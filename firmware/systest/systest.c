/* v1.1 board system test: DDR3 + caches, then exceptions/interrupts.
 * RESULT=1 (LED0) only if both parts pass; 3 otherwise. */
#include <stdint.h>
#include "mmio.h"
int ddrtest_main(void);
int irqtest_main(void);
static void puts_u(const char *s) { while (*s) uart_send((uint8_t)*s++); }
int main(void)
{
    int f = ddrtest_main();
    f += irqtest_main();
    puts_u(f ? "SYSTEST FAIL\r\n" : "SYSTEST PASS\r\n");
    while (!uart_idle()) { }
    mmio_write32(GPIO_LED, f ? 2 : 1);
    mmio_write32(SIM_RESULT, f ? 3 : 1);
    for (;;) { }
}
