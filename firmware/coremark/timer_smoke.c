#include "timer.h"
#include "platform.h"
#include "core_portme.h"
int main(void)
{
    platform_init();
    if (mmio_read32(TIMER_HZ) != EXPECTED_HZ) platform_finish(15);
    uint64_t first = cycle_read64();
    for (volatile uint32_t i = 0; i < 1000; ++i) __asm__ volatile ("nop");
    uint64_t second = cycle_read64();
    if (second <= first) platform_finish(21);
    ee_printf("TIMER_SMOKE FIRST="); print_hex64(first);
    ee_printf(" SECOND="); print_hex64(second);
    ee_printf(" DELTA="); print_hex64(second - first);
    ee_printf(" HZ=%u\n", EXPECTED_HZ);
    platform_finish(1);
}
