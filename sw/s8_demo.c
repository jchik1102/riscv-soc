#include "platform.h"

#ifndef TICK_PERIOD
#define TICK_PERIOD 3000UL
#endif
#ifndef RANDOM_CASES
#define RANDOM_CASES 4UL
#endif
#define FIXED_CASES 6UL
#define CASES (FIXED_CASES + RANDOM_CASES)
#define DIM 16UL
#define OPERANDS_OFFSET 0x400000UL
#define MATRIX_OFFSET 0x410000UL
#define MATRIX_RESULTS 0x500000UL
#define CASE_RESULTS 0x510000UL
#define SEED 0x5337414343454c31UL
#define MATRIX_SEED 0x533844454d4f3136UL

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef int s32;
typedef signed char s8;
#define SDRAM_ADDR(offset) (PLATFORM_SDRAM_BASE + (offset))
#define TIMER ((volatile u64 *)PLATFORM_TIMER_BASE)
#define COUNTERS ((volatile u64 *)PLATFORM_COUNTERS_BASE)
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
struct matrix { s8 a[DIM][DIM]; s8 b[DIM][DIM]; s32 c[DIM][DIM]; };
struct matrix_result { s32 d[DIM][DIM]; };

enum { SOFTWARE, POLLED, INTERRUPT };
enum { K_MCYCLE, K_RETIRED, K_MEM_WAIT, K_ARITH, K_D_ACCESS, K_D_MISS, K_D_UNCACHED, K_D_WRITE,
       K_CYCLE, K_FETCH, K_LOAD_USE, K_REDIRECT, K_I_ACCESS, K_I_MISS, K_I_UNCACHED, K_TICKS };
static const unsigned char counter_index[16] = {0, 2, 3, 4, 11, 12, 13, 14, 1, 5, 6, 7, 8, 9, 10, 0};

struct report {
    u64 magic;
    u64 checksum;
    u64 status;
    u64 ticks;
    u64 mismatches;
    u64 info;
    u64 phase;
    u64 cases;
    u64 accel_irqs;
    u64 bad_traps;
    u64 dim;
    u64 tile_runs;
    u64 counter_errors;
    u64 pad[3];
    u64 metrics[2][2][4][16];
};
__attribute__((section(".report"))) volatile struct report s8_report;

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

static void make_matrix(volatile struct matrix *m) {
    rng_state = MATRIX_SEED;
    for (u64 i = 0; i < DIM; i++) for (u64 k = 0; k < DIM; k++) m->a[i][k] = i == 0 ? -128 : rand8();
    for (u64 k = 0; k < DIM; k++) for (u64 j = 0; j < DIM; j++) m->b[k][j] = j == 0 ? -128 : rand8();
    for (u64 i = 0; i < DIM; i++) for (u64 j = 0; j < DIM; j++) m->c[i][j] = i == 0 && j == 0 ? 0x7fffffff : rand32();
}

static void case_sw(const volatile struct operands *m, volatile struct result *r, u64 n) {
    for (u64 i = 0; i < n; i++)
        for (u64 j = 0; j < n; j++) {
            u32 s = m->acc ? (u32)m->c[i][j] : 0;
            for (u64 k = 0; k < n; k++) s += (u32)((s32)m->a[i][k] * (s32)m->b[k][j]);
            r->d[i][j] = (s32)s;
        }
}

static void matrix_sw(const volatile struct matrix *m, volatile struct matrix_result *r) {
    for (u64 i = 0; i < DIM; i++)
        for (u64 j = 0; j < DIM; j++) {
            u32 s = (u32)m->c[i][j];
            for (u64 k = 0; k < DIM; k++) s += (u32)((s32)m->a[i][k] * (s32)m->b[k][j]);
            r->d[i][j] = (s32)s;
        }
}

static void run_accel(u64 ctrl, u64 method) {
    if (method == POLLED) {
        *ACC(PLATFORM_ACCEL_REGS_CTRL) = ctrl;
        while (!(*ACC(PLATFORM_ACCEL_REGS_STATUS) & STATUS_DONE)) { }
    } else {
        u64 before = accel_irqs;
        *ACC(PLATFORM_ACCEL_REGS_CTRL) = ctrl | CTRL_IE;
        while (accel_irqs == before) { }
    }
}

static inline u64 row_word(const volatile s8 *p, u64 n) {
    return n == 4 ? *(const volatile u32 *)p : *(const volatile u16 *)p;
}

static void case_accel(const volatile struct operands *m, volatile struct result *r, u64 n, u64 method) {
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
    run_accel(CTRL_START | (m->acc ? CTRL_ACC : 0), method);
    for (u64 i = 0; i < n; i++) {
        volatile u64 *row = (volatile u64 *)r->d[i];
        for (u64 w = 0; w < n / 2; w++) row[w] = *ACC(PLATFORM_ACCEL_REGS_D + 4 * n * i + 8 * w);
    }
}

static void matrix_accel(const volatile struct matrix *m, volatile struct matrix_result *r, u64 n, u64 method) {
    u64 tiles = DIM / n;
    for (u64 ti = 0; ti < tiles; ti++)
        for (u64 tj = 0; tj < tiles; tj++) {
            for (u64 tk = 0; tk < tiles; tk++) {
                for (u64 w = 0; w < n / 2; w++) {
                    u64 i = ti * n + 2 * w, k = tk * n + 2 * w;
                    *ACC(PLATFORM_ACCEL_REGS_A + 8 * w) = row_word(&m->a[i][tk * n], n) | row_word(&m->a[i + 1][tk * n], n) << 32;
                    *ACC(PLATFORM_ACCEL_REGS_B + 8 * w) = row_word(&m->b[k][tj * n], n) | row_word(&m->b[k + 1][tj * n], n) << 32;
                }
                for (u64 i = 0; i < n; i++)
                    for (u64 w = 0; w < n / 2; w++)
                        *ACC(PLATFORM_ACCEL_REGS_C + 4 * n * i + 8 * w) = tk == 0
                            ? ((const volatile u64 *)&m->c[ti * n + i][tj * n])[w]
                            : *ACC(PLATFORM_ACCEL_REGS_D + 4 * n * i + 8 * w);
                run_accel(CTRL_START | CTRL_ACC, method);
            }
            for (u64 i = 0; i < n; i++)
                for (u64 w = 0; w < n / 2; w++)
                    ((volatile u64 *)&r->d[ti * n + i][tj * n])[w] = *ACC(PLATFORM_ACCEL_REGS_D + 4 * n * i + 8 * w);
        }
}

static u64 window_t0, window_ticks;

static void window_begin(u64 caches_on) {
    COUNTERS[0] = 0;
    if (caches_on) { CACHE[0] = 0; CACHE[0] = 3; }
    for (u64 i = 1; i < 15; i++) COUNTERS[i] = 0;
    window_ticks = ticks;
    window_t0 = mcycle();
    COUNTERS[0] = 1;
}

static u64 window_end(volatile u64 *out, u64 caches_on) {
    COUNTERS[0] = 0;
    u64 t = mcycle() - window_t0;
    u64 v[15];
    for (u64 i = 1; i < 15; i++) v[i] = COUNTERS[i];
    out[K_MCYCLE] = t;
    for (u64 k = 1; k < 15; k++) out[k] = v[counter_index[k]];
    out[K_TICKS] = ticks - window_ticks;
    u64 bad = v[8] || v[9] || v[10];
    if (caches_on) bad |= v[13] != 0 || v[12] == 0;
    else bad |= v[11] != 0 || v[12] != 0 || v[13] == 0;
    return bad;
}

static u64 compare(const volatile s32 *want, const volatile s32 *got, u64 count) {
    u64 bad = 0;
    for (u64 i = 0; i < count; i++) bad += want[i] != got[i];
    return bad;
}

int main(void) {
    volatile struct operands *ops = (volatile struct operands *)SDRAM_ADDR(OPERANDS_OFFSET);
    volatile struct matrix *mat = (volatile struct matrix *)SDRAM_ADDR(MATRIX_OFFSET);
    volatile struct matrix_result *mres = (volatile struct matrix_result *)SDRAM_ADDR(MATRIX_RESULTS);
    volatile struct result *cres = (volatile struct result *)SDRAM_ADDR(CASE_RESULTS);
    for (u64 i = 0; i < sizeof(s8_report) / 8; i++) ((volatile u64 *)&s8_report)[i] = 0;
    u64 info = *ACC(PLATFORM_ACCEL_REGS_INFO);
    u64 n = info & 0xff;
    u64 tiles = DIM / (n ? n : 1);
    s8_report.info = info;
    s8_report.cases = CASES;
    s8_report.dim = DIM;
    s8_report.tile_runs = tiles * tiles * tiles;
    rng_state = SEED;
    for (u64 c = 0; c < CASES; c++) make_case(&ops[c], c);
    make_matrix(mat);
    TIMER[1] = TIMER[2] + TICK_PERIOD;
    __asm__ volatile("csrw mie, %0" :: "r"(0x880UL));
    __asm__ volatile("csrsi mstatus, 8");
    u64 counter_errors = 0;
    for (u64 mode = 0; mode < 2; mode++) {
        u64 on = mode == 0;
        s8_report.phase = mode + 1;
        CACHE[0] = on ? 3 : 0;
        for (u64 method = SOFTWARE; method <= INTERRUPT; method++) {
            volatile struct matrix_result *r = &mres[mode * 3 + method];
            window_begin(on);
            if (method == SOFTWARE) matrix_sw(mat, r);
            else matrix_accel(mat, r, n, method);
            counter_errors += window_end(s8_report.metrics[0][mode][method], on);
        }
        for (u64 method = SOFTWARE; method <= INTERRUPT; method++) {
            volatile struct result *r = &cres[(mode * 3 + method) * CASES];
            window_begin(on);
            for (u64 c = 0; c < CASES; c++) {
                if (method == SOFTWARE) case_sw(&ops[c], &r[c], n);
                else case_accel(&ops[c], &r[c], n, method);
            }
            counter_errors += window_end(s8_report.metrics[1][mode][method], on);
        }
    }
    __asm__ volatile("csrci mstatus, 8");
    TIMER[1] = ~0UL;
    *ACC(PLATFORM_ACCEL_REGS_CTRL) = 0;
    CACHE[0] = 3;
    u64 mismatches = 0, checksum = 0;
    for (u64 k = 1; k < 6; k++) mismatches += compare(&mres[0].d[0][0], &mres[k].d[0][0], DIM * DIM);
    for (u64 c = 0; c < CASES; c++)
        for (u64 k = 1; k < 6; k++)
            for (u64 i = 0; i < n; i++) mismatches += compare(cres[c].d[i], cres[k * CASES + c].d[i], n);
    for (u64 i = 0; i < DIM; i++) for (u64 j = 0; j < DIM; j++)
        checksum = ((checksum << 5) | (checksum >> 59)) ^ (u32)mres[0].d[i][j];
    for (u64 c = 0; c < CASES; c++)
        for (u64 i = 0; i < n; i++) for (u64 j = 0; j < n; j++)
            checksum = ((checksum << 5) | (checksum >> 59)) ^ (u32)cres[c].d[i][j];
    s8_report.checksum = checksum;
    s8_report.ticks = ticks;
    s8_report.mismatches = mismatches;
    s8_report.accel_irqs = accel_irqs;
    s8_report.bad_traps = bad_traps;
    s8_report.counter_errors = counter_errors;
    s8_report.status = (mismatches == 0 && bad_traps == 0 && ticks > 0 && counter_errors == 0 &&
                        accel_irqs == 2 * (tiles * tiles * tiles + CASES) && (n == 2 || n == 4)) ? 1 : 2;
    s8_report.phase = 3;
    s8_report.magic = 0x533844454d4f0000UL;
    return 0;
}
