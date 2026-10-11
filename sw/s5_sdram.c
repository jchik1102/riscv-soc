#include "platform.h"

#ifndef TEST_BYTES
#define TEST_BYTES 0x4000UL
#endif
#ifndef TICK_PERIOD
#define TICK_PERIOD 4000UL
#endif
#define WORK_WORDS 512UL
#define WORK_A 0x100000UL
#define WORK_B 0x200000UL
#define BYTE_BLOCK 0x300000UL
#define RUN_SLOT 0x3fffff0UL
#define RUN_MAGIC 0x52554e434f554e54UL

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned short u16;
typedef unsigned char u8;
#define SDRAM_ADDR(offset) (PLATFORM_SDRAM_BASE + (offset))
#define TIMER ((volatile u64 *)PLATFORM_TIMER_BASE)

struct report {
    u64 magic;
    u64 checksum;
    u64 status;
    u64 errors;
    u64 ticks;
    u64 words;
    u64 first_bad;
    u64 phase;
    u64 runs;
};
__attribute__((section(".report"))) volatile struct report s5_report;

static volatile u64 ticks, bad_traps;
static u64 errors, words, first_bad;

static const u64 probes[] = {0x0, 0x7f8, 0x800, 0x1000, 0x1800, 0x1ff8, 0x2000, 0x2008,
                             0x3ffe000, 0x3fffff8, 0x2000000, 0x1234560};

u64 trap_handler(u64 mcause, u64 mepc, u64 mtval) {
    (void)mtval;
    if (mcause == ((1UL << 63) | 7)) {
        ticks++;
        TIMER[1] = TIMER[1] + TICK_PERIOD;
        return mepc;
    }
    bad_traps++;
    return mcause >> 63 ? mepc : mepc + 4;
}

#define LOAD(name, insn) static inline u64 name(u64 address) {     u64 v; __asm__ volatile(insn " %0, 0(%1)" : "=r"(v) : "r"(address) : "memory"); return v; }
LOAD(load_b, "lb") LOAD(load_bu, "lbu") LOAD(load_h, "lh") LOAD(load_hu, "lhu") LOAD(load_w, "lw") LOAD(load_wu, "lwu")

static void check(u64 address, u64 actual, u64 expected) {
    words++;
    if (actual != expected) {
        if (!errors) first_bad = address;
        errors++;
    }
}

static u64 xorshift(u64 x) { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x; }

static u64 pattern(int p, u64 address, u64 *state) {
    if (p == 0) return address;
    if (p == 1) return ~address;
    *state = xorshift(*state);
    return *state;
}

static void full_span(int p) {
    u64 state = 0x9e3779b97f4a7c15UL;
    for (u64 offset = 0; offset < TEST_BYTES; offset += 8)
        *(volatile u64 *)SDRAM_ADDR(offset) = pattern(p, SDRAM_ADDR(offset), &state);
    state = 0x9e3779b97f4a7c15UL;
    for (u64 offset = 0; offset < TEST_BYTES; offset += 8) {
        u64 address = SDRAM_ADDR(offset);
        check(address, *(volatile u64 *)address, pattern(p, address, &state));
    }
}

static void boundaries(void) {
    u64 n = sizeof probes / sizeof probes[0];
    for (u64 i = 0; i < n; i++) *(volatile u64 *)SDRAM_ADDR(probes[i]) = SDRAM_ADDR(probes[i]) ^ 0x5a5aa5a5c3c33c3cUL;
    for (u64 i = 0; i < n; i++) {
        u64 address = SDRAM_ADDR(probes[i]);
        check(address, *(volatile u64 *)address, address ^ 0x5a5aa5a5c3c33c3cUL);
    }
    volatile u64 *beat = (volatile u64 *)SDRAM_ADDR(0x10);
    for (int bit = 0; bit < 64; bit++) {
        *beat = 1UL << bit;
        check((u64)beat, *beat, 1UL << bit);
    }
    volatile u8 *b = (volatile u8 *)SDRAM_ADDR(0x20);
    for (int i = 0; i < 8; i++) b[i] = (u8)(0x81 + 0x11 * i);
    check((u64)b, *(volatile u64 *)b, 0xf8e7d6c5b4a39281UL);
    volatile u16 *h = (volatile u16 *)SDRAM_ADDR(0x28);
    for (int i = 0; i < 4; i++) h[i] = (u16)(0x8001 + 0x1111 * i);
    check((u64)h, *(volatile u64 *)h, 0xb334a22391128001UL);
    volatile u32 *w = (volatile u32 *)SDRAM_ADDR(0x30);
    w[0] = 0x89abcdefU;
    w[1] = 0x01234567U;
    check((u64)w, *(volatile u64 *)w, 0x0123456789abcdefUL);
    check((u64)w, load_w((u64)w), 0xffffffff89abcdefUL);
    check((u64)w, load_wu((u64)w), 0x89abcdefUL);
    check((u64)h, load_h((u64)h), 0xffffffffffff8001UL);
    check((u64)h, load_hu((u64)&h[3]), 0xb334UL);
    check((u64)b, load_b((u64)&b[7]), 0xfffffffffffffff8UL);
    check((u64)b, load_bu((u64)b), 0x81UL);
}

static u64 workload(void) {
    volatile u64 *a = (volatile u64 *)SDRAM_ADDR(WORK_A);
    volatile u64 *bsum = (volatile u64 *)SDRAM_ADDR(WORK_B);
    u64 x = 12345;
    for (u64 i = 0; i < WORK_WORDS; i++) {
        x = x * 6364136223846793005UL + 1442695040888963407UL;
        a[i] = x;
    }
    u64 running = 0;
    for (u64 i = 0; i < WORK_WORDS; i++) {
        running += a[i] * (i | 1);
        bsum[i] = running;
    }
    volatile u8 *block = (volatile u8 *)SDRAM_ADDR(BYTE_BLOCK);
    for (u64 i = 0; i < 256; i++) block[i] = (u8)(i * 7 + 3);
    for (u64 i = 0; i < 128; i++) {
        u8 t = block[i];
        block[i] = block[255 - i];
        block[255 - i] = t;
    }
    u64 sum = 0;
    for (u64 i = 0; i < WORK_WORDS; i++) sum = ((sum << 5) | (sum >> 59)) ^ bsum[i];
    for (u64 i = 0; i < 256; i += 8) sum += *(volatile u64 *)(block + i);
    return sum;
}

int main(void) {
#ifdef RUN_COUNTER
    volatile u64 *slot = (volatile u64 *)SDRAM_ADDR(RUN_SLOT);
    u64 runs = slot[0] == RUN_MAGIC ? slot[1] : 0;
#endif
    TIMER[1] = TIMER[2] + TICK_PERIOD;
    __asm__ volatile("csrw mie, %0" :: "r"(0x80UL));
    __asm__ volatile("csrsi mstatus, 8");
    s5_report.phase = 1;
    boundaries();
    for (int p = 0; p < 3; p++) {
        s5_report.phase = 2 + p;
        full_span(p);
    }
    s5_report.phase = 5;
    u64 checksum = workload();
    __asm__ volatile("csrci mstatus, 8");
    TIMER[1] = ~0UL;
    s5_report.checksum = checksum;
    s5_report.errors = errors;
    s5_report.ticks = ticks;
    s5_report.words = words;
    s5_report.first_bad = first_bad;
    s5_report.status = (errors == 0 && bad_traps == 0 && ticks > 0) ? 1 : 2;
#ifdef RUN_COUNTER
    slot[0] = RUN_MAGIC;
    slot[1] = runs + 1;
    s5_report.runs = runs + 1;
#endif
    s5_report.phase = 6;
    s5_report.magic = 0x5335534452414d00UL;
    return 0;
}
