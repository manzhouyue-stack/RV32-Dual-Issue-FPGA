`timescale 1ns/1ps
module tb_trace;
  localparam [31:0] BASE=32'h8000_1000, TOHOST=32'h8000_2080;
  logic clk=0,rst=1;
  always #5 clk=~clk;
  logic external_freeze=0,external_port_conflict=0;
  logic [31:0] imem_addr,imem_rdata,dmem_raddr,dmem_rdata,dmem_waddr,dmem_wdata;
  logic dmem_re,dmem_we,retire_valid,retire_rd_we,retire_mem_valid,retire_mem_we;
  logic [3:0] dmem_be,retire_mem_be;
  logic [31:0] retire_pc,retire_instr,retire_rd_data,retire_mem_addr,retire_mem_wdata,debug_pc_f;
  logic [4:0] retire_rd,debug_valid;
  logic [2:0] debug_hazard;
  logic fault_valid;
  logic [31:0] fault_pc,fault_instr;
  logic [31:0] mem[0:2047];
  integer trace_fd,i,cycles=0,retired=0,collisions=0,load_stalls=0,redirects=0;
  logic mmio_valid,mmio_we,mmio_commit;
  logic [31:0] mmio_addr,mmio_wdata;
  logic [3:0] mmio_be;
  logic [31:0] mmio_rdata=0;
  logic mmio_ready=1;
  rv32_core #(.RESET_PC(BASE)) dut(.*);
  initial begin
    for(i=0;i<2048;i=i+1) mem[i]=0;
    $readmemh("tests/rv32i_trace.mem",mem);
    trace_fd=$fopen("tests/rv32i_trace.rtl.log","w");
    if(trace_fd==0)$fatal(1,"cannot open trace output");
    repeat(3) @(posedge clk);
    @(negedge clk);rst=0;
    for(cycles=0;cycles<300;cycles=cycles+1) begin
      @(negedge clk);
      if(debug_hazard[2]) redirects=redirects+1;
      if(debug_hazard[1]) collisions=collisions+1;
      if(debug_hazard[0]) load_stalls=load_stalls+1;
      if(retire_valid) begin
        $fdisplay(trace_fd,"%08x %08x %0d %0d %08x %0d %0d %08x %08x %01x",
          retire_pc,retire_instr,retire_rd_we,retire_rd,retire_rd_data,
          retire_mem_valid,retire_mem_we,retire_mem_addr,retire_mem_wdata,retire_mem_be);
        retired=retired+1;
        if(retire_mem_valid && retire_mem_we && retire_mem_addr==TOHOST) begin
          $fclose(trace_fd);
          if(retire_mem_wdata!=1 || mem[(TOHOST-BASE)>>2]!=1)
            $fatal(1,"program reported failure via tohost");
          if(collisions<1 || load_stalls<1 || redirects<2)
            $fatal(1,"expected hazards missing: %0d %0d %0d",collisions,load_stalls,redirects);
          $display("PASS RTL program: retired=%0d collisions=%0d load_stalls=%0d redirects=%0d",retired,collisions,load_stalls,redirects);
          $finish;
        end
      end
    end
    $fatal(1,"timeout before tohost success");
  end
  always @(posedge clk) begin
    imem_rdata<=mem[(imem_addr-BASE)>>2];
    if(dmem_re) begin
      if(dmem_we && dmem_raddr[31:2]==dmem_waddr[31:2]) dmem_rdata<=32'hxxxx_xxxx;
      else dmem_rdata<=mem[(dmem_raddr-BASE)>>2];
    end
    if(dmem_we) begin
      for(integer b=0;b<4;b=b+1)
        if(dmem_be[b]) mem[(dmem_waddr-BASE)>>2][8*b+:8]<=dmem_wdata[8*b+:8];
    end
  end
endmodule
