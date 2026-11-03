`timescale 1ns/1ps
module tb_rv32ui;
  localparam [31:0] BASE=32'h8000_1000;
  logic clk=0,rst=1,external_freeze=0,external_port_conflict=0;
  always #5 clk=~clk;
  logic [31:0] imem_addr,imem_rdata,dmem_raddr,dmem_rdata,dmem_waddr,dmem_wdata;
  logic dmem_re,dmem_we,retire_valid,retire_rd_we,retire_mem_valid,retire_mem_we;
  logic [3:0] dmem_be,retire_mem_be;
  logic [31:0] retire_pc,retire_instr,retire_rd_data,retire_mem_addr,retire_mem_wdata,debug_pc_f;
  logic [4:0] retire_rd,debug_valid;
  logic [2:0] debug_hazard;
  logic fault_valid;
  logic [31:0] fault_pc,fault_instr;
  logic [31:0] mem[0:16383];
  string memfile;
  string tracefile;
  integer trace_fd=0;
  integer inject=0;
  logic [31:0] prng=32'h42a1_9e37;
  logic [31:0] tohost;
  integer words,cycles,retired=0,i;
  logic mmio_valid,mmio_we,mmio_commit;
  logic [31:0] mmio_addr,mmio_wdata;
  logic [3:0] mmio_be;
  logic [31:0] mmio_rdata=0;
  logic mmio_ready=1;
  rv32_core #(.RESET_PC(BASE)) dut(.*);
  initial begin
    if(!$value$plusargs("mem=%s",memfile)) $fatal(1,"missing +mem");
    if(!$value$plusargs("tohost=%h",tohost)) $fatal(1,"missing +tohost");
    if(!$value$plusargs("words=%d",words)) $fatal(1,"missing +words");
    if($value$plusargs("trace=%s",tracefile)) begin
      trace_fd=$fopen(tracefile,"w");
      if(trace_fd==0) $fatal(1,"cannot open trace file");
    end
    if(!$value$plusargs("inject=%d",inject)) inject=0;
    for(i=0;i<16384;i=i+1) mem[i]=0;
    $readmemh(memfile,mem,0,words-1);
    repeat(3) @(posedge clk);
    @(negedge clk);rst=0;
    for(cycles=0;cycles<10000;cycles=cycles+1) begin
      @(negedge clk);
      if(retire_valid) begin
        retired=retired+1;
        if(trace_fd!=0) $fdisplay(trace_fd,"%08x %08x %0d %0d %08x %0d %0d %08x %08x %01x",
          retire_pc,retire_instr,retire_rd_we,retire_rd,retire_rd_data,
          retire_mem_valid,retire_mem_we,retire_mem_addr,retire_mem_wdata,retire_mem_be);
        if(retire_mem_valid && retire_mem_we && retire_mem_addr==tohost) begin
          if(retire_mem_wdata!==32'd1) $fatal(1,"RV32UI fail: tohost=%08x pc=%08x",retire_mem_wdata,retire_pc);
          $display("PASS rv32ui: retired=%0d cycles=%0d",retired,cycles);
          $finish;
        end
      end
    end
    $fatal(1,"RV32UI timeout after %0d cycles pc=%08x",cycles,debug_pc_f);
  end
  always @(negedge clk) begin
    if(rst || inject==0) begin
      external_freeze=0;
      external_port_conflict=0;
    end else begin
      prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
      external_freeze=(prng[7:0]<26);
      external_port_conflict=dmem_re && dmem_we && prng[11];
    end
  end
  always @(posedge clk) begin
    imem_rdata<=mem[(imem_addr-BASE)>>2];
    if(dmem_re) begin
      if(dmem_we && dmem_raddr[31:2]==dmem_waddr[31:2]) dmem_rdata<=32'hxxxx_xxxx;
      else dmem_rdata<=mem[(dmem_raddr-BASE)>>2];
    end
    if(dmem_we) for(integer b=0;b<4;b=b+1)
      if(dmem_be[b]) mem[(dmem_waddr-BASE)>>2][8*b+:8]<=dmem_wdata[8*b+:8];
  end
endmodule
