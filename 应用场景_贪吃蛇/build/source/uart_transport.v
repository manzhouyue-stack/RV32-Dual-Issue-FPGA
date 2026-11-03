`timescale 1ns/1ps
// 8N1 UART, independent TX/RX, with a free-running 16x baud clock enable.
module uart_transport(
 input clk,input rst_n,input tx_en,input rx_en,
 input [23:0] baud_inc,input baud_restart,
 input tx_push,input [7:0] tx_data,output tx_push_ready,
 input rx_pop,output [7:0] rx_data,output rx_avail,
 output tx_full,output tx_empty,output reg tx_busy,output rx_busy,output rx_line_idle,
 output [4:0] tx_level,output [4:0] rx_level,
 output reg rx_overrun_event,output reg frame_error_event,
 input uart_rx,output reg uart_tx
);
 reg [23:0] baud_phase;
 wire [24:0] baud_sum={1'b0,baud_phase}+{1'b0,baud_inc};
 wire baud_tick=baud_sum[24] && !baud_restart;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) baud_phase<=24'd0;
  else if(baud_restart) baud_phase<=24'd0;
  else baud_phase<=baud_sum[23:0];
 end

 wire [7:0] tx_head;
 wire tx_fifo_empty;
 reg [9:0] tx_shift;
 reg [3:0] tx_subtick,tx_bit;
 // A queued successor starts on the stop-completion tick: exactly 160 ticks
 // start-to-start, so equal-baud continuous echo cannot grow a FIFO backlog.
 wire tx_finishing=tx_busy && tx_bit==4'd9 && tx_subtick==4'd15;
 wire tx_start=baud_tick && tx_en && (!tx_busy || tx_finishing) && !tx_fifo_empty;
 fifo16x8 tx_fifo(.clk(clk),.rst_n(rst_n),.push(tx_push),.pop(tx_start),
  .in_data(tx_data),.out_data(tx_head),.level(tx_level),.full(tx_full),
  .empty(tx_fifo_empty),.push_ready(tx_push_ready));
 assign tx_empty=tx_fifo_empty && !tx_busy;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   uart_tx<=1'b1;tx_busy<=1'b0;tx_shift<=10'h3ff;tx_subtick<=4'd0;tx_bit<=4'd0;
  end else if(baud_tick) begin
   if(tx_start) begin
    tx_shift<={1'b1,tx_head,1'b0};uart_tx<=1'b0;tx_busy<=1'b1;
    tx_subtick<=4'd0;tx_bit<=4'd0;
   end else if(tx_busy) begin
    if(tx_subtick==4'd15) begin
     tx_subtick<=4'd0;
     if(tx_bit==4'd9) begin tx_busy<=1'b0;uart_tx<=1'b1;end
     else begin
      tx_bit<=tx_bit+4'd1;tx_shift<={1'b1,tx_shift[9:1]};uart_tx<=tx_shift[1];
     end
    end else tx_subtick<=tx_subtick+4'd1;
   end
  end
 end

 (* ASYNC_REG = "TRUE" *) reg rx_meta,rx_sync;
 reg rx_previous;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin rx_meta<=1'b1;rx_sync<=1'b1;rx_previous<=1'b1;end
  else begin rx_meta<=uart_rx;rx_sync<=rx_meta;rx_previous<=rx_sync;end
 end
 localparam [1:0] RX_IDLE=2'd0,RX_START=2'd1,RX_DATA=2'd2,RX_STOP=2'd3;
 reg [1:0] rx_state;
 reg rx_armed;
 reg [3:0] rx_subtick;
 reg [2:0] rx_bit;
 reg [7:0] rx_shift;
 wire rx_fifo_empty,rx_fifo_full,rx_push_ready;
 // Commit at the stop-bit center, allowing pop and push on the very same edge.
 wire rx_commit=rx_en && rx_state==RX_STOP && baud_tick && rx_subtick==4'd15 && rx_sync;
 fifo16x8 rx_fifo(.clk(clk),.rst_n(rst_n),.push(rx_commit),.pop(rx_pop),
  .in_data(rx_shift),.out_data(rx_data),.level(rx_level),.full(rx_fifo_full),
  .empty(rx_fifo_empty),.push_ready(rx_push_ready));
 assign rx_avail=!rx_fifo_empty;
 assign rx_busy=(rx_state!=RX_IDLE);
 assign rx_line_idle=(rx_state==RX_IDLE) && rx_sync;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   rx_state<=RX_IDLE;rx_armed<=1'b0;rx_subtick<=4'd0;rx_bit<=3'd0;rx_shift<=8'd0;
   rx_overrun_event<=1'b0;frame_error_event<=1'b0;
  end else begin
   rx_overrun_event<=rx_commit && !rx_push_ready;
   frame_error_event<=1'b0;
   if(!rx_en) begin rx_state<=RX_IDLE;rx_armed<=1'b0;rx_subtick<=4'd0;end
   else begin
    case(rx_state)
     RX_IDLE:begin
      if(rx_sync) rx_armed<=1'b1;
      if(rx_armed && rx_previous && !rx_sync) begin
       rx_state<=RX_START;rx_subtick<=4'd0;
      end
     end
     RX_START:if(baud_tick) begin
      if(rx_subtick==4'd7) begin
       rx_subtick<=4'd0;
       if(!rx_sync) begin rx_state<=RX_DATA;rx_bit<=3'd0;end
       else rx_state<=RX_IDLE;
      end else rx_subtick<=rx_subtick+4'd1;
     end
     RX_DATA:if(baud_tick) begin
      if(rx_subtick==4'd15) begin
       rx_subtick<=4'd0;rx_shift[rx_bit]<=rx_sync;
       if(rx_bit==3'd7) rx_state<=RX_STOP;
       else rx_bit<=rx_bit+3'd1;
      end else rx_subtick<=rx_subtick+4'd1;
     end
     RX_STOP:if(baud_tick) begin
      if(rx_subtick==4'd15) begin
       rx_subtick<=4'd0;rx_state<=RX_IDLE;
       if(!rx_sync) begin frame_error_event<=1'b1;rx_armed<=1'b0;end
      end else rx_subtick<=rx_subtick+4'd1;
     end
     default:begin rx_state<=RX_IDLE;rx_armed<=1'b0;end
    endcase
   end
  end
 end
endmodule
