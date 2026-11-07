`timescale 1ns/1ps
// v1.1 board top (MES2L676-100HP): CPU SoC on the 27 MHz -> PLL system clock,
// plus the on-board DDR3 (2 x MT41K256M16, 32-bit, 512 MiB) through the Pango
// ips2l_hmic_s controller (IP "ddr3_test", 125 MHz differential reference on
// N3/N2, controller core_clk 125 MHz). The controller's debug/calibration
// inputs take the vendor example's power-up defaults (DFT_CTRL_BUS_*).
module soc_stage1_top(
    input  wire clk, key0_n, key1_n, uart_rx,
    output wire uart_tx,
    output wire [7:0] led,
    input  wire ref_clk_p, ref_clk_n,
    output wire mem_cs_n, mem_rst_n, mem_ck, mem_ck_n, mem_cke, mem_ras_n, mem_cas_n, mem_we_n, mem_odt,
    output wire [14:0] mem_a,
    output wire [2:0] mem_ba,
    inout  wire [3:0] mem_dqs, mem_dqs_n,
    inout  wire [31:0] mem_dq,
    output wire [3:0] mem_dm
);
    wire clk_sys, rst_sys_n, pll_locked;
    wire [7:0] gpio_led;
    wire fault_valid; wire [3:0] fault_cause;
 wire [31:0] fault_pc,fault_instr,fault_addr; wire cpu_uart_tx;
    clk_rst_gen u_clk_rst(.clk_ref(clk),.key0_n(key0_n),
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.pll_locked(pll_locked));

    // ---------------- DDR3 controller ----------------
    wire ref_clk, core_clk, ddr_init_done;
    GTP_INBUFDS refclk_inbuf(.O(ref_clk), .I(ref_clk_p), .IB(ref_clk_n));
    // Controller-domain reset for the bridge (async assert, sync release).
    (* syn_preserve = 1 *) reg [1:0] arst_sync = 2'b00;
    always @(posedge core_clk or negedge key0_n)
        if (!key0_n) arst_sync <= 2'b00;
        else arst_sync <= {arst_sync[0], 1'b1};
    wire arst_n = arst_sync[1];

    wire [27:0] axi_awaddr, axi_araddr;
    wire axi_awuser_ap, axi_aruser_ap, axi_awready, axi_awvalid, axi_wready, axi_arready, axi_arvalid;
    wire axi_rlast, axi_rvalid;
    wire [3:0] axi_awuser_id, axi_aruser_id, axi_awlen, axi_arlen, axi_rid, axi_wusero_id;
    wire axi_wusero_last;
    wire [255:0] axi_wdata, axi_rdata;
    wire [31:0] axi_wstrb;

    ddr3_test #(
        .MEM_ROW_WIDTH(15), .MEM_COLUMN_WIDTH(10), .MEM_BANK_WIDTH(3),
        .MEM_DQ_WIDTH(32), .MEM_DM_WIDTH(4), .MEM_DQS_WIDTH(4), .CTRL_ADDR_WIDTH(28)
    ) I_ips_ddr_top (
        .ref_clk(ref_clk), .resetn(key0_n), .core_clk(core_clk),
        .pll_lock(), .phy_pll_lock(), .gpll_lock(), .rst_gpll_lock(), .ddrphy_cpd_lock(),
        .ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awready(axi_awready), .axi_awvalid(axi_awvalid),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_wusero_id(axi_wusero_id), .axi_wusero_last(axi_wusero_last),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arready(axi_arready), .axi_arvalid(axi_arvalid),
        .axi_rdata(axi_rdata), .axi_rid(axi_rid), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid),
        .apb_clk(1'b0), .apb_rst_n(1'b0), .apb_sel(1'b0), .apb_enable(1'b0), .apb_addr(8'd0),
        .apb_write(1'b0), .apb_ready(), .apb_wdata(16'd0), .apb_rdata(),
        .mem_cs_n(mem_cs_n), .mem_rst_n(mem_rst_n), .mem_ck(mem_ck), .mem_ck_n(mem_ck_n),
        .mem_cke(mem_cke), .mem_ras_n(mem_ras_n), .mem_cas_n(mem_cas_n), .mem_we_n(mem_we_n),
        .mem_odt(mem_odt), .mem_a(mem_a), .mem_ba(mem_ba), .mem_dqs(mem_dqs), .mem_dqs_n(mem_dqs_n),
        .mem_dq(mem_dq), .mem_dm(mem_dm),
        // vendor example defaults: DFT_CTRL_BUS_0 = 0x1001, _8 = 0x0010_0000, others 0
        .dbg_gate_start(1'b0), .dbg_cpd_start(1'b0), .dbg_ddrphy_rst_n(1'b1), .dbg_gpll_scan_rst(1'b0),
        .samp_position_dyn_adj(1'b0), .init_samp_position_even(32'd0), .init_samp_position_odd(32'd0),
        .wrcal_position_dyn_adj(1'b0), .init_wrcal_position(32'd0),
        .force_read_clk_ctrl(1'b0), .init_slip_step(16'd0), .init_read_clk_ctrl(12'd0),
        .debug_calib_ctrl(), .dbg_dll_upd_state(), .dbg_slice_status(), .dbg_slice_state(), .debug_data(),
        .debug_gpll_dps_phase(), .dbg_rst_dps_state(), .dbg_tran_err_rst_cnt(), .dbg_ddrphy_init_fail(),
        .debug_cpd_offset_adj(1'b0), .debug_cpd_offset_dir(1'b0), .debug_cpd_offset(10'd0),
        .debug_dps_cnt_dir0(), .debug_dps_cnt_dir1(),
        .ck_dly_en(1'b1), .init_ck_dly_step(8'd0), .ck_dly_set_bin(),
        .align_error(), .debug_rst_state(), .debug_cpd_state()
    );

    // ---------------- CPU SoC ----------------
    soc_stage1_core system(.clk(clk_sys),.rst_n(rst_sys_n),
        .key1_n(key1_n),.uart_rx(uart_rx),.uart_tx(cpu_uart_tx),.led(gpio_led),
        .fault_valid(fault_valid),.fault_cause(fault_cause),
        .fault_pc(fault_pc),.fault_instr(fault_instr),.fault_addr(fault_addr),.sim_result(),.sim_exit_valid(),
        .retire_valid(),.retire_pc(),.retire_instr(),.retire_rd_data(),
        .retire_rd_we(),.retire_rd(),.retire_mem_valid(),.retire_mem_we(),
        .retire_mem_addr(),.retire_mem_wdata(),.retire_mem_be(),
        .retire1_valid(),.retire1_pc(),.retire1_instr(),.retire1_rd_data(),
        .retire1_rd_we(),.retire1_rd(),.retire1_mem_valid(),.retire1_mem_we(),
        .retire1_mem_addr(),.retire1_mem_wdata(),.retire1_mem_be(),
        .aclk(core_clk),.arst_n(arst_n),.ddr_init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awuser_ap),.axi_awuser_id(axi_awuser_id),.axi_awlen(axi_awlen),
        .axi_awready(axi_awready),.axi_awvalid(axi_awvalid),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),
        .axi_araddr(axi_araddr),.axi_aruser_ap(axi_aruser_ap),.axi_aruser_id(axi_aruser_id),.axi_arlen(axi_arlen),
        .axi_arready(axi_arready),.axi_arvalid(axi_arvalid),.axi_rdata(axi_rdata),.axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid));
    fault_uart_diag diag(.clk(clk_sys),.rst_n(rst_sys_n),.fault(fault_valid),.cause(fault_cause),.pc(fault_pc),.insn(fault_instr),.addr(fault_addr),.cpu_tx(cpu_uart_tx),.tx(uart_tx));
    // CPU fault display as before; otherwise software LEDs.
    assign led=!rst_sys_n ? 8'h00 : (fault_valid ? {4'he,fault_cause} : gpio_led);
endmodule

module fault_uart_diag(input wire clk,rst_n,fault,input wire [3:0] cause,input wire [31:0] pc,insn,addr,input wire cpu_tx,output wire tx);
reg captured,owned; reg [3:0] c; reg [31:0] p,i,a;
reg [27:0] wait_count; reg [9:0] shift; reg [9:0] ticks; reg [3:0] bits; reg [5:0] pos;
function [7:0] hexchar(input [3:0] n);begin hexchar=n<10 ? 8'd48+n : 8'd87+n;end endfunction
function [7:0] ch(input [5:0] n);begin
case(n)
0:ch=13;1:ch=10;2:ch="F";3:ch="A";4:ch="U";5:ch="L";6:ch="T";7:ch=" ";8:ch="C";9:ch="=";10:ch=hexchar(c);11:ch=" ";12:ch="P";13:ch="C";14:ch="=";
23:ch=" ";24:ch="I";25:ch="=";34:ch=" ";35:ch="A";36:ch="=";45:ch=13;46:ch=10;
default:begin
if(n>=15&&n<=22)ch=hexchar((p>>((22-n)*4))&15);
else if(n>=26&&n<=33)ch=hexchar((i>>((33-n)*4))&15);
else if(n>=37&&n<=44)ch=hexchar((a>>((44-n)*4))&15);
else ch=32;
end endcase end endfunction
assign tx=owned ? (bits!=0 ? shift[0] : 1'b1) : cpu_tx;
always @(posedge clk or negedge rst_n)begin
if(!rst_n)begin captured<=0;owned<=0;c<=0;p<=0;i<=0;a<=0;wait_count<=0;shift<=1023;ticks<=0;bits<=0;pos<=0;end
else if(!captured)begin if(fault)begin captured<=1;c<=cause;p<=pc;i<=insn;a<=addr;wait_count<=2000000;end end
else if(wait_count!=0)wait_count<=wait_count-1;
else begin owned<=1;
if(bits==0)begin shift<={1'b1,ch(pos),1'b0};bits<=10;ticks<=867;end
else if(ticks!=0)ticks<=ticks-1;
else begin ticks<=867;shift<={1'b1,shift[9:1]};bits<=bits-1;
if(bits==1)begin if(pos==46)begin pos<=0;wait_count<=100000000;end else pos<=pos+1;end
end end end
endmodule
