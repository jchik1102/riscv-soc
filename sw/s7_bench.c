#include "platform.h"

#ifndef TICK_PERIOD
#define TICK_PERIOD 3000UL
#endif
#ifndef RANDOM_CASES
#define RANDOM_CASES 4UL
#endif
#define FIXED_CASES 6UL
#define CASES (FIXED_CASES + RANDOM_CASES)
#define OPERANDS_OFFSET 0x400000UL
#define RESULTS_OFFSET 0x500000UL
#define SEED 0x5337414343454c31UL

typedef unsigned long u64;
typedef unsigned int u32;
typedef int s32;
typedef signed char s8;
#define SDRAM_ADDR(offset) (PLATFORM_SDRAM_BASE + (offset))
#define TIMER ((volatile u64 *)PLATFORM_TIMER_BASE)
#define CACHE ((volatile u64 *)PLATFORM_CACHE_BASE)
#define INTC ((volatile u64 *)PLATFORM_INTC_BASE)
#define ACC(offset) ((volatile u64 *)(PLATFORM_ACCELERATOR_BASE + (offset)))
#define CTRL_START 1UL
#define CTRL_IE 2UL
#define CTRL_ACC 4UL
#define STATUS_DONE 2UL

struct operands {
    s8 a[4][4];
    s8 b[4][4];
    s32 c[4][4];
    u64 acc;
    u64 pad[3];
};
struct result { s32 d[4][4]; };

enum { M_SOFTWARE, M_TRANSFER, M_COMPUTE, M_READBACK, M_COMPLETE, M_COMPLETE_IRQ, M_CYCLES_REG, M_COMPUTE_IRQ };

struct report {
    u64 magic;
    u64 checksum;
    u64 status;
    u64 ticks;
    u64 mismatches;
    u64 info;
    u64 phase;
    u64 cases;
    u64 totals[2][8];
    u64 accel_irqs;
    u64 bad_traps;
    u64 per_case[16][4];
};
__attribute__((section(".report"))) volatile struct report s7_report;

static volatile u64 ticks, bad_traps, accel_irqs;

u64 trap_handler(u64 mcause, u64 mepc, u64 mtval) {
    (void)mtval;
    if (mcause == ((1UL << 63) | 7)) {
        ticks++;
        TIMER[1] = TIMER[1] + TICK_PERIOD;
        return mepc;
    }
    if (mcause == ((1UL << 63) | 11)) {
        u64 active = INTC[2];
        if (active & (1UL << PLATFORM_INTERRUPTS_ACCELERATOR)) {
            *ACC(PLATFORM_ACCEL_REGS_STATUS) = STATUS_DONE;
            accel_irqs++;
        } else bad_traps++;
        return mepc;
    }
    bad_traps++;
    return mcause >> 63 ? mepc : mepc + 4;
}

static inline u64 mcycle(void) { u64 v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }

static u64 rng_state;
static u64 next(void) { rng_state = rng_state * 6364136223846793005UL + 1442695040888963407UL; return rng_state; }
static s8 rand8(void) { return (s8)(next() >> 56); }
static s32 rand32(void) { return (s32)(next() >> 32); }

static void make_case(volatile struct operands *m, u64 index) {
    for (int i = 0; i < 4; i++) for (int k = 0; k < 4; k++) {
        s8 v;
        if (index == 0) v = 0;
        else if (index == 1) v = i == k;
        else if (index == 2 || index == 3) v = -128;
        else if (index == 4) v = 127;
        else v = rand8();
        m->a[i][k] = v;
    }
    for (int k = 0; k < 4; k++) for (int j = 0; j < 4; j++) {
        s8 v;
        if (index == 2) v = -128;
        else if (index == 3 || index == 4) v = 127;
        else v = rand8();
        m->b[k][j] = v;
    }
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {
        s32 v;
        if (index == 2) v = 0x7fffffff;
        else if (index == 3) v = (s32)0x80000000u;
        else v = rand32();
        m->c[i][j] = v;
    }
    if (index == 0 || index == 2 || index == 3) m->acc = 1;
    else if (index < FIXED_CASES) m->acc = 0;
    else m->acc = next() >> 63;
}

static void matmul_sw(const volatile struct operands *m, struct result *r, u64 n) {
    for (u64 i = 0; i < n; i++)
        for (u64 j = 0; j < n; j++) {
            u32 s = m->acc ? (u32)m->c[i][j] : 0;
            for (u64 k = 0; k < n; k++) s += (u32)((s32)m->a[i][k] * (s32)m->b[k][j]);
            r->d[i][j] = (s32)s;
        }
}

static void load_buffers(const volatile struct operands *m, u64 n) {
    const volatile u64 *a = (const volatile u64 *)m->a, *b = (const volatile u64 *)m->b;
    for (u64 w = 0; w < n / 2; w++) {
        *ACC(PLATFORM_ACCEL_REGS_A + 8 * w) = a[w];
        *ACC(PLATFORM_ACCEL_REGS_B + 8 * w) = b[w];
    }
    if (m->acc)
        for (u64 i = 0; i < n; i++) {
            const volatile u64 *c = (const volatile u64 *)m->c[i];
            for (u64 w = 0; w < n / 2; w++) *ACC(PLATFORM_ACCEL_REGS_C + 4 * n * i + 8 * w) = c[w];
        }
}

static void read_d(volatile struct result *r, u64 n) {
    for (u64 i = 0; i < n; i++) {
        volatile u64 *row = (volatile u64 *)r->d[i];
        for (u64 w = 0; w < n / 2; w++) row[w] = *ACC(PLATFORM_ACCEL_REGS_D + 4 * n * i + 8 * w);
    }
}

static u64 compare(const struct result *want, const volatile struct result *got, u64 n) {
    u64 bad = 0;
    for (u64 i = 0; i < n; i++) for (u64 j = 0; j < n; j++) bad += want->d[i][j] != got->d[i][j];
    return bad;
}

int main(void) {
    volatile struct operands *ops = (volatile struct operands *)SDRAM_ADDR(OPERANDS_OFFSET);
    volatile struct result *res = (volatile struct result *)SDRAM_ADDR(RESULTS_OFFSET);
    for (u64 i = 0; i < sizeof(s7_report) / 8; i++) ((volatile u64 *)&s7_report)[i] = 0;
    u64 info = *ACC(PLATFORM_ACCEL_REGS_INFO);
    u64 n = info & 0xff;
    s7_report.info = info;
    s7_report.cases = CASES;
    rng_state = SEED;
    for (u64 c = 0; c < CASES; c++) make_case(&ops[c], c);
    TIMER[1] = TIMER[2] + TICK_PERIOD;
    __asm__ volatile("csrw mie, %0" :: "r"(0x880UL));
    __asm__ volatile("csrsi mstatus, 8");
    u64 mismatches = 0, checksum = 0;
    for (u64 mode = 0; mode < 2; mode++) {
        s7_report.phase = mode + 1;
        CACHE[0] = mode == 0 ? 3 : 0;
        for (u64 c = 0; c < CASES; c++) {
            volatile struct operands *m = &ops[c];
            volatile struct result *polled = &res[(mode * CASES + c) * 2], *irq = polled + 1;
            struct result sw;
            u64 ctrl = CTRL_START | (m->acc ? CTRL_ACC : 0);
            u64 t0 = mcycle();
            matmul_sw(m, &sw, n);
            u64 t_sw = mcycle() - t0;
            t0 = mcycle();
            load_buffers(m, n);
            u64 t1 = mcycle();
            *ACC(PLATFORM_ACCEL_REGS_CTRL) = ctrl;
            while (!(*ACC(PLATFORM_ACCEL_REGS_STATUS) & STATUS_DONE)) { }
            u64 t2 = mcycle();
            read_d(polled, n);
            *ACC(PLATFORM_ACCEL_REGS_STATUS) = STATUS_DONE;
            u64 t3 = mcycle();
            u64 cycles_reg = *ACC(PLATFORM_ACCEL_REGS_CYCLES);
            u64 before = accel_irqs;
            u64 i0 = mcycle();
            load_buffers(m, n);
            *ACC(PLATFORM_ACCEL_REGS_CTRL) = ctrl | CTRL_IE;
            u64 i1 = mcycle();
            while (accel_irqs == before) { }
            u64 i2 = mcycle();
            read_d(irq, n);
            u64 i3 = mcycle();
            *ACC(PLATFORM_ACCEL_REGS_CTRL) = 0;
            mismatches += compare(&sw, polled, n) + compare(&sw, irq, n);
            if (mode == 0)
                for (u64 i = 0; i < n; i++) for (u64 j = 0; j < n; j++)
                    checksum = ((checksum << 5) | (checksum >> 59)) ^ (u32)sw.d[i][j];
            volatile u64 *t = s7_report.totals[mode];
            t[M_SOFTWARE] += t_sw;
            t[M_TRANSFER] += t1 - t0;
            t[M_COMPUTE] += t2 - t1;
            t[M_READBACK] += t3 - t2;
            t[M_COMPLETE] += t3 - t0;
            t[M_COMPLETE_IRQ] += i3 - i0;
            t[M_CYCLES_REG] += cycles_reg;
            t[M_COMPUTE_IRQ] += i2 - i1;
            if (mode == 0 && c < 16) {
                s7_report.per_case[c][0] = t_sw;
                s7_report.per_case[c][1] = t2 - t1;
                s7_report.per_case[c][2] = t3 - t0;
                s7_report.per_case[c][3] = i3 - i0;
            }
        }
    }
    __asm__ volatile("csrci mstatus, 8");
    TIMER[1] = ~0UL;
    CACHE[0] = 3;
    s7_report.checksum = checksum;
    s7_report.ticks = ticks;
    s7_report.mismatches = mismatches;
    s7_report.accel_irqs = accel_irqs;
    s7_report.bad_traps = bad_traps;
    s7_report.status = (mismatches == 0 && bad_traps == 0 && ticks > 0 && accel_irqs == 2 * CASES &&
                        (n == 2 || n == 4)) ? 1 : 2;
    s7_report.phase = 3;
    s7_report.magic = 0x5337414343454c00UL;
    return 0;
}
