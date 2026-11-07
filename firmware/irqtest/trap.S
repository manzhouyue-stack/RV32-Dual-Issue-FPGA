/* Machine-mode trap entry for irqtest: saves caller-saved registers, calls
   trap_c(mcause, mepc, mtval) which returns the resume pc, then MRET.
   Also a vectored table (mtvec mode 1): entry i at base + 4*i. */
    .section .text,"ax",@progbits
    .option norvc
    .globl trap_entry
    .balign 64
trap_entry:
    addi sp, sp, -64
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw a0, 16(sp)
    sw a1, 20(sp)
    sw a2, 24(sp)
    sw a3, 28(sp)
    sw a4, 32(sp)
    sw a5, 36(sp)
    sw a6, 40(sp)
    sw a7, 44(sp)
    sw t3, 48(sp)
    sw t4, 52(sp)
    sw t5, 56(sp)
    sw t6, 60(sp)
    csrr a0, mcause
    csrr a1, mepc
    csrr a2, mtval
    call trap_c
    csrw mepc, a0
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw a0, 16(sp)
    lw a1, 20(sp)
    lw a2, 24(sp)
    lw a3, 28(sp)
    lw a4, 32(sp)
    lw a5, 36(sp)
    lw a6, 40(sp)
    lw a7, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 64
    mret

/* Vectored table: exceptions -> entry 0; interrupt i -> entry i. Entries
   record which slot was used (vec_hit) and then share trap_entry. */
    .globl vec_table
    .balign 256
vec_table:
    j vec_any            /* 0: exceptions */
    j vec_any            /* 1 */
    j vec_any            /* 2 */
    j vec_msi            /* 3: machine software */
    j vec_any            /* 4 */
    j vec_any            /* 5 */
    j vec_any            /* 6 */
    j vec_mti            /* 7: machine timer */
    j vec_any            /* 8 */
    j vec_any            /* 9 */
    j vec_any            /* 10 */
    j vec_any            /* 11: machine external */
vec_msi:
    addi sp, sp, -8
    sw t0, 0(sp)
    li t0, 3
    j vec_mark
vec_mti:
    addi sp, sp, -8
    sw t0, 0(sp)
    li t0, 7
    j vec_mark
vec_any:
    addi sp, sp, -8
    sw t0, 0(sp)
    li t0, 0xff
vec_mark:
    sw t1, 4(sp)
    sw t0, vec_hit, t1
    lw t1, 4(sp)
    lw t0, 0(sp)
    addi sp, sp, 8
    j trap_entry

/* Deliberate faulting instructions with fixed labels for mepc checks. */
    .globl do_illegal, do_ecall, do_ebreak, do_ld_mis, do_st_mis, do_ld_fault
do_illegal:
    .word 0x00000000
    ret
do_ecall:
    ecall
    ret
do_ebreak:
    ebreak
    ret
do_ld_mis:                /* a0 = address */
    lw a0, 0(a0)
    ret
do_st_mis:
    sw a1, 0(a0)
    ret
do_ld_fault:
    lw a0, 0(a0)
    ret
