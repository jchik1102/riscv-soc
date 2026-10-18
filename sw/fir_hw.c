// The S3 FIR benchmark on the hardware filter (rtl/peripherals/fir_filter.sv)
// and in software, in one program. The software filter is the function from
// sw/fir.c, unchanged. The hardware driver loads the coefficients, then for
// each sample writes it to DATA and reads the output back; the read is held
// on the bus until the filter has finished, so there is no polling. mcycle is
// read around each version, and both outputs must match the reference
// checksum and each other.
#include "fir_data.h"
#include "platform.h"

typedef unsigned long u64;

struct report {
    u64 magic;
    u64 checksum_hw;
    u64 status;
    u64 checksum_sw;
    u64 cycles_sw;
    u64 cycles_hw;
    u64 mismatches;
    u64 filter_cycles;
};

__attribute__((section(".report"))) volatile struct report fir_report;
short sw_output[FIR_SAMPLES];
short hw_output[FIR_SAMPLES];

#define FIR_REG(offset) (*(volatile u64 *)(PLATFORM_DSP_BASE + (offset)))
#define FIR_CTRL 0x000
#define FIR_CYCLES 0x018
#define FIR_DATA 0x020
#define FIR_COEFF 0x100

static inline u64 mcycle(void) {
    u64 v;
    __asm__ volatile("csrr %0, mcycle" : "=r"(v));
    return v;
}

__attribute__((noinline)) static void fir(const short *x, const short *h, short *y, int n) {
    for (int i = 0; i < n; i++) {
        long acc = 0;
        for (int k = 0; k < FIR_TAPS && k <= i; k++)
            acc += (long)(h[k] * x[i - k]);
        acc = (acc + (1L << 14)) >> 15;
        if (acc > 32767) acc = 32767;
        if (acc < -32768) acc = -32768;
        y[i] = (short)acc;
    }
}

__attribute__((noinline)) static void fir_hw(const short *x, const short *h, short *y, int n) {
    FIR_REG(FIR_CTRL) = 1;                          // clear the delay line and counters
    for (int k = 0; k < FIR_TAPS; k++) FIR_REG(FIR_COEFF + 8 * k) = (u64)(long)h[k];
    for (int i = 0; i < n; i++) {
        FIR_REG(FIR_DATA) = (u64)(long)x[i];
        y[i] = (short)FIR_REG(FIR_DATA);
    }
}

static u64 checksum(const short *y) {
    u64 sum = 0;
    for (int i = 0; i < FIR_SAMPLES; i++) sum += (u64)(i + 1) * (unsigned short)y[i];
    return sum;
}

int main(void) {
    u64 t0 = mcycle();
    fir(fir_input, fir_coeff, sw_output, FIR_SAMPLES);
    u64 t1 = mcycle();
    fir_hw(fir_input, fir_coeff, hw_output, FIR_SAMPLES);
    u64 t2 = mcycle();
    u64 mismatches = 0;
    for (int i = 0; i < FIR_SAMPLES; i++) mismatches += sw_output[i] != hw_output[i];
    u64 sw = checksum(sw_output), hw = checksum(hw_output);
    fir_report.cycles_sw = t1 - t0;
    fir_report.cycles_hw = t2 - t1;
    fir_report.filter_cycles = FIR_REG(FIR_CYCLES);
    fir_report.mismatches = mismatches;
    fir_report.checksum_sw = sw;
    fir_report.checksum_hw = hw;
    fir_report.status = sw == FIR_EXPECTED_CHECKSUM && hw == FIR_EXPECTED_CHECKSUM && mismatches == 0 ? 1 : 2;
    fir_report.magic = 0x4649524857313600UL;        // "FIRHW16"
    return (int)fir_report.status;
}
