#include "platform.h"

#ifndef TICK_PERIOD
#define TICK_PERIOD 3000UL
#endif
#ifndef SMALL_WORDS
#define SMALL_WORDS 128UL
#endif
#ifndef BIG_WORDS
#define BIG_WORDS 512UL
#endif
#ifndef ROUNDS
#define ROUNDS 3UL
#endif
#define DATA_OFFSET 0x200000UL
#define CODE_OFFSET 0x300000UL

typedef unsigned long u64;
#define SDRAM_ADDR(offset) (PLATFORM_SDRAM_BASE + (offset))
#define TIMER ((volatile u64 *)PLATFORM_TIMER_BASE)
#define COUNTERS ((volatile u64 *)PLATFORM_COUNTERS_BASE)
#define CACHE ((volatile u64 *)PLATFORM_CACHE_BASE)

struct report {
    u64 magic;
    u64 checksum;
    u64 status;
    u64 ticks;
    u64 mismatches;
    u64 info;
    u64 phase;
    u64 pad;
    u64 cycles[4][4];
    u64 events[4][7];
    u64 results[4][4];
};
__attribute__((section(".report"))) volatile struct report s6_report;

static volatile u64 ticks, bad_traps;
extern char __sdram_text_start[], __sdram_text_end[];

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

__attribute__((section(".sdram_text"), noinline))
u64 kernel(const volatile u64 *a, u64 n, u64 rounds) {
    u64 s = 0;
    for (u64 r = 0; r < rounds; r++)
        for (u64 i = 0; i < n; i++) s = (s ^ a[i]) + (s << 7) + (s >> 3) + r;
    return s;
}

static inline u64 mcycle(void) { u64 v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }

int main(void) {
    typedef u64 (*kernel_t)(const volatile u64 *, u64, u64);
    volatile u64 *data = (volatile u64 *)SDRAM_ADDR(DATA_OFFSET);
    volatile u64 *code = (volatile u64 *)SDRAM_ADDR(CODE_OFFSET);
    kernel_t in_ram = kernel;
    kernel_t in_sdram = (kernel_t)(u64)code;
    u64 x = 0x243f6a8885a308d3UL;
    for (u64 i = 0; i < BIG_WORDS; i++) {
        x = x * 6364136223846793005UL + 1442695040888963407UL;
        data[i] = x;
    }
    const volatile u64 *source = (const volatile u64 *)__sdram_text_start;
    for (u64 i = 0; i < (u64)(__sdram_text_end - __sdram_text_start) / 8; i++) code[i] = source[i];
    __asm__ volatile("fence.i" ::: "memory");
    s6_report.info = CACHE[1];
    TIMER[1] = TIMER[2] + TICK_PERIOD;
    __asm__ volatile("csrw mie, %0" :: "r"(0x80UL));
    __asm__ volatile("csrsi mstatus, 8");
    u64 mismatches = 0;
    for (u64 mode = 0; mode < 4; mode++) {
        s6_report.phase = mode + 1;
        CACHE[0] = mode;
        u64 before[7];
        for (int e = 0; e < 7; e++) before[e] = COUNTERS[8 + e];
        for (u64 w = 0; w < 4; w++) {
            kernel_t f = w < 2 ? in_ram : in_sdram;
            u64 n = (w & 1) ? BIG_WORDS : SMALL_WORDS;
            u64 t0 = mcycle();
            u64 result = f(data, n, ROUNDS);
            s6_report.cycles[mode][w] = mcycle() - t0;
            s6_report.results[mode][w] = result;
            if (result != s6_report.results[0][w]) mismatches++;
        }
        for (int e = 0; e < 7; e++) s6_report.events[mode][e] = COUNTERS[8 + e] - before[e];
    }
    __asm__ volatile("csrci mstatus, 8");
    TIMER[1] = ~0UL;
    CACHE[0] = 3;
    u64 checksum = 0;
    for (u64 w = 0; w < 4; w++) checksum = ((checksum << 7) | (checksum >> 57)) ^ s6_report.results[0][w];
    s6_report.checksum = checksum;
    s6_report.ticks = ticks;
    s6_report.mismatches = mismatches;
    s6_report.status = (mismatches == 0 && bad_traps == 0 && ticks > 0) ? 1 : 2;
    s6_report.phase = 5;
    s6_report.magic = 0x5336434143484500UL;
    return 0;
}
