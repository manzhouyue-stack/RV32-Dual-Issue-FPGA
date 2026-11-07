/* Position-independent kernel copied into DDR and executed through the
   I-cache: a0 = n -> returns sum_{i=1..n} (i*i ^ (i << 3)). */
    .section .text,"ax",@progbits
    .option norvc
    .globl ddr_kernel, ddr_kernel_end
    .balign 64
ddr_kernel:
    li t0, 0
    li t1, 1
1:  bgt t1, a0, 2f
    mul t2, t1, t1
    slli t3, t1, 3
    xor t2, t2, t3
    add t0, t0, t2
    addi t1, t1, 1
    j 1b
2:  mv a0, t0
    ret
ddr_kernel_end:
