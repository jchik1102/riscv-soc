.option norvc
.option norelax
.section .text.init
.globl _start
_start:
    la sp, __stack_top
    la s0, asm_results
    li t0, -7
    li t1, 2
    li t2, 0x8000000000000000
    li t3, -1
    li t4, 0x123456780000000f
    mul    t5, t0, t1
    sd     t5, 0(s0)
    mulh   t5, t2, t2
    sd     t5, 8(s0)
    mulhsu t5, t3, t3
    sd     t5, 16(s0)
    mulhu  t5, t3, t3
    sd     t5, 24(s0)
    div    t5, t2, t3
    sd     t5, 32(s0)
    divu   t5, t0, t1
    sd     t5, 40(s0)
    rem    t5, t0, t1
    sd     t5, 48(s0)
    remu   t5, t0, t1
    sd     t5, 56(s0)
    div    t5, t0, zero
    sd     t5, 64(s0)
    mulw   t5, t4, t0
    sd     t5, 72(s0)
    divw   t5, t0, t1
    sd     t5, 80(s0)
    divuw  t5, t0, t1
    sd     t5, 88(s0)
    remw   t5, t4, zero
    sd     t5, 96(s0)
    remuw  t5, t0, t1
    sd     t5, 104(s0)
    call   kernel_main
    sd     a0, 112(s0)
    ebreak
.section .data
.balign 8
.globl asm_results
asm_results: .zero 120
