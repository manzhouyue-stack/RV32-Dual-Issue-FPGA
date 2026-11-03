/* Snake autopilot. Copied into DDR at boot and executed through the I-cache, so
 * it must stay position independent: no calls, no static data, no jump tables.
 * Picks the move with enough reachable room (flood fill), then nearest food. */
#include <stdint.h>
#include "snake.h"

__attribute__((section(".ap_text")))
int ap_choose(const uint8_t *grid, uint16_t *queue, uint8_t *seen,
              int head, int food, int cur_dir, int length)
{
    int hx = head % BOARD_W, hy = head / BOARD_W;
    int fx = food % BOARD_W, fy = food / BOARD_W;
    int best_dir = cur_dir, best_score = -100000;

    for (int d = 0; d < 4; d++) {
        if (d == ((cur_dir + 2) & 3)) continue;
        int nx = hx + (d == DIR_RIGHT) - (d == DIR_LEFT);
        int ny = hy + (d == DIR_DOWN) - (d == DIR_UP);
        if (nx < 0 || ny < 0 || nx >= BOARD_W || ny >= BOARD_H) continue;
        int start = ny * BOARD_W + nx;
        if (grid[start] == CELL_SNAKE) continue;

        /* Flood fill: how many cells can the snake still reach after this move? */
        for (int i = 0; i < BOARD_W * BOARD_H; i++) seen[i] = 0;
        int rd = 0, wr = 0, room = 0;
        queue[wr++] = (uint16_t)start;
        seen[start] = 1;
        while (rd < wr) {
            int c = queue[rd++], x = c % BOARD_W, y = c / BOARD_W;
            room++;
            for (int k = 0; k < 4; k++) {
                int ax = x + (k == DIR_RIGHT) - (k == DIR_LEFT);
                int ay = y + (k == DIR_DOWN) - (k == DIR_UP);
                if (ax < 0 || ay < 0 || ax >= BOARD_W || ay >= BOARD_H) continue;
                int a = ay * BOARD_W + ax;
                if (seen[a] || grid[a] == CELL_SNAKE) continue;
                seen[a] = 1;
                queue[wr++] = (uint16_t)a;
            }
        }
        int dx = nx - fx, dy = ny - fy;
        int dist = (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
        int score = (room > length ? 2000 : room * 2) - dist * 2;
        if (score > best_score) {
            best_score = score;
            best_dir = d;
        }
    }
    return best_dir;
}
