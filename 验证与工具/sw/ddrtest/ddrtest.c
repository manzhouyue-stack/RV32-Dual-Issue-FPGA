/* DDR3 + cache self-test for the v1.1 SoC. Prints one line per check and the
 * cache/bus statistics; RESULT=1 (LED0) if all checks pass, 3 otherwise. */
#include <stdint.h>
#include "mmio.h"

#define DDR_BASE   UINT32_C(0x80000000)
#define CREG       UINT32_C(0x10004000)
#define C_STATUS   (CREG + 0x00)
#define C_CTRL     (CREG + 0x04)
#define C_IC_HITS  (CREG + 0x08)
#define C_IC_FILLS (CREG + 0x0C)
#define C_DC_HITS  (CREG + 0x10)
#define C_DC_FILLS (CREG + 0x14)
#define C_DC_WBS   (CREG + 0x18)
#define C_BUSY     (CREG + 0x1C)
#define C_LINES    (CREG + 0x20)
#define MTIME_LO   UINT32_C(0x10003000)

extern uint32_t ddr_kernel(uint32_t n);
extern char ddr_kernel_end[];
static int failures;

static void puts_u(const char *s) { while (*s) uart_send((uint8_t)*s++); }
static void put_dec(uint32_t v)
{
    char b[11];
    int i = 10;
    b[i] = 0;
    do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    puts_u(&b[i]);
}
static void check(const char *name, int ok, uint32_t got)
{
    puts_u(ok ? "PASS " : "FAIL ");
    puts_u(name);
    puts_u(" ");
    put_dec(got);
    puts_u("\r\n");
    if (!ok) failures++;
}
static void stat(const char *name, uint32_t v)
{
    puts_u("  ");
    puts_u(name);
    puts_u("=");
    put_dec(v);
    puts_u("\r\n");
}
static void dcache_flush(void)
{
    mmio_write32(C_CTRL, 1);
    while (mmio_read32(C_STATUS) & 2) { }
}
static void clear_stats(void) { mmio_write32(C_CTRL, 4); }
static void dump_stats(void)
{
    uint32_t lines = mmio_read32(C_LINES), busy = mmio_read32(C_BUSY);
    stat("ic_hits", mmio_read32(C_IC_HITS));
    stat("ic_fills", mmio_read32(C_IC_FILLS));
    stat("dc_hits", mmio_read32(C_DC_HITS));
    stat("dc_fills", mmio_read32(C_DC_FILLS));
    stat("dc_writebacks", mmio_read32(C_DC_WBS));
    stat("bus_lines_64B", lines);
    stat("bus_busy_cycles", busy);
    if (lines) stat("cycles_per_line", busy / lines);
}

#ifdef SYSTEST
int ddrtest_main(void)
#else
int main(void)
#endif
{
    /* UART: 115200 8N1 (UART_NCO_50MHZ_115200 is overridden for the build clock) */
    mmio_write32(UART_CTRL, 0);
    mmio_write32(UART_BAUD, UART_NCO_50MHZ_115200);
    mmio_write32(UART_CTRL, 7);
    puts_u("DDRTEST v1.1\r\n");
    while (!(mmio_read32(C_STATUS) & 1)) { }
    check("ddr init done", 1, mmio_read32(C_STATUS));

    /* 1. 64 KiB write/verify: 8x the D-cache, every line is evicted dirty */
    volatile uint32_t *d = (volatile uint32_t *)DDR_BASE;
    const uint32_t N = 16384;
    clear_stats();
    for (uint32_t i = 0; i < N; i++) d[i] = i * 0x9e3779b9u ^ 0x5a5a1234u;
    uint32_t bad = 0;
    for (uint32_t i = 0; i < N; i++) if (d[i] != (i * 0x9e3779b9u ^ 0x5a5a1234u)) bad++;
    check("64KiB word write/read", bad == 0, bad);
    puts_u("stats after 64KiB write+read:\r\n");
    dump_stats();
    check("dirty lines written back", mmio_read32(C_DC_WBS) > 0, mmio_read32(C_DC_WBS));

    /* 2. sub-word stores and loads */
    volatile uint8_t *b8 = (volatile uint8_t *)(DDR_BASE + 0x20000);
    volatile uint16_t *b16 = (volatile uint16_t *)(DDR_BASE + 0x20000);
    volatile uint32_t *b32 = (volatile uint32_t *)(DDR_BASE + 0x20000);
    b32[0] = 0x11223344u;
    b8[1] = 0xaa;
    b16[1] = 0xbeef;
    check("byte/half store merge", b32[0] == 0xbeefaa44u, b32[0]);
    check("signed byte load", (int8_t)b8[1] == (int8_t)0xaa, (uint32_t)(int32_t)(int8_t)b8[1]);

    /* 3. flush: data must survive write-back and be re-read from DDR */
    dcache_flush();
    clear_stats();
    bad = 0;
    for (uint32_t i = 0; i < N; i += 7) if (d[i] != (i * 0x9e3779b9u ^ 0x5a5a1234u)) bad++;
    check("re-read after flush", bad == 0, bad);
    check("flush forced refills", mmio_read32(C_DC_FILLS) > 0, mmio_read32(C_DC_FILLS));
    check("sub-word data after flush", b32[0] == 0xbeefaa44u, b32[0]);

    /* 4. execute code from DDR through the I-cache */
    uint32_t len = (uint32_t)(ddr_kernel_end - (char *)ddr_kernel);
    volatile uint32_t *code = (volatile uint32_t *)(DDR_BASE + 0x100000);
    const uint32_t *src = (const uint32_t *)ddr_kernel;
    for (uint32_t i = 0; i < len / 4; i++) code[i] = src[i];
    dcache_flush();                      /* code reaches DDR */
    mmio_write32(C_CTRL, 2);             /* drop stale I-cache lines */
    __asm__ volatile ("fence.i" ::: "memory");
    clear_stats();
    uint32_t (*fn)(uint32_t) = (uint32_t (*)(uint32_t))(DDR_BASE + 0x100000);
    uint32_t want = ddr_kernel(1000), got = fn(1000);
    check("run code from DDR", got == want, got);
    check("I-cache served the loop", mmio_read32(C_IC_HITS) > 1000 && mmio_read32(C_IC_FILLS) <= 2,
          mmio_read32(C_IC_HITS));

    /* 5. bandwidth: cold streaming read vs cache-resident re-read */
    uint32_t t0, t1, sum = 0;
    dcache_flush();
    clear_stats();
    t0 = mmio_read32(MTIME_LO);
    for (uint32_t i = 0; i < 4096; i++) sum += d[i];          /* 16 KiB, all misses */
    t1 = mmio_read32(MTIME_LO);
    puts_u("cold read 16KiB:\r\n");
    stat("cycles", t1 - t0);
    stat("bytes_per_100_cycles", (16384u * 100u) / (t1 - t0));
    dump_stats();
    clear_stats();
    t0 = mmio_read32(MTIME_LO);
    for (int r = 0; r < 4; r++)
        for (uint32_t i = 0; i < 1024; i++) sum += d[i];      /* 4 KiB, resident */
    t1 = mmio_read32(MTIME_LO);
    puts_u("warm read 4KiB x4:\r\n");
    stat("cycles", t1 - t0);
    dump_stats();
    check("warm pass hit rate >= 99%", mmio_read32(C_DC_HITS) >= 4096u * 99u / 100u, mmio_read32(C_DC_HITS));
    check("checksum", sum != 0, sum);

    puts_u(failures ? "DDRTEST FAIL\r\n" : "DDRTEST PASS\r\n");
#ifdef SYSTEST
    return failures;
#endif
    while (!uart_idle()) { }
    mmio_write32(GPIO_LED, failures ? 2 : 1);
    mmio_write32(SIM_RESULT, failures ? 3 : 1);
    for (;;) { }
}
