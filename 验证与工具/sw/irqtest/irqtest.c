/* Machine-mode exception and interrupt self-test for the v1.0 SoC.
 * Prints one line per check over UART; RESULT=1 (LED0) if all pass, 3 if not. */
#include <stdint.h>
#include "mmio.h"

#define MTIME_LO     UINT32_C(0x10003000)
#define MTIME_HI     UINT32_C(0x10003004)
#define MTIMECMP_LO  UINT32_C(0x10003010)
#define MTIMECMP_HI  UINT32_C(0x10003014)
#define MSIP         UINT32_C(0x10003018)

#define csr_read(c) ({ uint32_t v_; __asm__ volatile ("csrr %0, " #c : "=r"(v_)); v_; })
#define csr_write(c, v) __asm__ volatile ("csrw " #c ", %0" :: "r"(v))
#define csr_set(c, v) __asm__ volatile ("csrs " #c ", %0" :: "r"(v))
#define csr_clear(c, v) __asm__ volatile ("csrc " #c ", %0" :: "r"(v))

extern void trap_entry(void), vec_table(void);
extern void do_illegal(void), do_ecall(void), do_ebreak(void);
extern uint32_t do_ld_mis(uint32_t addr), do_ld_fault(uint32_t addr);
extern void do_st_mis(uint32_t addr, uint32_t value);

volatile uint32_t vec_hit;
static volatile uint32_t last_cause, last_epc, last_tval, traps, timer_irqs, soft_irqs;
static volatile uint32_t timer_period = 3000, timer_limit = 5;
static int failures;

static void puts_u(const char *s) { while (*s) uart_send((uint8_t)*s++); }
static void put_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) uart_send("0123456789abcdef"[(v >> i) & 15]);
}
static void check(const char *name, int ok, uint32_t got)
{
    puts_u(ok ? "PASS " : "FAIL ");
    puts_u(name);
    puts_u(" 0x");
    put_hex(got);
    puts_u("\r\n");
    if (!ok) failures++;
}
static uint64_t mtime(void)
{
    uint32_t hi, lo;
    do { hi = mmio_read32(MTIME_HI); lo = mmio_read32(MTIME_LO); } while (hi != mmio_read32(MTIME_HI));
    return ((uint64_t)hi << 32) | lo;
}
static void set_mtimecmp(uint64_t t)
{
    mmio_write32(MTIMECMP_HI, 0xffffffffu);   /* no spurious match while updating */
    mmio_write32(MTIMECMP_LO, (uint32_t)t);
    mmio_write32(MTIMECMP_HI, (uint32_t)(t >> 32));
}

/* Called from trap_entry; returns the pc to resume at. */
uint32_t trap_c(uint32_t cause, uint32_t epc, uint32_t tval)
{
    last_cause = cause;
    last_epc = epc;
    last_tval = tval;
    traps++;
    if (cause == 0x80000007u) {
        timer_irqs++;
        if (timer_irqs < timer_limit) set_mtimecmp(mtime() + timer_period);
        else set_mtimecmp(~UINT64_C(0));
        return epc;                      /* interrupts resume the interrupted instruction */
    }
    if (cause == 0x80000003u) {
        soft_irqs++;
        mmio_write32(MSIP, 0);
        return epc;
    }
    return epc + 4;                      /* skip the faulting instruction */
}

#ifdef SYSTEST
int irqtest_main(void)
#else
int main(void)
#endif
{
    uint32_t v;
    /* UART: 115200 8N1 (UART_NCO_50MHZ_115200 is overridden for the build clock) */
    mmio_write32(UART_CTRL, 0);
    mmio_write32(UART_BAUD, UART_NCO_50MHZ_115200);
    mmio_write32(UART_CTRL, 7);
    puts_u("IRQTEST v1.0\r\n");
    csr_write(mtvec, (uint32_t)trap_entry);

    /* --- CSR identity and counters */
    v = csr_read(misa);
    check("misa RV32 I M B", (v >> 30) == 1 && (v & (1u << 8)) && (v & (1u << 12)) && (v & (1u << 1)), v);
    check("mhartid 0", csr_read(mhartid) == 0, csr_read(mhartid));
    csr_write(mscratch, 0x5a5aa5a5u);
    check("mscratch rw", csr_read(mscratch) == 0x5a5aa5a5u, csr_read(mscratch));
    uint32_t c0 = csr_read(mcycle), i0 = csr_read(minstret);
    for (volatile int k = 0; k < 10; k++) { }
    uint32_t c1 = csr_read(mcycle), i1 = csr_read(minstret);
    check("mcycle advances", c1 - c0 > 20, c1 - c0);
    check("minstret advances", i1 - i0 > 20 && i1 - i0 <= c1 - c0 + 2 * 2, i1 - i0);
    uint32_t t_csr = csr_read(time), t_mmio = (uint32_t)mtime();
    check("time CSR tracks platform mtime", t_mmio - t_csr < 64, t_mmio - t_csr);

    /* --- synchronous exceptions: cause, epc, tval, resume */
    traps = 0;
    do_illegal();
    check("illegal: mcause 2", last_cause == 2, last_cause);
    check("illegal: mepc", last_epc == (uint32_t)do_illegal, last_epc);
    check("illegal: mtval=instr", last_tval == 0, last_tval);
    do_ecall();
    check("ecall: mcause 11", last_cause == 11 && last_epc == (uint32_t)do_ecall, last_cause);
    do_ebreak();
    check("ebreak: mcause 3", last_cause == 3 && last_epc == (uint32_t)do_ebreak, last_cause);
    do_ld_mis(0x10002u);
    check("load misaligned: mcause 4", last_cause == 4 && last_tval == 0x10002u, last_tval);
    do_st_mis(0x10006u, 1);
    check("store misaligned: mcause 6", last_cause == 6 && last_tval == 0x10006u, last_tval);
    do_ld_fault(0x20000000u);
    check("load access fault: mcause 5", last_cause == 5 && last_tval == 0x20000000u, last_tval);
    check("all 6 exceptions trapped", traps == 6, traps);
    check("mstatus.MIE stays 0 in handler", (csr_read(mstatus) & 8) == 0, csr_read(mstatus));

    /* --- masked interrupt must not be taken */
    traps = 0;
    csr_write(mie, 1u << 7);
    set_mtimecmp(mtime() + 50);
    for (volatile int k = 0; k < 100; k++) { }
    check("MTIP pending in mip", (csr_read(mip) & (1u << 7)) != 0, csr_read(mip));
    check("no trap while mstatus.MIE=0", traps == 0, traps);

    /* --- timer interrupts, direct mode, WFI */
    timer_irqs = 0;
    set_mtimecmp(mtime() + timer_period);
    csr_set(mstatus, 8u);
    while (timer_irqs < timer_limit) __asm__ volatile ("wfi");
    check("5 timer interrupts", timer_irqs == 5, timer_irqs);
    check("timer mcause 0x80000007", last_cause == 0x80000007u, last_cause);

    /* --- software interrupt */
    csr_write(mie, 1u << 3);
    soft_irqs = 0;
    mmio_write32(MSIP, 1);
    for (volatile int k = 0; k < 20 && soft_irqs == 0; k++) { }
    check("software interrupt taken", soft_irqs == 1 && last_cause == 0x80000003u, last_cause);

    /* --- vectored mode: interrupt 7 enters vec_table + 28 */
    csr_write(mtvec, (uint32_t)vec_table | 1u);
    csr_write(mie, 1u << 7);
    vec_hit = 0;
    timer_irqs = 0;
    timer_limit = 1;
    set_mtimecmp(mtime() + 200);
    while (timer_irqs == 0) { }
    check("vectored timer slot 7", vec_hit == 7, vec_hit);
    vec_hit = 0;
    csr_write(mie, 1u << 3);
    mmio_write32(MSIP, 1);
    for (volatile int k = 0; k < 20 && vec_hit == 0; k++) { }
    check("vectored software slot 3", vec_hit == 3, vec_hit);
    do_ecall();
    check("vectored exception -> base", vec_hit == 0xff && last_cause == 11, vec_hit);

    csr_clear(mstatus, 8u);
    csr_write(mie, 0);
    puts_u(failures ? "IRQTEST FAIL\r\n" : "IRQTEST PASS\r\n");
#ifdef SYSTEST
    return failures;
#endif
    while (!uart_idle()) { }
    mmio_write32(GPIO_LED, failures ? 2 : 1);
    mmio_write32(SIM_RESULT, failures ? 3 : 1);
    for (;;) { }
}
