/* Minimal ee_printf for CoreMark: %d %u %x %s %c with l and width/zero
 * flags, which is everything core_main.c prints when HAS_FLOAT is 0. Each
 * character is stored to the testbench console address. Also provides the
 * memset/memcpy that GCC may call in freestanding code. */
#include <stdarg.h>
#include <stddef.h>

#define CONSOLE ((volatile unsigned char *)0x10000000UL)

static void put(char c) { *CONSOLE = (unsigned char)c; }

static void put_number(unsigned long value, unsigned base, int negative, int width, char pad)
{
    char digits[24];
    int n = 0;
    do {
        unsigned d = value % base;
        digits[n++] = (char)(d < 10 ? '0' + d : 'a' + d - 10);
        value /= base;
    } while (value != 0);
    if (negative) digits[n++] = '-';
    while (width-- > n) put(pad);
    while (n > 0) put(digits[--n]);
}

int ee_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    for (; *fmt; fmt++) {
        if (*fmt != '%') { put(*fmt); continue; }
        fmt++;
        char pad = ' ';
        int width = 0, is_long = 0;
        if (*fmt == '0') { pad = '0'; fmt++; }
        while (*fmt >= '0' && *fmt <= '9') width = width * 10 + (*fmt++ - '0');
        while (*fmt == 'l') { is_long = 1; fmt++; }
        switch (*fmt) {
        case 'd': case 'i': {
            long v = is_long ? va_arg(args, long) : va_arg(args, int);
            put_number(v < 0 ? -(unsigned long)v : (unsigned long)v, 10, v < 0, width, pad);
            break;
        }
        case 'u':
            put_number(is_long ? va_arg(args, unsigned long) : va_arg(args, unsigned), 10, 0, width, pad);
            break;
        case 'x': case 'X':
            put_number(is_long ? va_arg(args, unsigned long) : va_arg(args, unsigned), 16, 0, width, pad);
            break;
        case 's': {
            const char *s = va_arg(args, const char *);
            while (*s) put(*s++);
            break;
        }
        case 'c': put((char)va_arg(args, int)); break;
        case '%': put('%'); break;
        default: put('%'); put(*fmt); break;
        }
    }
    va_end(args);
    return 0;
}

void *memset(void *dst, int value, size_t n)
{
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)value;
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}
