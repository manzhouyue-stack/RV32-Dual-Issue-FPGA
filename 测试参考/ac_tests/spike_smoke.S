    .section .text
    .globl _start
_start:
    li t0, 42
    addi t0, t0, 1
    li t1, 43
    bne t0, t1, fail
    li t0, 1
    j finish
fail:
    li t0, 3
finish:
    la t1, tohost
    sw t0, 0(t1)
1:  j 1b

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
