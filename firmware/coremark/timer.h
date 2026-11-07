#ifndef COREMARK_TIMER_H
#define COREMARK_TIMER_H
#include <stdint.h>
#ifndef TIMER_READ32
#include "mmio.h"
#define TIMER_READ32(address) mmio_read32(address)
#endif
/* PROPOSED interface: requires B timer-enabled hardware, absent in v0.3. */
#define CYCLE_LO UINT32_C(0x10003000)
#define CYCLE_HI UINT32_C(0x10003004)
#define TIMER_HZ UINT32_C(0x10003008)
#ifndef EXPECTED_HZ
#define EXPECTED_HZ UINT32_C(50000000)
#endif
static inline uint64_t cycle_read64(void)
{
    uint32_t hi0, lo, hi1;
    do {
        hi0 = TIMER_READ32(CYCLE_HI);
        lo = TIMER_READ32(CYCLE_LO);
        hi1 = TIMER_READ32(CYCLE_HI);
    } while (hi0 != hi1);
    return ((uint64_t)hi1 << 32) | lo;
}
#endif
