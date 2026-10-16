/* CoreMark port for the RV64IM pipeline core in tb/core/coremark_tb.sv.
 * Bare metal: no FPU, no libc. Time is the mcycle CSR; output goes byte by
 * byte to the testbench console address. Based on CoreMark's barebones port. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H
#include <stddef.h>

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0
#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC" __VERSION__
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS FLAGS_STR
#endif
#define MEM_LOCATION "STACK"

typedef signed short ee_s16;
typedef unsigned short ee_u16;
typedef signed int ee_s32;
typedef double ee_f32;
typedef unsigned char ee_u8;
typedef unsigned int ee_u32;
typedef unsigned long ee_ptr_int;
typedef size_t ee_size_t;
#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE unsigned long
typedef unsigned long CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MEM_METHOD MEM_STACK
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK 0
#define USE_SOCKET 0
#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

/* Core clock the tick count is converted with (the DE10-Lite core clock). */
#ifndef CLOCK_HZ
#define CLOCK_HZ 50000000UL
#endif

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#if (TOTAL_DATA_SIZE == 1200)
#define PROFILE_RUN 1
#elif (TOTAL_DATA_SIZE == 2000)
#define PERFORMANCE_RUN 1
#else
#define VALIDATION_RUN 1
#endif
#endif

extern ee_u32 default_num_contexts;
int ee_printf(const char *fmt, ...);

#endif
