.option norvc
.option norelax
.section .text.init
.globl _start
_start:
    la sp, __stack_top
    la t0, __bss_start
    la t1, __bss_end
clear_bss:
    bgeu t0, t1, run_main
    sd zero, 0(t0)
    addi t0, t0, 8
    j clear_bss
run_main:
    call main
    # No trap handler: ECALL with mtvec = 0 halts the core, which ends the run.
    csrw mtvec, zero
    ecall
