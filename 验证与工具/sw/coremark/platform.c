#include "mmio.h"
#include "platform.h"
#include "core_portme.h"
void platform_finish(uint32_t result)
{
    if (!uart_idle() || (mmio_read32(UART_STATUS) & UART_ERRORS)) result = 11;
    mmio_write32(GPIO_LED, result == 1 ? 1 : 2);
    mmio_write32(SIM_RESULT, result);
    for (;;) __asm__ volatile ("nop");
}
void platform_init(void)
{
    if (!uart_idle()) platform_finish(3);
    mmio_write32(UART_CTRL, 0);
    if (mmio_read32(UART_CTRL) != 0) platform_finish(5);
    mmio_write32(UART_BAUD, UART_NCO_50MHZ_115200);
    if (mmio_read32(UART_BAUD) != UART_NCO_50MHZ_115200) platform_finish(7);
    mmio_write32(UART_CTRL, 7);
    if (mmio_read32(UART_CTRL) != 3) platform_finish(9);
}
void print_hex64(uint64_t v)
{
    ee_printf("%08x%08x", (uint32_t)(v >> 32), (uint32_t)v);
}
