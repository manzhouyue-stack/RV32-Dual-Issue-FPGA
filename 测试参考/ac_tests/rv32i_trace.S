    .section .text
    .globl _start
_start:
    lui s0, 0x80002
    addi t0, zero, 7
    addi t1, t0, 5
    add t2, t1, t0
    sw t2, 0(s0)
    lw t3, 0(s0)
    add t4, t3, t0
    addi t5, zero, 26
    bne t4, t5, fail
    beq t4, t5, branch_ok
    sw t0, 4(s0)          // wrong path: must never write
    addi a0, zero, 99    // wrong path: must never retire
branch_ok:
    jal ra, jump_ok
    sw t0, 8(s0)          // wrong path: must never write
    addi a0, zero, 88    // wrong path: must never retire
jump_ok:
    lw a1, 0(s0)
    bne a1, t2, fail
    lw a2, 4(s0)
    bne a2, zero, fail
    lw a3, 8(s0)
    bne a3, zero, fail
    addi a0, zero, 1
    j finish
fail:
    addi a0, zero, 3
finish:
    la t6, tohost
    sw a0, 0(t6)
1:  j 1b

    .section .tohost,"aw",@progbits
    .align 6
    .globl tohost
tohost:
    .dword 0
    .globl fromhost
fromhost:
    .dword 0
