#ifndef C_START_MMIO_H
#define C_START_MMIO_H
#include <stdint.h>

/* Derived from B's supplied v0.3 address/permission description.
 * This standalone small driver is not a copy of B's unavailable mmio.h. */
#define UART_DATA   UINT32_C(0x10000000)
#define UART_STATUS UINT32_C(0x10000004)
#define UART_CTRL   UINT32_C(0x10000008)
#define UART_BAUD   UINT32_C(0x1000000c)
#define GPIO_LED    UINT32_C(0x10001000)
#define SIM_RESULT  UINT32_C(0x10002000)
#define TX_FULL UINT32_C(1)
#define TX_IDLE UINT32_C(2)
#define UART_ERRORS UINT32_C(0x38)
#ifndef UART_NCO_50MHZ_115200
#define UART_NCO_50MHZ_115200 UINT32_C(618475)
#endif
#define POLL_LIMIT UINT32_C(200000)

static inline void io_fence(void)
{
    __asm__ volatile ("fence iorw, iorw" ::: "memory");
}
static inline uint32_t mmio_read32(uint32_t address)
{
    uint32_t value;
    io_fence();
    value = *(volatile uint32_t *)(uintptr_t)address;
    io_fence();
    return value;
}
static inline void mmio_write32(uint32_t address, uint32_t value)
{
    io_fence();
    *(volatile uint32_t *)(uintptr_t)address = value;
    io_fence();
}
static inline int uart_idle(void)
{
    for (uint32_t n = 0; n < POLL_LIMIT; ++n)
        if (mmio_read32(UART_STATUS) & TX_IDLE) return 1;
    return 0;
}
static inline int uart_send(uint32_t byte)
{
    for (uint32_t n = 0; n < POLL_LIMIT; ++n) {
        if (!(mmio_read32(UART_STATUS) & TX_FULL)) {
            mmio_write32(UART_DATA, byte & UINT32_C(0xff));
            return 1;
        }
    }
    return 0;
}
#endif
