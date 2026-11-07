#include "coremark.h"
#include "timer.h"
#include "platform.h"
#if VALIDATION_RUN
volatile ee_s32 seed1_volatile = 0x3415, seed2_volatile = 0x3415;
#else
volatile ee_s32 seed1_volatile = 0, seed2_volatile = 0;
#endif
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;
ee_u32 default_num_contexts = 1;
static uint64_t begin_ticks, end_ticks;
extern unsigned cm_validated, cm_error;
void start_time(void) { begin_ticks = cycle_read64(); }
void stop_time(void) { end_ticks = cycle_read64(); }
CORE_TICKS get_time(void) { return end_ticks - begin_ticks; }
secs_ret time_in_secs(CORE_TICKS ticks) { return (secs_ret)(ticks / EXPECTED_HZ); }
void portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc; (void)argv;
    platform_init();
    if (mmio_read32(TIMER_HZ) != EXPECTED_HZ) platform_finish(15);
    if (sizeof(ee_ptr_int) != sizeof(void *) || sizeof(ee_u32) != 4) platform_finish(17);
    ee_printf("CM_BUILD %s iterations=%u validation=%u\n", BUILD_ID, (unsigned)ITERATIONS, (unsigned)VALIDATION_RUN);
    p->portable_id = 1;
}
void portable_fini(core_portable *p)
{
    ee_printf("CM_TICKS_HEX="); print_hex64(get_time());
    ee_printf(" TIMER_HZ=%u CPU_HZ=%u ITERATIONS=%u\n", EXPECTED_HZ, EXPECTED_HZ, (unsigned)ITERATIONS);
    ee_printf("CM_OFFICIAL_INTEGER_SECONDS; RAW_TICKS_REQUIRED_FOR_PRECISE_SCORE\n");
    p->portable_id = 0;
    /* Short CRC runs intentionally fail official duration (10 s at EXPECTED_HZ), never claim a score. */
    platform_finish(cm_validated && !cm_error && get_time() >= UINT64_C(10) * EXPECTED_HZ ? 1 : 19);
}
