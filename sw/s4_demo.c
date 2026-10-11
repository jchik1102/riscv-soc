#include "platform.h"

#ifndef TICK_PERIOD
#define TICK_PERIOD 3000UL
#endif
#ifndef TICKS
#define TICKS 6UL
#endif
#ifndef UART_DIV
#define UART_DIV 16UL
#endif

typedef unsigned long u64;
#define UART ((volatile u64 *)PLATFORM_UART_BASE)
#define TIMER ((volatile u64 *)PLATFORM_TIMER_BASE)
#define COUNT ((volatile u64 *)PLATFORM_COUNTERS_BASE)

struct report {
    u64 magic;
    u64 ticks;
    u64 status;
    u64 ecalls, rx_count, checksum, mcycle, minstret;
    u64 counters[8];
};
__attribute__((section(".report"))) volatile struct report s4_report;

static volatile u64 ticks, ecalls, rx_count, bad_traps;
static volatile unsigned char rx_buf[16];
static u64 work[32];

static inline u64 csr_mcycle(void) { u64 v; __asm__ volatile("csrr %0, mcycle" : "=r"(v)); return v; }
static inline u64 csr_minstret(void) { u64 v; __asm__ volatile("csrr %0, minstret" : "=r"(v)); return v; }

static void putc_uart(char c) {
    while (UART[2] & 1) { }
    UART[0] = (unsigned char)c;
}
static void puts_uart(const char *s) { while (*s) putc_uart(*s++); }
static void puthex(u64 v) {
    puts_uart("0x");
    int started = 0;
    for (int shift = 60; shift >= 0; shift -= 4) {
        unsigned d = (v >> shift) & 15;
        if (d || started || shift == 0) { putc_uart(d < 10 ? '0' + d : 'a' + d - 10); started = 1; }
    }
}

u64 trap_handler(u64 mcause, u64 mepc, u64 mtval) {
    (void)mtval;
    if (mcause >> 63) {
        u64 code = mcause & 0xff;
        if (code == 7) {
            ticks++;
            s4_report.ticks = ticks;
            if (ticks >= TICKS) TIMER[1] = ~0UL;
            else TIMER[1] = TIMER[1] + TICK_PERIOD;
        } else if (code == 11) {
            while (UART[2] & 4) {
                u64 v = UART[1];
                if (rx_count < sizeof rx_buf) rx_buf[rx_count] = (unsigned char)v;
                rx_count++;
            }
        } else bad_traps++;
        return mepc;
    }
    if (mcause == 11) { ecalls++; return mepc + 4; }
    bad_traps++;
    return mepc + 4;
}

int main(void) {
    UART[4] = UART_DIV;
    puts_uart("S4 start\n");
    u64 cycle0 = csr_mcycle(), instret0 = csr_minstret();
    UART[3] = 1;
    TIMER[1] = TIMER[2] + TICK_PERIOD;
    __asm__ volatile("csrw mie, %0" :: "r"(0x880UL));
    __asm__ volatile("csrsi mstatus, 8");
    u64 checksum = 0;
    for (u64 i = 1; i <= 200; i++) {
        work[i & 31] = (work[(i * 7) & 31] + i * i) % 1000003UL;
        checksum += work[i & 31] / (i % 13 + 1);
    }
    __asm__ volatile("ecall");
    __asm__ volatile("ecall");
    while (ticks < TICKS) { }
    __asm__ volatile("csrci mstatus, 8");
    u64 cycles = csr_mcycle() - cycle0, instret = csr_minstret() - instret0;
    for (int i = 0; i < 8; i++) s4_report.counters[i] = COUNT[i];
    puts_uart("ticks=");  puthex(ticks);
    puts_uart(" ecalls="); puthex(ecalls);
    puts_uart(" rx=");
    for (u64 i = 0; i < rx_count && i < sizeof rx_buf; i++) putc_uart(rx_buf[i]);
    puts_uart(" sum="); puthex(checksum);
    puts_uart("\n");
    while (!(UART[2] & 2)) { }
    s4_report.ecalls = ecalls;
    s4_report.rx_count = rx_count;
    s4_report.checksum = checksum;
    s4_report.mcycle = cycles;
    s4_report.minstret = instret;
    s4_report.status = (ticks == TICKS && ecalls == 2 && bad_traps == 0 && cycles > instret) ? 1 : 2;
    s4_report.magic = 0x5334444f4e450000UL;
    return 0;
}
