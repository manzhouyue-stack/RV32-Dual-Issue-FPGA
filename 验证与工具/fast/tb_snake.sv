`timescale 1ns/1ps
// Snake console bench: frozen v1.1 SoC, DDR behavioral model and the real
// uart_transport. Drives keys over serial RX and KEY1, decodes TX into
// snake_tx.log, and fails on any CPU fault or a bad replay.
module tb_snake;
    reg clk = 0, rst_n = 0, aclk = 0, key1_n = 1, rx_line = 1;
    always #5 clk = ~clk;
    always #4 aclk = ~aclk;
    wire ddr_init_done, awready, awvalid, wready, arready, arvalid, rlast, rvalid;
    wire [27:0] awaddr, araddr;
    wire [3:0] awlen, arlen;
    wire [255:0] wdata, rdata;
    wire [31:0] wstrb;
    ddr_axi_model ddr(.aclk(aclk), .arst_n(rst_n), .init_done(ddr_init_done),
        .axi_awaddr(awaddr), .axi_awlen(awlen), .axi_awready(awready), .axi_awvalid(awvalid),
        .axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wready(wready),
        .axi_araddr(araddr), .axi_arlen(arlen), .axi_arready(arready), .axi_arvalid(arvalid),
        .axi_rdata(rdata), .axi_rlast(rlast), .axi_rvalid(rvalid));
    wire uart_tx, finished, fault_valid;
    wire [31:0] result, fault_pc, fault_instr, fault_addr;
    wire [3:0] fault_cause;
    wire [7:0] led;
    soc_stage1_core dut(.clk(clk), .rst_n(rst_n), .key1_n(key1_n), .uart_rx(rx_line), .uart_tx(uart_tx), .led(led),
        .sim_result(result), .sim_exit_valid(finished),
        .fault_valid(fault_valid), .fault_cause(fault_cause),
        .fault_pc(fault_pc), .fault_instr(fault_instr), .fault_addr(fault_addr),
        .retire_valid(), .retire_pc(), .retire_instr(), .retire_rd_data(), .retire_rd_we(), .retire_rd(),
        .retire_mem_valid(), .retire_mem_we(), .retire_mem_addr(), .retire_mem_wdata(), .retire_mem_be(),
        .retire1_valid(), .retire1_pc(), .retire1_instr(), .retire1_rd_data(), .retire1_rd_we(), .retire1_rd(),
        .retire1_mem_valid(), .retire1_mem_we(), .retire1_mem_addr(), .retire1_mem_wdata(), .retire1_mem_be(),
        .aclk(aclk), .arst_n(rst_n), .ddr_init_done(ddr_init_done),
        .axi_awaddr(awaddr), .axi_awuser_ap(), .axi_awuser_id(), .axi_awlen(awlen),
        .axi_awready(awready), .axi_awvalid(awvalid), .axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wready(wready),
        .axi_araddr(araddr), .axi_aruser_ap(), .axi_aruser_id(), .axi_arlen(arlen),
        .axi_arready(arready), .axi_arvalid(arvalid), .axi_rdata(rdata), .axi_rlast(rlast), .axi_rvalid(rvalid));

    localparam real BIT_NS = 1.0e9 / 921600.0;
    integer log_fd, tx_bytes = 0;
    reg saw_ready = 0, saw_replay_ok = 0, saw_replay_bad = 0, saw_trap = 0, saw_over = 0, saw_auto = 0;
    reg [8*12-1:0] tail = 0;
    integer paused_count = 0;

    // TX decoder
    initial begin : txdec
        reg [7:0] ch;
        integer b;
        log_fd = $fopen("snake_tx.log", "w");
        forever begin
            @(negedge uart_tx);
            #(BIT_NS / 2.0);
            if (uart_tx !== 1'b0) begin $display("SNAKE_FAIL start bit"); $finish; end
            for (b = 0; b < 8; b = b + 1) begin
                #(BIT_NS);
                ch[b] = uart_tx;
            end
            #(BIT_NS);
            if (uart_tx !== 1'b1) begin $display("SNAKE_FAIL stop bit"); $finish; end
            $fwrite(log_fd, "%c", ch);
            tx_bytes = tx_bytes + 1;
            tail = {tail[8*11-1:0], ch};
            if (tail[8*6-1:0] == "READY:") saw_ready = 1;
            if (tail[8*6-1:0] == "PAUSED") paused_count = paused_count + 1;
            if (tail[8*9-1:0] == "REPLAY OK") saw_replay_ok = 1;
            if (tail[8*10-1:0] == "REPLAY BAD") saw_replay_bad = 1;
            if (tail[8*12-1:0] == "TRAP handled") saw_trap = 1;
            if (tail[8*9-1:0] == "GAME OVER") saw_over = 1;
            if (tail[8*4-1:0] == "AUTO") saw_auto = 1;
        end
    end

    task send(input [7:0] ch);
        integer b;
        begin
            rx_line = 0;
            #(BIT_NS);
            for (b = 0; b < 8; b = b + 1) begin
                rx_line = ch[b];
                #(BIT_NS);
            end
            rx_line = 1;
            #(BIT_NS);
            $display("KEY '%c' at %0t tx_bytes=%0d led=%b", ch, $time, tx_bytes, led);
        end
    endtask
    task key1_press;
        begin
            key1_n = 0;
            #12ms;
            key1_n = 1;
            #12ms;
            $display("KEY1 pressed at %0t", $time);
        end
    endtask

    integer failures = 0;
    initial begin
        repeat (20) @(negedge clk);
        rst_n = 1;
        wait (saw_ready);
        $display("BOOT OK at %0t tx_bytes=%0d", $time, tx_bytes);
        send("n");
        #3ms;
        // serial arrows and letters, turning clear of the walls
        send("s"); #2ms;
        send(8'h1b); send("["); send("C"); #1ms;
        // autopilot through the DDR-resident code keeps the snake alive from here on
        send("o");
        #10ms;
        if (!saw_auto) begin $display("SNAKE_FAIL AUTO not shown"); failures++; end
        // exceptions: illegal, ecall, misaligned load
        send("f"); #10ms;
        if (!saw_trap) begin $display("SNAKE_FAIL no trap line after f"); failures++; end
        send("f"); #10ms;
        send("f"); #10ms;
        // pause by key, then by KEY1
        send("p"); #10ms;
        if (paused_count != 1) begin $display("SNAKE_FAIL p did not pause"); failures++; end
        send("p"); #10ms;
        key1_press;
        if (paused_count != 2) begin $display("SNAKE_FAIL KEY1 did not pause"); failures++; end
        key1_press;
        #100ms;
        if (saw_over) begin $display("SNAKE_FAIL died under autopilot"); failures++; end
        send("k");
        #3ms;
        if (!saw_over) begin $display("SNAKE_FAIL no game over"); failures++; end
        send("r");
        wait (saw_replay_ok || saw_replay_bad);
        if (saw_replay_bad) begin $display("SNAKE_FAIL replay"); failures++; end
        #3ms;
        send("q");
        wait (finished);
        #1us;
        $display("SNAKE_RESULT result=%0d failures=%0d tx_bytes=%0d time=%0t", result, failures, tx_bytes, $time);
        if (failures == 0 && result == 1) $display("SNAKE_PASS");
        $fclose(log_fd);
        $finish;
    end
    always @(posedge clk) if (rst_n && fault_valid) begin
        $display("SNAKE_FAIL cpu fault cause=%0d pc=%h instr=%h addr=%h", fault_cause, fault_pc, fault_instr, fault_addr);
        $finish;
    end
    initial begin #1s; $display("SNAKE_FAIL timeout tx_bytes=%0d", tx_bytes); $finish; end
endmodule
