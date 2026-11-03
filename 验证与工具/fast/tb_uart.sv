`timescale 1ns/1ps
// Baud check at the real system clock: actual uart_transport, 10 ns clock
// (100 MHz) unless +CLK_NS given; decode uart_tx at exactly 115200 baud and
// measure the start-bit width. Stops after the first complete text line.
module tb_uart;
    reg clk = 0, rst_n = 0;
    real half_ns;
    initial begin
        if (!$value$plusargs("CLK_NS=%f", half_ns)) half_ns = 10.0;
        half_ns = half_ns / 2.0;
        forever #(half_ns) clk = ~clk;
    end
    wire uart_tx;
    wire [7:0] led;
    soc_stage1_core dut(.clk(clk), .rst_n(rst_n), .key1_n(1'b1), .uart_rx(1'b1), .uart_tx(uart_tx), .led(led),
        .sim_result(), .sim_exit_valid(), .fault_valid(), .fault_cause(), .fault_pc(), .fault_instr(),
        .fault_addr(), .retire_valid(), .retire_pc(), .retire_instr(), .retire_rd_data(), .retire_rd_we(),
        .retire_rd(), .retire_mem_valid(), .retire_mem_we(), .retire_mem_addr(), .retire_mem_wdata(),
        .retire_mem_be());
    localparam real BIT_NS = 1.0e9 / 115200.0;
    string line = "";
    realtime t_fall, t_rise;
    initial begin : rx
        reg [7:0] ch;
        integer b;
        repeat (5) @(negedge clk);
        rst_n = 1;
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2.0);
            if (uart_tx !== 1'b0) begin $display("UART_CHECK FAIL start bit"); $finish; end
            for (b = 0; b < 8; b = b + 1) begin
                #(BIT_NS);
                ch[b] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1) begin $display("UART_CHECK FAIL stop bit"); $finish; end
            if (ch == 8'h0a) begin
                $display("UART_CHECK line=[%s] first_low_ns=%0.1f expected_bit_ns=%0.1f", line, t_rise - t_fall, BIT_NS);
                $finish;
            end else if (ch != 8'h0d) line = {line, ch};
        end
    end
    // First low pulse: start bit of 'C' (LSB 1), i.e. exactly one bit time.
    initial begin
        @(posedge rst_n);
        @(negedge uart_tx) t_fall = $realtime;
        @(posedge uart_tx) t_rise = $realtime;
    end
    initial begin #50ms; $display("UART_CHECK TIMEOUT line=[%s]", line); $finish; end
endmodule
