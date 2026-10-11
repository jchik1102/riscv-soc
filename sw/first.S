.section .text.init
.option norvc
.option norelax
.global _start
_start:
    addi x1, x0, 5
    addi x2, x0, 7
    add  x3, x1, x2
    .word 0
