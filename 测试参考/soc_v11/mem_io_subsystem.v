`timescale 1ns/1ps
// v1.1: B's mem_io_subsystem with the second fetch word (dual-issue), the
// machine interrupt lines / mtime, and the cached DDR region:
//   0x8000_0000-0x9FFF_FFFF -> I-cache (fetch) / D-cache (load/store) -> DDR3
//   0x1000_4000 page        -> cache control and statistics (ddr_cache_top)
module mem_io_subsystem #(
 parameter integer CLK_HZ=50000000,
 parameter integer KEY_DEBOUNCE_CYCLES=CLK_HZ/100
)(
 input clk,rst_n,boot_write_enable,
 input if_valid,input [31:0] if_addr,output if_ready,if_rvalid,if_error,output [31:0] if_rdata,
 output if_error1,output [31:0] if_rdata1,
 input ld_valid,input [31:0] ld_addr,input [1:0] ld_size,output ld_ready,ld_rvalid,ld_error,output [31:0] ld_rdata,
 input [31:0] ld_maddr,   // MEM-stage load address from the core (DDR loads always issue from MEM)
 input st_valid,input [31:0] st_addr,st_wdata,input [1:0] st_size,input [3:0] st_wstrb,output st_ready,st_done,st_error,
 input key1_n,uart_rx,output uart_tx,output [7:0] led,
 output [31:0] sim_result,output sim_exit_valid,
 output [63:0] mtime,output irq_timer,irq_soft,irq_ext,
 output phy_it_a_en,phy_it_b_en,phy_it_b_we,phy_dt_a_en,phy_dt_b_en,phy_dt_b_we,
 // DDR controller side (aclk domain)
 input aclk,arst_n,ddr_init_done,
 output [27:0] axi_awaddr,output axi_awuser_ap,output [3:0] axi_awuser_id,output [3:0] axi_awlen,
 input axi_awready,output axi_awvalid,output [255:0] axi_wdata,output [31:0] axi_wstrb,input axi_wready,
 output [27:0] axi_araddr,output axi_aruser_ap,output [3:0] axi_aruser_id,output [3:0] axi_arlen,
 input axi_arready,output axi_arvalid,input [255:0] axi_rdata,input axi_rlast,axi_rvalid
);
 // DDR region and cache register page
 wire if_ddr=(if_addr[31:29]==3'b100);
 wire ld_ddr=(ld_addr[31:29]==3'b100)&&(ld_size!=2'd3);
 wire st_ddr=(st_addr[31:29]==3'b100)&&(st_size!=2'd3);
 wire ld_creg=(ld_addr[31:12]==20'h10004);
 wire st_creg=(st_addr[31:12]==20'h10004);
 wire c_if_ready,c_if_rvalid,c_ld_ready,c_ld_rvalid,c_st_ready,c_st_done;
 wire [31:0] c_if_rdata0,c_if_rdata1,c_ld_rdata,c_reg_rdata;
 wire t_if_ready,t_if_rvalid,t_if_error,t_if_error1;
 wire [31:0] t_if_rdata,t_if_rdata1;
 assign if_ready=if_ddr?c_if_ready:t_if_ready;
 assign if_rvalid=t_if_rvalid||c_if_rvalid;
 assign if_rdata=c_if_rvalid?c_if_rdata0:t_if_rdata;
 assign if_rdata1=c_if_rvalid?c_if_rdata1:t_if_rdata1;
 assign if_error=c_if_rvalid?1'b0:t_if_error;
 assign if_error1=c_if_rvalid?1'b0:t_if_error1;
 wire ld_mmio=(ld_addr[31:12]==20'h10000)||(ld_addr[31:12]==20'h10001)||(ld_addr[31:12]==20'h10002)||(ld_addr[31:12]==20'h10003)||ld_creg;
 wire st_mmio=(st_addr[31:12]==20'h10000)||(st_addr[31:12]==20'h10001)||(st_addr[31:12]==20'h10002)||(st_addr[31:12]==20'h10003)||st_creg;
 wire ld_special=ld_mmio||(ld_size==2'd3);
 wire st_special=st_mmio||(st_size==2'd3);
 wire mmio_stall=ld_valid&&ld_mmio&&st_valid&&st_mmio;
 wire t_ld_ready,t_st_ready,t_ld_rvalid,t_ld_error,t_st_done,t_st_error;
 wire [31:0] t_ld_rdata;
 assign ld_ready=rst_n&&!mmio_stall&&(ld_special||(ld_ddr?c_ld_ready:t_ld_ready));
 assign st_ready=rst_n&&(st_special||(st_ddr?c_st_ready:t_st_ready));
 wire ld_accept=ld_valid&&ld_ready&&ld_special;
 wire st_accept=st_valid&&st_ready&&st_special;
 wire [31:0] regs_data;
 wire regs_read_error,regs_write_error;
 reg special_ld_response,special_st_response;
 reg special_ld_valid,special_st_done,special_ld_error,special_st_error;
 reg [31:0] special_ld_data;
 assign ld_rvalid=special_ld_response?special_ld_valid:(c_ld_rvalid||t_ld_rvalid);
 assign ld_error=special_ld_response?special_ld_error:(c_ld_rvalid?1'b0:t_ld_error);
 assign ld_rdata=special_ld_response?special_ld_data:(c_ld_rvalid?c_ld_rdata:t_ld_rdata);
 assign st_done=special_st_response?special_st_done:(c_st_done||t_st_done);
 assign st_error=special_st_response?special_st_error:(c_st_done?1'b0:t_st_error);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   special_ld_response<=0;special_st_response<=0;special_ld_valid<=0;special_st_done<=0;
   special_ld_error<=0;special_st_error<=0;special_ld_data<=0;
  end else begin
   special_ld_response<=ld_accept;special_st_response<=st_accept;
   special_ld_valid<=ld_accept;special_st_done<=st_accept;
   special_ld_error<=ld_accept&&(!ld_mmio||(!ld_creg&&regs_read_error));
   special_st_error<=st_accept&&(!st_mmio||(!st_creg&&regs_write_error));
   special_ld_data<=ld_creg?c_reg_rdata:((!ld_mmio||regs_read_error)?32'd0:regs_data);
  end
 end
 tcm_subsystem memory(
  .clk(clk),.rst_n(rst_n),.boot_write_enable(boot_write_enable),
  .if_valid(if_valid&&!if_ddr),.if_addr(if_addr),.if_ready(t_if_ready),.if_rvalid(t_if_rvalid),.if_rdata(t_if_rdata),.if_error(t_if_error),
  .if_rdata1(t_if_rdata1),.if_error1(t_if_error1),
  .ld_valid(ld_valid&&!ld_special&&!mmio_stall&&!ld_ddr),.ld_addr(ld_addr),.ld_ready(t_ld_ready),.ld_rvalid(t_ld_rvalid),.ld_rdata(t_ld_rdata),.ld_error(t_ld_error),
  .st_valid(st_valid&&!st_special&&!st_ddr),.st_addr(st_addr),.st_wdata(st_wdata),.st_wstrb(st_wstrb),.st_ready(t_st_ready),.st_done(t_st_done),.st_error(t_st_error),
  .phy_it_a_en(phy_it_a_en),.phy_it_b_en(phy_it_b_en),.phy_it_b_we(phy_it_b_we),
  .phy_dt_a_en(phy_dt_a_en),.phy_dt_b_en(phy_dt_b_en),.phy_dt_b_we(phy_dt_b_we)
 );
 wire tx_en,rx_en,baud_restart,tx_push,tx_push_ready,tx_full,tx_empty,rx_busy,rx_pop,rx_avail;
 wire rx_overrun_event,frame_error_event;
 wire [23:0] baud_inc;
 wire [7:0] tx_data,rx_data;
 ddr_cache_top caches(
  .clk(clk),.rst_n(rst_n),
  .if_valid(if_valid&&if_ddr),.if_off(if_addr[28:0]),.if_ready(c_if_ready),.if_rvalid(c_if_rvalid),
  .if_rdata0(c_if_rdata0),.if_rdata1(c_if_rdata1),
  .ld_valid(ld_valid&&ld_ddr&&!mmio_stall),.ld_off(ld_maddr[28:0]),.ld_ready(c_ld_ready),.ld_rvalid(c_ld_rvalid),.ld_rdata(c_ld_rdata),
  .st_valid(st_valid&&st_ddr),.st_off(st_addr[28:0]),.st_wdata(st_wdata),.st_wstrb(st_wstrb),.st_ready(c_st_ready),.st_done(c_st_done),
  .reg_rd(ld_accept&&ld_creg),.reg_rd_off(ld_addr[7:0]),.reg_rdata(c_reg_rdata),
  .reg_wr(st_accept&&st_creg),.reg_wr_off(st_addr[7:0]),.reg_wdata(st_wdata),
  .aclk(aclk),.arst_n(arst_n),.ddr_init_done(ddr_init_done),
  .axi_awaddr(axi_awaddr),.axi_awuser_ap(axi_awuser_ap),.axi_awuser_id(axi_awuser_id),.axi_awlen(axi_awlen),
  .axi_awready(axi_awready),.axi_awvalid(axi_awvalid),.axi_wdata(axi_wdata),.axi_wstrb(axi_wstrb),.axi_wready(axi_wready),
  .axi_araddr(axi_araddr),.axi_aruser_ap(axi_aruser_ap),.axi_aruser_id(axi_aruser_id),.axi_arlen(axi_arlen),
  .axi_arready(axi_arready),.axi_arvalid(axi_arvalid),.axi_rdata(axi_rdata),.axi_rlast(axi_rlast),.axi_rvalid(axi_rvalid)
 );
 mmio_regs #(.CLK_HZ(CLK_HZ),.KEY_DEBOUNCE_CYCLES(KEY_DEBOUNCE_CYCLES)) registers(
  .clk(clk),.rst_n(rst_n),.key1_n(key1_n),
  .ld_accept(ld_accept&&ld_mmio&&!ld_creg),.ld_addr(ld_addr),.ld_size(ld_size),
  .st_accept(st_accept&&st_mmio&&!st_creg),.st_addr(st_addr),.st_size(st_size),.st_wdata(st_wdata),.st_wstrb(st_wstrb),
  .read_data(regs_data),.read_error(regs_read_error),.write_error(regs_write_error),
  .tx_en(tx_en),.rx_en(rx_en),.baud_inc(baud_inc),.baud_restart(baud_restart),
  .tx_push(tx_push),.tx_data(tx_data),.tx_push_ready(tx_push_ready),.tx_full(tx_full),.tx_empty(tx_empty),.rx_busy(rx_busy),
  .rx_pop(rx_pop),.rx_data(rx_data),.rx_avail(rx_avail),.rx_overrun_event(rx_overrun_event),.frame_error_event(frame_error_event),
  .led(led),.sim_result(sim_result),.sim_exit_valid(sim_exit_valid),
  .mtime(mtime),.irq_timer(irq_timer),.irq_soft(irq_soft),.irq_ext(irq_ext)
 );
 uart_transport serial(
  .clk(clk),.rst_n(rst_n),.tx_en(tx_en),.rx_en(rx_en),.baud_inc(baud_inc),.baud_restart(baud_restart),
  .tx_push(tx_push),.tx_data(tx_data),.tx_push_ready(tx_push_ready),.tx_full(tx_full),.tx_empty(tx_empty),.tx_busy(),.tx_level(),
  .rx_pop(rx_pop),.rx_data(rx_data),.rx_avail(rx_avail),.rx_busy(rx_busy),.rx_line_idle(),.rx_level(),
  .rx_overrun_event(rx_overrun_event),.frame_error_event(frame_error_event),.uart_rx(uart_rx),.uart_tx(uart_tx)
 );
endmodule

