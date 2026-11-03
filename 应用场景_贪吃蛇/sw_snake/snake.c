/* Terminal snake game console for the v1.1 SoC (application scenario, first version).
 *
 * Uses the whole system with no external peripherals beyond the UART:
 *   timer IRQ      game tick          UART RX IRQ   keyboard input (also polled)
 *   DDR3 + D-cache board, snake body and per-tick replay record
 *   DDR3 + I-cache autopilot code     traps         'f' key raises a real exception
 *   mcycle/minstret and cache counters drive the live performance panel
 *
 * Keys: w a s d / arrows move, n new game, o autopilot, p or space pause (KEY1 too),
 *       r replay, f raise an exception. SNAKE_SIM builds add k (end game), q (exit). */
#include <stdint.h>
#include "mmio.h"
#include "snake.h"

#define MTIME_LO    UINT32_C(0x10003000)
#define MTIME_HI    UINT32_C(0x10003004)
#define MTIMECMP_LO UINT32_C(0x10003010)
#define MTIMECMP_HI UINT32_C(0x10003014)
#define IRQ_EN      UINT32_C(0x1000301C)
#define GPIO_KEY    UINT32_C(0x10001004)
#define RX_AVAIL    UINT32_C(4)

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

#define CPU_HZ UINT32_C(100000000)
#define CELLS  (BOARD_W * BOARD_H)

/* DDR map: all game state lives here, so play exercises the caches. */
#define DDR_BASE  UINT32_C(0x80000000)
#define DDR_CODE  (DDR_BASE + 0x00000)
/* One way of the 8 KiB 2-way D-cache spans 4 KiB, so the four arrays share a 4 KiB
 * window: spacing them 4 KiB apart made them fight over the same sets (simulation:
 * D-cache fills fell from 15012 to 38, ticks only about 6% faster). */
#define DDR_GRID  ((uint8_t *)(DDR_BASE + 0x10000))
#define DDR_SEEN  ((uint8_t *)(DDR_BASE + 0x10240))
#define DDR_RING  ((uint16_t *)(DDR_BASE + 0x10480))
#define DDR_QUEUE ((uint16_t *)(DDR_BASE + 0x108C0))
#define DDR_REC   ((uint8_t *)(DDR_BASE + 0x100000))
#define DDR_TEST  ((volatile uint32_t *)(DDR_BASE + 0x400000))
#define REC_MAX   UINT32_C(0x100000)

#define csr_read(c) ({ uint32_t v_; __asm__ volatile ("csrr %0, " #c : "=r"(v_)); v_; })
#define csr_write(c, v) __asm__ volatile ("csrw " #c ", %0" :: "r"(v))
#define csr_set(c, v) __asm__ volatile ("csrs " #c ", %0" :: "r"(v))
#define csr_clear(c, v) __asm__ volatile ("csrc " #c ", %0" :: "r"(v))

extern void trap_entry(void);
extern void do_illegal(void), do_ecall(void);
extern uint32_t do_ld_mis(uint32_t addr);
extern int ap_choose(const uint8_t *, uint16_t *, uint8_t *, int, int, int, int);
extern char __ap_start[], __ap_end[];
typedef int (*ap_fn_t)(const uint8_t *, uint16_t *, uint8_t *, int, int, int, int);
static ap_fn_t ap_fn;

volatile uint32_t vec_hit;   /* referenced by the shared trap.S vector table */

enum { ST_MENU, ST_PLAY, ST_PAUSE, ST_OVER, ST_REPLAY };

static volatile uint32_t tick_pending, timer_irqs, ext_irqs, exc_count;
static volatile uint32_t irq_lat_last, irq_lat_max;
static volatile uint32_t trap_cause, trap_epc, trap_tval, trap_new;
static volatile uint8_t rx_buf[32];
static volatile uint32_t rx_wr, rx_rd;
static uint64_t next_cmp;
static uint32_t tick_period;

static int state, dir, next_dir, length, head_i, score, best, autopilot, food;
static int pause_from, fault_kind;
static uint32_t rng, seed, rec_len, replay_pos, ticks_total;
static int rec_score;
static uint32_t cyc_last, cyc_max, ins_last;
static uint64_t cyc_sum, ins_sum;
static uint32_t heartbeat, panel_due;
static int key_prev;

/* ---- low level output ---- */
static void puts_u(const char *s) { while (*s) uart_send((uint8_t)*s++); }
static void put_dec(uint32_t v)
{
    char b[11];
    int i = 10;
    b[i] = 0;
    do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    puts_u(&b[i]);
}
static void put_hex(uint32_t v)
{
    for (int i = 28; i >= 0; i -= 4) uart_send("0123456789abcdef"[(v >> i) & 15]);
}
static void cursor(int row, int col)
{
    puts_u("\x1b[");
    put_dec((uint32_t)row);
    uart_send(';');
    put_dec((uint32_t)col);
    uart_send('H');
}
static void clear_eol(void) { puts_u("\x1b[K"); }

/* ---- time, interrupts ---- */
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
static void rx_pop_all(void)
{
    while (mmio_read32(UART_STATUS) & RX_AVAIL) {
        uint32_t v = mmio_read32(UART_DATA);
        if (!(v & 0x80000000u)) {
            uint32_t n = (rx_wr + 1) % sizeof rx_buf;
            if (n != rx_rd) { rx_buf[rx_wr] = (uint8_t)v; rx_wr = n; }
        }
    }
}
/* Called from trap_entry; returns the pc to resume at. */
uint32_t trap_c(uint32_t cause, uint32_t epc, uint32_t tval)
{
    if (cause == 0x80000007u) {
        uint32_t lat = (uint32_t)mtime() - (uint32_t)next_cmp;
        irq_lat_last = lat;
        if (lat > irq_lat_max) irq_lat_max = lat;
        timer_irqs++;
        tick_pending = 1;
        next_cmp += tick_period;
        uint64_t now = mtime();
        if (next_cmp < now) next_cmp = now + tick_period;   /* long tick: skip, do not storm */
        set_mtimecmp(next_cmp);
        return epc;
    }
    if (cause == 0x8000000bu) {
        ext_irqs++;
        rx_pop_all();
        return epc;
    }
    trap_cause = cause;
    trap_epc = epc;
    trap_tval = tval;
    trap_new = 1;
    exc_count++;
    return epc + 4;                      /* skip the faulting instruction */
}
static int rx_get(void)
{
    if (rx_rd == rx_wr) return -1;
    int c = rx_buf[rx_rd];
    rx_rd = (rx_rd + 1) % sizeof rx_buf;
    return c;
}

/* ---- cache helpers ---- */
static void dcache_flush(void)
{
    mmio_write32(C_CTRL, 1);
    while (mmio_read32(C_STATUS) & 2) { }
}
static void put_stat(const char *name, uint32_t v)
{
    puts_u(name);
    put_dec(v);
    puts_u("  ");
}

/* ---- drawing ---- */
#define ROW_TOP 3
#define COL_LEFT 3
#define COL_PANEL (COL_LEFT + BOARD_W * 2 + 4)

static void draw_cell(int pos, const char *s)
{
    cursor(ROW_TOP + pos / BOARD_W, COL_LEFT + (pos % BOARD_W) * 2);
    puts_u(s);
}
static void draw_status(void)
{
    static const char *const names[] = { "MENU  ", "PLAY  ", "PAUSED", "OVER  ", "REPLAY" };
    cursor(1, COL_LEFT);
    puts_u("RISC-V SNAKE  score ");
    put_dec((uint32_t)score);
    puts_u("  best ");
    put_dec((uint32_t)best);
    puts_u("  ");
    puts_u(names[state]);
    puts_u(autopilot ? "  AUTO" : "      ");
    clear_eol();
}
static void draw_msg(const char *a, uint32_t v, const char *b)
{
    cursor(ROW_TOP + BOARD_H + 1, COL_LEFT);
    puts_u(a);
    if (a[0] && v != UINT32_MAX) put_dec(v);
    puts_u(b);
    clear_eol();
}
static void draw_frame(void)
{
    puts_u("\x1b[2J\x1b[?25l");
    draw_status();
    cursor(ROW_TOP - 1, COL_LEFT - 1);
    uart_send('+');
    for (int i = 0; i < BOARD_W * 2; i++) uart_send('-');
    uart_send('+');
    for (int y = 0; y < BOARD_H; y++) {
        cursor(ROW_TOP + y, COL_LEFT - 1);
        uart_send('|');
        cursor(ROW_TOP + y, COL_LEFT + BOARD_W * 2);
        uart_send('|');
    }
    cursor(ROW_TOP + BOARD_H, COL_LEFT - 1);
    uart_send('+');
    for (int i = 0; i < BOARD_W * 2; i++) uart_send('-');
    uart_send('+');
    cursor(ROW_TOP + BOARD_H + 2, COL_LEFT);
    puts_u("wasd/arrows move  n new  o auto  p pause  r replay  f raise exception");
}
static void panel_line(int row, const char *name, uint32_t v, const char *unit)
{
    cursor(ROW_TOP + row, COL_PANEL);
    puts_u(name);
    put_dec(v);
    puts_u(unit);
    clear_eol();
}
static void draw_panel(void)
{
    uint32_t ipc = cyc_sum ? (uint32_t)(ins_sum * 100 / cyc_sum) : 0;
    uint32_t ih = mmio_read32(C_IC_HITS), iff = mmio_read32(C_IC_FILLS);
    uint32_t dh = mmio_read32(C_DC_HITS), df = mmio_read32(C_DC_FILLS);
    uint32_t lines = mmio_read32(C_LINES), busy = mmio_read32(C_BUSY);
    panel_line(0, "tick cycles   ", cyc_last, "");
    panel_line(1, "tick max      ", cyc_max, "");
    panel_line(2, "tick instrs   ", ins_last, "");
    panel_line(3, "avg IPC x100  ", ipc, "");
    panel_line(4, "irq lat last  ", irq_lat_last, " cyc");
    panel_line(5, "irq lat max   ", irq_lat_max, " cyc");
    panel_line(6, "timer irqs    ", timer_irqs, "");
    panel_line(7, "uart irqs     ", ext_irqs, "");
    panel_line(8, "exceptions    ", exc_count, "");
    panel_line(10, "I$ hits       ", ih, "");
    panel_line(11, "I$ fills      ", iff, "");
    panel_line(12, "D$ hits       ", dh, "");
    panel_line(13, "D$ fills      ", df, "");
    panel_line(14, "D$ writebacks ", mmio_read32(C_DC_WBS), "");
    panel_line(15, "bus lines     ", lines, "");
    panel_line(16, "cyc/line      ", lines ? busy / lines : 0, "");
}

/* ---- game ---- */
static uint32_t rng_next(void)
{
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}
static void place_food(void)
{
    int p = (int)(rng_next() % CELLS);
    for (int i = 0; i < CELLS; i++) {
        if (DDR_GRID[p] == CELL_EMPTY) {
            food = p;
            DDR_GRID[p] = CELL_FOOD;
            draw_cell(p, "**");
            return;
        }
        p = (p + 1) % CELLS;
    }
    food = -1;
}
static void game_init(uint32_t game_seed)
{
    seed = game_seed;
    rng = seed;
    for (int i = 0; i < CELLS; i++) DDR_GRID[i] = CELL_EMPTY;
    draw_frame();
    dir = next_dir = DIR_RIGHT;
    length = 3;
    head_i = length - 1;
    score = 0;
    int start = BOARD_H / 2 * BOARD_W + BOARD_W / 2 - 2;
    for (int i = 0; i < length; i++) {
        DDR_RING[i] = (uint16_t)(start + i);
        DDR_GRID[start + i] = CELL_SNAKE;
        draw_cell(start + i, i == length - 1 ? "@@" : "[]");
    }
    place_food();
}
/* One game step. Returns 0 when the snake dies. */
static int game_step(int d)
{
    int head = DDR_RING[head_i];
    int x = head % BOARD_W + (d == DIR_RIGHT) - (d == DIR_LEFT);
    int y = head / BOARD_W + (d == DIR_DOWN) - (d == DIR_UP);
    if (x < 0 || y < 0 || x >= BOARD_W || y >= BOARD_H) return 0;
    int to = y * BOARD_W + x;
    int ate = to == food;
    int tail = DDR_RING[(head_i - length + 1 + CELLS) % CELLS];
    if (DDR_GRID[to] == CELL_SNAKE && to != tail) return 0;
    if (!ate) {
        DDR_GRID[tail] = CELL_EMPTY;
        draw_cell(tail, "  ");
    } else {
        length++;
        score++;
    }
    draw_cell(head, "[]");
    head_i = (head_i + 1) % CELLS;
    DDR_RING[head_i] = (uint16_t)to;
    DDR_GRID[to] = CELL_SNAKE;
    draw_cell(to, "@@");
    dir = d;
    if (ate) {
        place_food();
        draw_status();
    }
    return 1;
}
static void set_speed(void)
{
#ifdef SNAKE_SIM
    tick_period = 100000;
#else
    int ms = state == ST_REPLAY ? 30 : 160 - 4 * score;
    tick_period = (uint32_t)(ms < 60 ? 60 : ms) * (CPU_HZ / 1000);
#endif
}
static void new_game(void)
{
    uint32_t s = (uint32_t)mtime() | 1u;
    state = ST_PLAY;
    game_init(s);
    rec_len = 0;
    set_speed();
    draw_status();
    draw_msg("", 0, "");
}
static void end_game(void)
{
    state = ST_OVER;
    rec_score = score;
    if (score > best) best = score;
    draw_status();
    draw_msg("GAME OVER  score ", (uint32_t)score, "  n new game, r replay");
}
static void start_replay(void)
{
    if (!rec_len) {
        draw_msg("no recorded game yet", UINT32_MAX, "");
        return;
    }
    state = ST_REPLAY;
    replay_pos = 0;
    game_init(seed);
    set_speed();
    draw_status();
}
static void end_replay(void)
{
    int ok = score == rec_score;
    state = ST_OVER;
    draw_status();
    draw_msg(ok ? "REPLAY OK  from DDR, score " : "REPLAY BAD score ", (uint32_t)score, ok ? " matches" : " differs");
#ifdef SNAKE_SIM
    puts_u("\r\nSIM_REPLAY ");
    puts_u(ok ? "OK\r\n" : "BAD\r\n");
#endif
}
static void toggle_pause(void)
{
    if (state == ST_PLAY || state == ST_REPLAY) {
        pause_from = state;
        state = ST_PAUSE;
    } else if (state == ST_PAUSE) {
        state = pause_from;
    }
    draw_status();
}
static void raise_exception(void)
{
    /* Deliberately faulting instructions: the trap handler must recover. */
    switch (fault_kind++ % 3) {
    case 0: do_illegal(); break;
    case 1: do_ecall(); break;
    default: (void)do_ld_mis(DDR_BASE + 1); break;
    }
}
static void set_dir(int d)
{
    if (d != ((dir + 2) & 3)) next_dir = d;
}
static void handle_key(int c)
{
    static int esc;
    if (esc == 1) { esc = c == '[' ? 2 : 0; return; }
    if (esc == 2) {
        esc = 0;
        if (c == 'A') set_dir(DIR_UP);
        else if (c == 'B') set_dir(DIR_DOWN);
        else if (c == 'C') set_dir(DIR_RIGHT);
        else if (c == 'D') set_dir(DIR_LEFT);
        return;
    }
    switch (c) {
    case 27: esc = 1; break;
    case 'w': case 'W': set_dir(DIR_UP); break;
    case 's': case 'S': set_dir(DIR_DOWN); break;
    case 'a': case 'A': set_dir(DIR_LEFT); break;
    case 'd': case 'D': set_dir(DIR_RIGHT); break;
    case 'n': case 'N': new_game(); break;
    case 'o': case 'O': autopilot = !autopilot; draw_status(); break;
    case 'p': case 'P': case ' ': toggle_pause(); break;
    case 'r': case 'R': if (state == ST_OVER || state == ST_MENU) start_replay(); break;
    case 'f': case 'F': raise_exception(); break;
#ifdef SNAKE_SIM
    case 'k': if (state == ST_PLAY) end_game(); break;
    case 'q':
        puts_u("\r\nSIM_STATS ticks=");
        put_dec(ticks_total);
        puts_u(" score=");
        put_dec((uint32_t)score);
        puts_u(" timer=");
        put_dec(timer_irqs);
        puts_u(" uart=");
        put_dec(ext_irqs);
        puts_u(" exc=");
        put_dec(exc_count);
        puts_u(" latmax=");
        put_dec(irq_lat_max);
        puts_u(" ichits=");
        put_dec(mmio_read32(C_IC_HITS));
        puts_u(" dchits=");
        put_dec(mmio_read32(C_DC_HITS));
        puts_u("\r\n");
        while (!uart_idle()) { }
        mmio_write32(SIM_RESULT, 1);
        break;
#endif
    default: break;
    }
}
static void play_tick(void)
{
    uint32_t c0 = csr_read(mcycle), i0 = csr_read(minstret);
    int d = next_dir, alive;
    if (autopilot) {
        d = ap_fn(DDR_GRID, DDR_QUEUE, DDR_SEEN, DDR_RING[head_i], food, dir, length);
        next_dir = d;
    }
    if (rec_len < REC_MAX) DDR_REC[rec_len++] = (uint8_t)d;
    uint32_t c1 = csr_read(mcycle), i1 = csr_read(minstret);
    alive = game_step(d);
    cyc_last = c1 - c0;
    ins_last = i1 - i0;
    cyc_sum += cyc_last;
    ins_sum += ins_last;
    if (cyc_last > cyc_max) cyc_max = cyc_last;
    set_speed();
    if (!alive || food < 0) end_game();
}
static void replay_tick(void)
{
    if (replay_pos >= rec_len) { end_replay(); return; }
    if (!game_step(DDR_REC[replay_pos++])) end_replay();
}

static void report_trap(void)
{
    if (!trap_new) return;
    trap_new = 0;
    cursor(ROW_TOP + BOARD_H + 1, COL_LEFT);
    puts_u("TRAP handled, game continues: mcause=");
    put_dec(trap_cause);
    puts_u(" mepc=0x");
    put_hex(trap_epc);
    puts_u(" mtval=0x");
    put_hex(trap_tval);
    clear_eol();
}

/* ---- boot ---- */
static void boot_selftest(void)
{
    /* 64 KiB = 8x the D-cache: every line is filled and evicted through the bus. */
    const uint32_t n = 16384;
    uint32_t bad = 0;
    mmio_write32(C_CTRL, 4);
    uint32_t c0 = csr_read(mcycle);
    for (uint32_t i = 0; i < n; i++) DDR_TEST[i] = i * 0x9e3779b9u;
    for (uint32_t i = 0; i < n; i++) if (DDR_TEST[i] != i * 0x9e3779b9u) bad++;
    uint32_t cyc = csr_read(mcycle) - c0;
    uint32_t lines = mmio_read32(C_LINES), busy = mmio_read32(C_BUSY);
    puts_u(bad ? "DDR3 self-test FAIL  bad=" : "DDR3 self-test PASS  bad=");
    put_dec(bad);
    puts_u("\r\n  ");
    put_stat("cycles=", cyc);
    put_stat("bus_lines=", lines);
    put_stat("bus_busy=", busy);
    put_stat("cyc_per_64B_line=", lines ? busy / lines : 0);
    puts_u("\r\n  ");
    put_stat("dc_hits=", mmio_read32(C_DC_HITS));
    put_stat("dc_fills=", mmio_read32(C_DC_FILLS));
    put_stat("dc_wb=", mmio_read32(C_DC_WBS));
    puts_u("\r\n");
}
static void install_autopilot(void)
{
    const uint32_t *src = (const uint32_t *)__ap_start;
    volatile uint32_t *dst = (volatile uint32_t *)DDR_CODE;
    uint32_t len = (uint32_t)(__ap_end - __ap_start) / 4;
    for (uint32_t i = 0; i < len; i++) dst[i] = src[i];
    dcache_flush();
    __asm__ volatile ("fence.i" ::: "memory");
    ap_fn = (ap_fn_t)(DDR_CODE + ((uint32_t)ap_choose - (uint32_t)__ap_start));
}

int main(void)
{
    mmio_write32(UART_CTRL, 0);
    mmio_write32(UART_BAUD, UART_NCO_50MHZ_115200);
    mmio_write32(UART_CTRL, 7);
    puts_u("\x1b[2J\x1b[H\r\nRISC-V SNAKE console  (RV32IM+Zba/Zbb/Zbs dual-issue, I/D cache, DDR3)\r\n");
    while (!(mmio_read32(C_STATUS) & 1)) { }
    boot_selftest();
    install_autopilot();

    csr_write(mtvec, (uint32_t)trap_entry);
    tick_period = 100000;
#ifndef SNAKE_SIM
    tick_period = 16 * (CPU_HZ / 100);
#endif
    next_cmp = mtime() + tick_period;
    set_mtimecmp(next_cmp);
    mmio_write32(IRQ_EN, 1);             /* UART RX -> external interrupt */
    csr_set(mie, (1u << 7) | (1u << 11));
    csr_set(mstatus, 8u);
    mmio_write32(C_CTRL, 4);

    puts_u("READY: press n for a new game, o then n for autopilot\r\n");
    state = ST_MENU;
    key_prev = (int)mmio_read32(GPIO_KEY) & 1;
    for (;;) {
        /* Polling backs up the RX interrupt; masked so it cannot race the handler. */
        csr_clear(mstatus, 8u);
        rx_pop_all();
        csr_set(mstatus, 8u);
        for (int c; (c = rx_get()) >= 0; ) {
            handle_key(c);
            report_trap();
        }

        int key = (int)mmio_read32(GPIO_KEY) & 1;
        if (key && !key_prev) toggle_pause();
        key_prev = key;

        if (tick_pending) {
            tick_pending = 0;
            ticks_total++;
            heartbeat = !heartbeat;
            mmio_write32(GPIO_LED, (heartbeat << 7) | ((uint32_t)autopilot << 6) | ((uint32_t)score & 0x3f));
            if (state == ST_PLAY) play_tick();
            else if (state == ST_REPLAY) replay_tick();
            if (state != ST_MENU && ++panel_due >= 8) {
                panel_due = 0;
                draw_panel();
            }
        }
    }
}
