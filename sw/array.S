.option norvc
.option norelax
.section .text.init
.globl _start
_start:
    la t0, array
    li t1, 16
    li t2, -8
fill:
    sw t2, 0(t0)
    addiw t2, t2, 1
    addi t0, t0, 4
    addi t1, t1, -1
    bne t1, zero, fill
    la a0, array
    jal ra, sum
    la t0, result
    sd a0, 0(t0)
    lwu a1, 0(t0)
    ld a2, 0(t0)
    ebreak
sum:
    mv t0, a0
    li t1, 16
    li a0, 0
accumulate:
    lw t2, 0(t0)
    add a0, a0, t2
    addi t0, t0, 4
    addi t1, t1, -1
    bne t1, zero, accumulate
    ret
.section .data
.balign 8
array: .zero 64
result: .dword 0
