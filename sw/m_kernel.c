typedef unsigned long u64;

static volatile long inputs[] = {3, 200, 1000003, -1000, 7, -1234, 567, 4000000000L};

__attribute__((noinline)) static u64 modpow(u64 base, u64 exp, u64 mod) {
    u64 result = 1 % mod;
    base %= mod;
    while (exp) {
        if (exp & 1) result = result * base % mod;
        base = base * base % mod;
        exp >>= 1;
    }
    return result;
}

__attribute__((noinline)) static long signed_mix(long a, long b) {
    return a / b + a % b * 3;
}

__attribute__((noinline)) static int word_mix(int a, int b) {
    return a * b / (b - 3) % 1000;
}

__attribute__((noinline)) static unsigned word_umix(unsigned a, unsigned b) {
    return a / b + a % b;
}

long kernel_main(void) {
    long total = (long)modpow((u64)inputs[0], (u64)inputs[1], (u64)inputs[2]);
    total += signed_mix(inputs[3], inputs[4]);
    total += word_mix((int)inputs[5], (int)inputs[6]);
    total += (long)word_umix((unsigned)inputs[7], (unsigned)inputs[4]);
    return total;
}
