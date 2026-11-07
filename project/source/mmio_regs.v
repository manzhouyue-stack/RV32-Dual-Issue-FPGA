`timescale 1ns/1ps
// v1.0 copy of B's register bank plus machine interrupt sources:
//   0x10003010/14 MTIMECMP lo/hi (timer IRQ while mtime >= mtimecmp; resets to all ones)
//   0x10003018    MSIP     bit0 software interrupt
//   0x1000301C    IRQ_EN   bit0 UART RX available, bit1 KEY1 pressed -> external IRQ
// Register bank; every commit is qualified by an accepted, legal request.
module mmio_regs #(
 parameter integer CLK_HZ=50000000,
 parameter integer KEY_DEBOUNCE_CYCLES=CLK_HZ/100
)(
 input clk,rst_n,key1_n,
 input ld_accept,input [31:0] ld_addr,input [1:0] ld_size,
 input st_accept,input [31:0] st_addr,st_wdata,input [1:0] st_size,input [3:0] st_wstrb,
 output reg [31:0] read_data,output reg read_error,write_error,
 output tx_en,rx_en,output [23:0] baud_inc,output baud_restart,
 output tx_push,output [7:0] tx_data,input tx_push_ready,tx_full,tx_empty,rx_busy,
 output rx_pop,input [7:0] rx_data,input rx_avail,rx_overrun_event,frame_error_event,
 output [7:0] led,output reg [31:0] sim_result,output reg sim_exit_valid,
 output [63:0] mtime,output reg irq_timer,output irq_soft,output irq_ext
);
 localparam [23:0] DEFAULT_INC=(64'd16*64'd115200*64'd16777216+CLK_HZ/2)/CLK_HZ;
 wire [31:0] timer_read_data;
 cycle_counter64 #(.CLK_HZ(CLK_HZ)) timer(
  .clk(clk),.rst_n(rst_n),.addr(ld_addr),.rdata(timer_read_data),.addr_valid(),.count(mtime));
 reg [63:0] mtimecmp;
 reg msip;
 reg [1:0] irq_en;
 reg [1:0] enables;
 reg [23:0] increment;
 reg rx_overrun,frame_error,tx_overflow;
 reg [7:0] gpio_led;
 (* ASYNC_REG="TRUE" *) reg key_meta,key_sync;
 reg key_pressed;
 function integer counter_width;
  input integer cycles;
  integer n;
  begin
   n=cycles-1;counter_width=1;
   while(n>1) begin n=n>>1;counter_width=counter_width+1;end
  end
 endfunction
 localparam integer KEY_COUNT_WIDTH=counter_width(KEY_DEBOUNCE_CYCLES);
 localparam [KEY_COUNT_WIDTH-1:0] KEY_COUNT_LAST=KEY_DEBOUNCE_CYCLES-1;
 reg [KEY_COUNT_WIDTH-1:0] key_count;
 wire key_sample=!key_sync;
 wire ld_format=(ld_size==2'd2)&&(ld_addr[1:0]==0);
 wire st_format=(st_size==2'd2)&&(st_addr[1:0]==0)&&(st_wstrb==4'hf);
 wire write_data=st_accept&&st_format&&(st_addr==32'h10000000);
 wire write_ctrl=st_accept&&st_format&&(st_addr==32'h10000008);
 // Valid same-value writes are idempotent and never disturb queued TX/RX.
 wire baud_value_ok=(st_wdata[31:24]==0)&&(|st_wdata[23:0]);
 wire baud_same=(st_wdata[23:0]==increment);
 // Rewriting the current valid increment is idempotent, so firmware may re-initialise
 // the UART while earlier output drains. A real rate change still needs TX/RX off and idle.
 wire baud_ok=baud_value_ok&&(baud_same||((enables==0)&&tx_empty&&!rx_busy));
 assign baud_restart=st_accept&&st_format&&(st_addr==32'h1000000c)&&baud_ok&&!baud_same;
 assign tx_en=enables[0];assign rx_en=enables[1];assign baud_inc=increment;
 assign tx_push=write_data&&tx_push_ready;
 assign tx_data=st_wdata[7:0];
 assign rx_pop=ld_accept&&ld_format&&(ld_addr==32'h10000000)&&rx_avail;
 assign led=(sim_result!=0)?sim_result[7:0]:gpio_led;
 always @* begin
  read_data=0;read_error=!ld_format;
  if(ld_format) begin
   case(ld_addr)
    32'h10000000:read_data=rx_avail?{24'd0,rx_data}:32'h80000000;
    32'h10000004:read_data={26'd0,tx_overflow,frame_error,rx_overrun,rx_avail,tx_empty,tx_full};
    32'h10000008:read_data={30'd0,enables};
    32'h1000000c:read_data={8'd0,increment};
    32'h10001000:read_data={24'd0,gpio_led};
    32'h10001004:read_data={31'd0,key_pressed};
    32'h10002000:read_data=sim_result;
    32'h10003000:read_data=timer_read_data;
    32'h10003004:read_data=timer_read_data;
    32'h10003008:read_data=timer_read_data;
    32'h10003010:read_data=mtimecmp[31:0];
    32'h10003014:read_data=mtimecmp[63:32];
    32'h10003018:read_data={31'd0,msip};
    32'h1000301c:read_data={30'd0,irq_en};
    default:read_error=1;
   endcase
  end
  write_error=!st_format;
  if(st_format) begin
   case(st_addr)
    32'h10000000:write_error=!tx_push_ready;
    32'h10000008:write_error=0;
    32'h1000000c:write_error=!baud_ok;
    32'h10001000:write_error=0;
    32'h10002000:write_error=(st_wdata==0)||!st_wdata[0];
    32'h10003010,32'h10003014,32'h10003018,32'h1000301c:write_error=0;
    default:write_error=1;
   endcase
  end
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   enables<=0;increment<=DEFAULT_INC;rx_overrun<=0;frame_error<=0;tx_overflow<=0;
   gpio_led<=0;sim_result<=0;sim_exit_valid<=0;
   mtimecmp<={64{1'b1}};msip<=0;irq_en<=0;irq_timer<=0;
   key_meta<=1;key_sync<=1;key_pressed<=0;key_count<=0;
  end else begin
   key_meta<=key1_n;key_sync<=key_meta;
   if(key_sample==key_pressed) key_count<=0;
   else if((KEY_DEBOUNCE_CYCLES<=1)||(key_count>=KEY_COUNT_LAST)) begin
    key_pressed<=key_sample;key_count<=0;
   end else key_count<=key_count+1'b1;
   sim_exit_valid<=0;
   irq_timer<=mtime>=mtimecmp;
   if(write_ctrl) begin
    enables<=st_wdata[1:0];
    if(st_wdata[2]) begin rx_overrun<=0;frame_error<=0;tx_overflow<=0;end
   end
   // Set dominates clear when the two events coincide.
   if(rx_overrun_event) rx_overrun<=1;
   if(frame_error_event) frame_error<=1;
   if(write_data&&!tx_push_ready) tx_overflow<=1;
   if(baud_restart) increment<=st_wdata[23:0];
   if(st_accept&&!write_error) begin
    if(st_addr==32'h10001000) gpio_led<=st_wdata[7:0];
    if(st_addr==32'h10002000) begin sim_result<=st_wdata;sim_exit_valid<=1;end
    if(st_addr==32'h10003010) mtimecmp[31:0]<=st_wdata;
    if(st_addr==32'h10003014) mtimecmp[63:32]<=st_wdata;
    if(st_addr==32'h10003018) msip<=st_wdata[0];
    if(st_addr==32'h1000301c) irq_en<=st_wdata[1:0];
   end
  end
 end
 assign irq_soft=msip;
 assign irq_ext=(irq_en[0]&&rx_avail)||(irq_en[1]&&key_pressed);
endmodule
