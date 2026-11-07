    .section .text.start,"ax",@progbits
    .option norvc
    .option norelax
    .globl _start
    .type _start,@function
_start:
    la sp, __stack_top
    la gp, __global_pointer$

    /* Restore .data on EVERY reset; KEY0 does not reload RAM contents. */
    la t0, __data_load_start
    la t1, __data_start
    la t2, __data_end
1:
    bgeu t1, t2, 2f
    lw t3, 0(t0)
    sw t3, 0(t1)
    addi t0, t0, 4
    addi t1, t1, 4
    j 1b
2:
    la t1, __bss_start
    la t2, __bss_end
3:
    bgeu t1, t2, 4f
    sw zero, 0(t1)
    addi t1, t1, 4
    j 3b
4:
    call main
5:
    j 5b
    .size _start, .-_start
