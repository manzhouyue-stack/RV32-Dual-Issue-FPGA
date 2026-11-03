// v0.9 TCM (dual fetch): as v0.8, plus if_rdata1 = word at if_addr+4 read
// from the other bank in the same cycle.
// v0.8 TCM: 64 KiB ITCM as two word-interleaved 32 KiB banks (bank = addr[2]),
// 32 KiB DTCM unchanged. Same B v0.3 request/response contract as the original
// tcm_subsystem (accept on valid&&ready, response flags one cycle later).
// Map: ITCM 0x0000_0000-0x0000_FFFF (first 4 KiB boot-protected), DTCM
// 0x0001_0000-0x0001_7FFF. The banks let a later fetch unit read any two
// consecutive instructions in one cycle.
module tcm_subsystem(
 input wire clk,rst_n,boot_write_enable,
 input wire if_valid,input wire [31:0] if_addr,output wire if_ready,output reg if_rvalid,output wire [31:0] if_rdata,output reg if_error,
 output wire [31:0] if_rdata1,output reg if_error1,
 input wire ld_valid,input wire [31:0] ld_addr,output wire ld_ready,output reg ld_rvalid,output wire [31:0] ld_rdata,output reg ld_error,
 input wire st_valid,input wire [31:0] st_addr,st_wdata,input wire [3:0] st_wstrb,output wire st_ready,output reg st_done,st_error,
 output wire phy_it_a_en,phy_it_b_en,phy_it_b_we,phy_dt_a_en,phy_dt_b_en,phy_dt_b_we
);
 wire if_it=(if_addr[31:16]==16'h0)&&(if_addr[1:0]==2'b00);
 wire ld_it=(ld_addr[31:16]==16'h0)&&(ld_addr[1:0]==2'b00);
 wire ld_dt=(ld_addr[31:15]==17'h2)&&(ld_addr[1:0]==2'b00);
 wire st_it=(st_addr[31:16]==16'h0)&&(st_addr[1:0]==2'b00);
 wire st_dt=(st_addr[31:15]==17'h2)&&(st_addr[1:0]==2'b00);
 wire st_bad=!(st_it||st_dt)||(st_it&&(st_addr[15:12]==4'h0)&&!boot_write_enable);
 wire st_modifies=rst_n&&st_valid&&!st_bad&&(|st_wstrb);
 assign st_ready=rst_n;
 // A store and a load/fetch to the same physical word never share a cycle;
 // an ITCM load also yields to a store using the same bank's port B.
 // Fetch pair: words w0=if_addr[15:2] and w1=w0+1 (the core never wraps a pair).
 wire [31:0] if_addr1=if_addr+32'd4;
 wire if_it1=(if_addr1[31:16]==16'h0)&&(if_addr[1:0]==2'b00);
 assign if_ready=rst_n&&!(if_valid&&if_it&&st_modifies&&st_it&&((if_addr==st_addr)||(if_addr1==st_addr)));
 assign ld_ready=rst_n&&!(ld_valid&&st_modifies&&
                    ((ld_it&&st_it&&(ld_addr[2]==st_addr[2]))||(ld_dt&&st_dt&&(ld_addr==st_addr))));
 wire if_accept=if_valid&&if_ready;
 wire ld_accept=ld_valid&&ld_ready;
 wire st_it0=st_modifies&&st_it&&!st_addr[2], st_it1=st_modifies&&st_it&&st_addr[2];
 wire ld_it0=ld_accept&&ld_it&&!ld_addr[2], ld_it1=ld_accept&&ld_it&&ld_addr[2];
 assign phy_it_a_en=if_accept&&if_it;
 assign phy_it_b_we=st_modifies&&st_it;
 assign phy_it_b_en=phy_it_b_we||(ld_accept&&ld_it);
 assign phy_dt_a_en=ld_accept&&ld_dt;
 assign phy_dt_b_we=st_modifies&&st_dt;
 assign phy_dt_b_en=phy_dt_b_we;
 wire [31:0] it0_a,it1_a,it0_b,it1_b,dt_load_data;
 reg ld_response_dt,if_bank,ld_bank;
 assign if_rdata=if_error?32'b0:(if_bank?it1_a:it0_a);
 assign if_rdata1=if_error1?32'b0:(if_bank?it0_a:it1_a);
 assign ld_rdata=ld_error?32'b0:(ld_response_dt?dt_load_data:(ld_bank?it1_b:it0_b));
 always @(posedge clk or negedge rst_n) begin
   if(!rst_n) begin
     if_rvalid<=0; if_error<=0; if_error1<=0; ld_rvalid<=0; ld_error<=0;
     st_done<=0; st_error<=0; ld_response_dt<=0; if_bank<=0; ld_bank<=0;
   end else begin
     if_rvalid<=if_accept; if_error<=if_accept&&!if_it; if_error1<=if_accept&&!if_it1;
     ld_rvalid<=ld_accept; ld_error<=ld_accept&&!(ld_it||ld_dt);
     ld_response_dt<=ld_accept&&ld_dt;
     if(if_accept) if_bank<=if_addr[2];
     if(ld_accept) ld_bank<=ld_addr[2];
     st_done<=st_valid&&st_ready; st_error<=st_valid&&st_ready&&st_bad;
   end
 end
 soc_itcm_ram_b0 itcm0(
   .a_clk(clk),.a_clk_en(phy_it_a_en),.a_rst(1'b0),.a_addr(if_addr[2]?if_addr1[15:3]:if_addr[15:3]),
   .a_wr_data(32'b0),.a_wr_en(1'b0),.a_wr_byte_en(4'b0),.a_rd_data(it0_a),
   .b_clk(clk),.b_clk_en(st_it0||ld_it0),.b_rst(1'b0),
   .b_addr(st_it0?st_addr[15:3]:ld_addr[15:3]),
   .b_wr_data(st_wdata),.b_wr_en(st_it0),.b_wr_byte_en(st_wstrb),.b_rd_data(it0_b)
 );
 soc_itcm_ram_b1 itcm1(
   .a_clk(clk),.a_clk_en(phy_it_a_en),.a_rst(1'b0),.a_addr(if_addr[15:3]),
   .a_wr_data(32'b0),.a_wr_en(1'b0),.a_wr_byte_en(4'b0),.a_rd_data(it1_a),
   .b_clk(clk),.b_clk_en(st_it1||ld_it1),.b_rst(1'b0),
   .b_addr(st_it1?st_addr[15:3]:ld_addr[15:3]),
   .b_wr_data(st_wdata),.b_wr_en(st_it1),.b_wr_byte_en(st_wstrb),.b_rd_data(it1_b)
 );
 soc_dtcm_ram dtcm(
   .a_clk(clk),.a_clk_en(phy_dt_a_en),.a_rst(1'b0),.a_addr(ld_addr[14:2]),
   .a_wr_data(32'b0),.a_wr_en(1'b0),.a_wr_byte_en(4'b0),.a_rd_data(dt_load_data),
   .b_clk(clk),.b_clk_en(phy_dt_b_en),.b_rst(1'b0),.b_addr(st_addr[14:2]),
   .b_wr_data(st_wdata),.b_wr_en(phy_dt_b_we),.b_wr_byte_en(st_wstrb),.b_rd_data()
 );
endmodule
