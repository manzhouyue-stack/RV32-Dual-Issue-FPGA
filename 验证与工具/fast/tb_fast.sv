`timescale 1ns/1ps
// Fast CoreMark bench: actual CPU + B tcm_subsystem/mem_io_subsystem/mmio_regs/
// timer RTL, behavioral RAM and instant UART (fast_models.v). Cycle counts
// inside the timed window match the vendor-IP bench; UART time does not.
module tb_fast;
`ifdef FAST_VENDOR_RAM
    GTP_GRS GRS_INST(.GRS_N(1'b1));
`endif
    reg clk = 0, rst_n = 0;
`ifdef CPU_DDR
    // 100 MHz CPU, 125 MHz DDR controller clock (board ratio)
    always #5 clk = ~clk;
    reg aclk = 0;
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
`else
    always #10 clk = ~clk;
`endif
    wire [31:0] result, fault_pc, fault_instr, fault_addr, retire_pc, retire_instr;
    wire finished, fault_valid, retire_valid, retire1_valid;
    wire [31:0] retire1_pc, retire1_instr;
    wire [3:0] fault_cause;
    wire [7:0] led;
    soc_stage1_core dut(.clk(clk), .rst_n(rst_n), .key1_n(1'b1), .uart_rx(1'b1), .uart_tx(), .led(led),
        .sim_result(result), .sim_exit_valid(finished),
        .fault_valid(fault_valid), .fault_cause(fault_cause),
        .fault_pc(fault_pc), .fault_instr(fault_instr), .fault_addr(fault_addr),
        .retire_valid(retire_valid), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .retire_rd_data(), .retire_rd_we(), .retire_rd(),
        .retire_mem_valid(), .retire_mem_we(), .retire_mem_addr(),
        .retire_mem_wdata(), .retire_mem_be()
`ifdef CPU_DUAL
        , .retire1_valid(retire1_valid), .retire1_pc(retire1_pc), .retire1_instr(retire1_instr),
        .retire1_rd_data(), .retire1_rd_we(), .retire1_rd(), .retire1_mem_valid(), .retire1_mem_we(),
        .retire1_mem_addr(), .retire1_mem_wdata(), .retire1_mem_be()
`endif
`ifdef CPU_DDR
        , .aclk(aclk), .arst_n(rst_n), .ddr_init_done(ddr_init_done),
        .axi_awaddr(awaddr), .axi_awuser_ap(), .axi_awuser_id(), .axi_awlen(awlen),
        .axi_awready(awready), .axi_awvalid(awvalid), .axi_wdata(wdata), .axi_wstrb(wstrb), .axi_wready(wready),
        .axi_araddr(araddr), .axi_aruser_ap(), .axi_aruser_id(), .axi_arlen(arlen),
        .axi_arready(arready), .axi_arvalid(arvalid), .axi_rdata(rdata), .axi_rlast(rlast), .axi_rvalid(rvalid)
`endif
        );
`ifndef CPU_DUAL
    assign retire1_valid = 1'b0;
`endif

    integer cycles = 0, retired = 0, lo_reads = 0, win_cyc = 0, win_ret = 0;
    integer limit;
    wire lo_read = dut.cpu.ld_valid && dut.cpu.ld_ready && dut.cpu.ld_addr == 32'h10003000;
`ifdef CPU_STATS
    integer st_redir = 0, st_lu = 0, st_qempty = 0, st_br = 0, st_jalr = 0;
`endif
`ifdef CPU_TRACE
    integer tr_fd;
    initial tr_fd = $fopen("retire_trace.txt", "w");
`endif
`ifdef CPU_DUAL
    // Bring-up trace of the first cycles after reset.
    always @(negedge clk) if (rst_n && cycles < 30)
        $display("DBG c=%0d ifv=%b rdy=%b rv=%b pcf=%h f2=%b qc=%0d s0=%b s1=%b f0=%b f1=%b e=%b%b m=%b%b w=%b%b redir=%b in0=%h in1=%h stop=%b",
            cycles, dut.cpu.if_valid, dut.cpu.if_ready, dut.cpu.if_rvalid, dut.cpu.pc_f, dut.cpu.f2_valid,
            dut.cpu.q_count, dut.cpu.s_v[0], dut.cpu.s_v[1], dut.cpu.d_fire0, dut.cpu.d_fire1,
            dut.cpu.e_valid[0], dut.cpu.e_valid[1], dut.cpu.m_valid[0], dut.cpu.m_valid[1],
            dut.cpu.w_valid[0], dut.cpu.w_valid[1], dut.cpu.redirect, dut.cpu.s_in[0], dut.cpu.s_in[1], dut.cpu.stop);
`endif
    reg [31:0] last_pc = 0, last_pc1 = 0;
    always @(posedge clk) begin if (retire_valid) last_pc <= retire_pc; if (retire1_valid) last_pc1 <= retire1_pc; end
    always @(posedge clk) if (rst_n) begin
        cycles <= cycles + 1;
        retired <= retired + retire_valid + retire1_valid;
        if (lo_read) lo_reads <= lo_reads + 1;
        if (lo_reads == 1) begin
            win_cyc <= win_cyc + 1;
            win_ret <= win_ret + retire_valid + retire1_valid;
`ifdef CPU_STATS
            if (dut.cpu.ex_redirect) st_redir <= st_redir + 1;
`ifdef CPU_DUAL
            // load_use: slot 0 blocked by a load/mul in EX; id_empty: no slot 0;
            // branches: dual issues (two instructions entered EX); jalr: single issues
            if (dut.cpu.s_v[0] && dut.cpu.haz[0] && dut.cpu.e_space) st_lu <= st_lu + 1;
            if (!dut.cpu.s_v[0]) st_qempty <= st_qempty + 1;
            if (dut.cpu.d_fire1) st_br <= st_br + 1;
            if (dut.cpu.d_fire0 && !dut.cpu.d_fire1) st_jalr <= st_jalr + 1;
`else
            if (dut.cpu.d_valid && dut.cpu.load_use && dut.cpu.e_space) st_lu <= st_lu + 1;
            if (!dut.cpu.d_valid) st_qempty <= st_qempty + 1;
            if (dut.cpu.e_fire && dut.cpu.e_branch != 0) st_br <= st_br + 1;
            if (dut.cpu.e_fire && dut.cpu.e_jalr) st_jalr <= st_jalr + 1;
`endif
`endif
`ifdef CPU_TRACE
`ifdef CPU_TRACE_CYC
            if (retire_valid) $fdisplay(tr_fd, "%08x %08x %0d", retire_pc, retire_instr, cycles);
            if (retire1_valid) $fdisplay(tr_fd, "%08x %08x %0d", retire1_pc, retire1_instr, cycles);
`else
            if (retire_valid) $fdisplay(tr_fd, "%08x %08x", retire_pc, retire_instr);
            if (retire1_valid) $fdisplay(tr_fd, "%08x %08x", retire1_pc, retire1_instr);
`endif
`endif
        end
    end
    initial begin
        if (!$value$plusargs("LIMIT=%d", limit)) limit = 50000000;
        repeat (5) @(negedge clk);
        rst_n = 1;
        while (cycles < limit) begin
            @(negedge clk);
            if (fault_valid === 1'b1) begin
                $display("\nFAST_FAULT pc=%h instr=%h cause=%0d addr=%h", fault_pc, fault_instr, fault_cause, fault_addr);
                $finish;
            end
            if (finished === 1'b1) begin
                $display("\nFAST_DONE result=%0d cycles=%0d retired=%0d window_cycles=%0d window_retired=%0d CPI=%0.4f",
                    result, cycles, retired, win_cyc, win_ret, 1.0 * win_cyc / (win_ret > 0 ? win_ret : 1));
`ifdef CPU_STATS
                $display("FAST_STATS redirects=%0d load_use=%0d id_empty=%0d branches=%0d jalr=%0d",
                    st_redir, st_lu, st_qempty, st_br, st_jalr);
`endif
`ifdef CPU_TRACE
                $fclose(tr_fd);
`endif
                $finish;
            end
        end
        $display("\nFAST_TIMEOUT cycles=%0d retired=%0d last_pc=%h last_pc1=%h", cycles, retired, last_pc, last_pc1);
        $finish;
    end
endmodule
