/* Reproducible test fixture, not the production loader. */
    .section .boot,"ax",@progbits
    .option norvc
    .option norelax
    .globl _reset_fixture
_reset_fixture:
    lui t0, 0x1
    jalr zero, 0(t0)
