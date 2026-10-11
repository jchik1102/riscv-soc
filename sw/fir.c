#include "fir_data.h"

typedef unsigned long u64;

struct report {
    u64 magic;
    u64 checksum;
    u64 status;
};

__attribute__((section(".report"))) volatile struct report fir_report;
short fir_output[FIR_SAMPLES];

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

int main(void) {
    fir(fir_input, fir_coeff, fir_output, FIR_SAMPLES);
    u64 sum = 0;
    for (int i = 0; i < FIR_SAMPLES; i++) sum += (u64)(i + 1) * (unsigned short)fir_output[i];
    fir_report.checksum = sum;
    fir_report.status = sum == FIR_EXPECTED_CHECKSUM ? 1 : 2;
    fir_report.magic = 0x4649523151313500UL;
    return (int)fir_report.status;
}
