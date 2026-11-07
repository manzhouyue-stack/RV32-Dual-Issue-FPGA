`timescale 1ns/1ps
// v1.0 copy of B's counter with the count exported.
// Free running system-clock ticks. Reads neither latch nor modify state.
module cycle_counter64 #(parameter integer CLK_HZ=50000000)(
 input clk,rst_n,input [31:0] addr,
 output reg [31:0] rdata,output addr_valid,
 output [63:0] count   // v1.0: platform mtime for the time CSR and mtimecmp
);
 reg [63:0] cycles;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) cycles<=64'd0;
  else cycles<=cycles+64'd1;
 assign count=cycles;
 assign addr_valid=(addr==32'h10003000)||(addr==32'h10003004)||(addr==32'h10003008);
 always @* begin
  case(addr)
   32'h10003000:rdata=cycles[31:0];
   32'h10003004:rdata=cycles[63:32];
   32'h10003008:rdata=CLK_HZ;
   default:rdata=32'd0;
  endcase
 end
endmodule
