`timescale 1ns/1ps
// Small register/LUT FIFO. Empty reads have no bypass; full plus legal pop accepts push.
module fifo16x8(
 input clk,input rst_n,input push,input pop,input [7:0] in_data,
 output [7:0] out_data,output reg [4:0] level,
 output full,output empty,output push_ready
);
 (* ram_style = "distributed" *) reg [7:0] memory[0:15];
 reg [3:0] read_ptr,write_ptr;
 wire pop_accept=pop && !empty;
 wire push_accept=push && push_ready;
 assign empty=(level==5'd0);
 assign full=(level==5'd16);
 assign push_ready=!full || pop_accept;
 assign out_data=memory[read_ptr];
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   level<=5'd0;read_ptr<=4'd0;write_ptr<=4'd0;
  end else begin
   if(push_accept) begin memory[write_ptr]<=in_data;write_ptr<=write_ptr+4'd1;end
   if(pop_accept) read_ptr<=read_ptr+4'd1;
   case({push_accept,pop_accept})
    2'b10:level<=level+5'd1;
    2'b01:level<=level-5'd1;
    default:level<=level;
   endcase
  end
 end
endmodule
