#ifndef STAGE1_RISCV_TEST_H
#define STAGE1_RISCV_TEST_H

#define TESTNUM x3
#define RVTEST_RV32U
#define RVTEST_RV64U
#define RVTEST_CODE_BEGIN .section .text; .globl _start; _start:
#define RVTEST_CODE_END
#define RVTEST_DATA_BEGIN .align 4
#define RVTEST_DATA_END \
  .section .tohost,"aw",@progbits; .align 6; \
  .globl tohost; tohost: .dword 0; \
  .globl fromhost; fromhost: .dword 0
#define RVTEST_PASS \
  li TESTNUM, 1; la x31, tohost; sw TESTNUM, 0(x31); 1: j 1b
#define RVTEST_FAIL \
  slli TESTNUM, TESTNUM, 1; ori TESTNUM, TESTNUM, 1; \
  la x31, tohost; sw TESTNUM, 0(x31); 1: j 1b

#endif
