`timescale 1ns/1ps
// v1.1 SoC core (adds the cached DDR3 region, see soc_v11/mem_io_subsystem.v):
// v1.0 SoC core: rv32_core_d (dual issue, Zicsr, M-mode traps/interrupts) +
// dual-fetch banked TCM + B's MMIO with mtimecmp/msip/IRQ_EN.
// System clock in Hz (UART default NCO, TIMER_HZ, debounce).
`ifndef SYS_CLK_HZ
`define SYS_CLK_HZ 50000000
`endif
module soc_stage1_core(
    input wire clk, rst_n, key1_n, uart_rx,
    output wire uart_tx,
    output wire [7:0] led,
    output wire [31:0] sim_result,
    output wire sim_exit_valid,
    output wire fault_valid,
    output wire [3:0] fault_cause,
    output wire [31:0] fault_pc, fault_instr, fault_addr,
    output wire retire_valid,
    output wire [31:0] retire_pc, retire_instr, retire_rd_data,
    output wire retire_rd_we,
    output wire [4:0] retire_rd,
    output wire retire_mem_valid, retire_mem_we,
    output wire [31:0] retire_mem_addr, retire_mem_wdata,
    output wire [3:0] retire_mem_be,
    output wire retire1_valid,
    output wire [31:0] retire1_pc, retire1_instr, retire1_rd_data,
    output wire retire1_rd_we,
    output wire [4:0] retire1_rd,
    output wire retire1_mem_valid, retire1_mem_we,
    output wire [31:0] retire1_mem_addr, retire1_mem_wdata,
    output wire [3:0] retire1_mem_be,
    // DDR3 controller AXI host port (aclk domain)
    input wire aclk, arst_n, ddr_init_done,
    output wire [27:0] axi_awaddr, output wire axi_awuser_ap, output wire [3:0] axi_awuser_id, output wire [3:0] axi_awlen,
    input wire axi_awready, output wire axi_awvalid, output wire [255:0] axi_wdata, output wire [31:0] axi_wstrb, input wire axi_wready,
    output wire [27:0] axi_araddr, output wire axi_aruser_ap, output wire [3:0] axi_aruser_id, output wire [3:0] axi_arlen,
    input wire axi_arready, output wire axi_arvalid, input wire [255:0] axi_rdata, input wire axi_rlast, axi_rvalid
);
    wire if_valid,if_ready,if_rvalid,if_error,if_error1;
    wire ld_valid,ld_ready,ld_rvalid,ld_error;
    wire st_valid,st_ready,st_done,st_error;
    wire [31:0] if_addr,if_rdata,if_rdata1,ld_addr,ld_maddr,ld_rdata,st_addr,st_wdata;
    wire [1:0] ld_size,st_size;
    wire [3:0] st_wstrb;
    wire [4:0] debug_valid;
    wire [63:0] mtime;
    wire irq_timer,irq_soft,irq_ext;
    rv32_core_d #(.RESET_PC(32'h00000000)) cpu(
        .clk(clk),.rst(~rst_n),.external_freeze(1'b0),
        .if_valid(if_valid),.if_addr(if_addr),.if_ready(if_ready),
        .if_rvalid(if_rvalid),.if_rdata(if_rdata),.if_error(if_error),
        .if_rdata1(if_rdata1),.if_error1(if_error1),
        .ld_valid(ld_valid),.ld_addr(ld_addr),.ld_size(ld_size),.ld_ready(ld_ready),.ld_maddr(ld_maddr),
        .ld_rvalid(ld_rvalid),.ld_rdata(ld_rdata),.ld_error(ld_error),
        .st_valid(st_valid),.st_addr(st_addr),.st_size(st_size),
        .st_wdata(st_wdata),.st_wstrb(st_wstrb),.st_ready(st_ready),
        .st_done(st_done),.st_error(st_error),
        .retire_valid(retire_valid),.retire_pc(retire_pc),.retire_instr(retire_instr),
        .retire_rd_we(retire_rd_we),.retire_rd(retire_rd),.retire_rd_data(retire_rd_data),
        .retire_mem_valid(retire_mem_valid),.retire_mem_we(retire_mem_we),
        .retire_mem_addr(retire_mem_addr),.retire_mem_wdata(retire_mem_wdata),.retire_mem_be(retire_mem_be),
        .retire1_valid(retire1_valid),.retire1_pc(retire1_pc),.retire1_instr(retire1_instr),
        .retire1_rd_we(retire1_rd_we),.retire1_rd(retire1_rd),.retire1_rd_data(retire1_rd_data),
        .retire1_mem_valid(retire1_mem_valid),.retire1_mem_we(retire1_mem_we),
        .retire1_mem_addr(retire1_mem_addr),.retire1_mem_wdata(retire1_mem_wdata),.retire1_mem_be(retire1_mem_be),
        .fault_valid(fault_valid),.fault_cause(fault_cause),.fault_pc(fault_pc),
        .fault_instr(fault_instr),.fault_addr(fault_addr),.debug_valid(debug_valid),
        .irq_soft(irq_soft),.irq_timer(irq_timer),.irq_ext(irq_ext),.mtime(mtime)
    );
    mem_io_subsystem #(.CLK_HZ(`SYS_CLK_HZ)) subsystem(
        .clk(clk),.rst_n(rst_n),.boot_write_enable(1'b0),
        .if_valid(if_valid),.if_addr(if_addr),.if_ready(if_ready),
        .if_rvalid(if_rvalid),.if_rdata(if_rdata),.if_error(if_error),
        .if_rdata1(if_rdata1),.if_error1(if_error1),
        .ld_valid(ld_valid),.ld_addr(ld_addr),.ld_size(ld_size),.ld_ready(ld_ready),.ld_maddr(ld_maddr),
        .ld_rvalid(ld_rvalid),.ld_rdata(ld_rdata),.ld_error(ld_error),
        .st_valid(st_valid),.st_addr(st_addr),.st_size(st_size),
        .st_wdata(st_wdata),.st_wstrb(st_wstrb),.st_ready(st_ready),
        .st_done(st_done),.st_error(st_error),
        .key1_n(key1_n),.uart_rx(uart_rx),.uart_tx(uart_tx),.led(led),
        .sim_result(sim_result),.sim_exit_valid(sim_exit_valid),
        .mtime(mtime),.irq_timer(irq_timer),.irq_soft(irq_soft),.irq_ext(irq_ext),
        .phy_it_a_en(),.phy_it_b_en(),.phy_it_b_we(),
        .phy_dt_a_en(),.phy_dt_b_en(),.phy_dt_b_we(),
        .aclk(aclk),.arst_n(arst_n),.ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awuser_ap),.axi_awuser_id(axi_awuser_id),.axi_awlen(axi_awlen),
        .axi_awready(axi_awready),.axi_awvalid(axi_awvalid),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),
        .axi_araddr(axi_araddr),.axi_aruser_ap(axi_aruser_ap),.axi_aruser_id(axi_aruser_id),.axi_arlen(axi_arlen),
        .axi_arready(axi_arready),.axi_arvalid(axi_arvalid),.axi_rdata(axi_rdata),.axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid)
    );
endmodule
