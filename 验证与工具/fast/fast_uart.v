`timescale 1ns/1ps
// Instant UART stand-in for fast simulation (see fast_ram.v header).
module uart_transport(
    input clk, input rst_n, input tx_en, input rx_en,
    input [23:0] baud_inc, input baud_restart,
    input tx_push, input [7:0] tx_data, output tx_push_ready,
    input rx_pop, output [7:0] rx_data, output rx_avail,
    output tx_full, output tx_empty, output reg tx_busy, output rx_busy, output rx_line_idle,
    output [4:0] tx_level, output [4:0] rx_level,
    output reg rx_overrun_event, output reg frame_error_event,
    input uart_rx, output reg uart_tx
);
    assign tx_push_ready = 1'b1;
    assign tx_full = 1'b0;
    assign tx_empty = 1'b1;
    assign rx_data = 8'h00;
    assign rx_avail = 1'b0;
    assign rx_busy = 1'b0;
    assign rx_line_idle = 1'b1;
    assign tx_level = 0;
    assign rx_level = 0;
    initial begin tx_busy = 0; rx_overrun_event = 0; frame_error_event = 0; uart_tx = 1; end
    always @(posedge clk) if (rst_n && tx_push) $write("%c", tx_data);
endmodule
