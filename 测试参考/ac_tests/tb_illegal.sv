`timescale 1ns/1ps
module tb_illegal;
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
  logic [31:0] mem[0:15];
  integer i,cycles,retired=0;
  logic mmio_valid,mmio_we,mmio_commit;
  logic [31:0] mmio_addr,mmio_wdata;
  logic [3:0] mmio_be;
  logic [31:0] mmio_rdata=0;
  logic mmio_ready=1;
  rv32_core #(.RESET_PC(32'h1000)) dut(.*);
  initial begin
    for(i=0;i<16;i=i+1) mem[i]=32'h00000013;
    mem[0]=32'h00100093; // addi x1,x0,1
    mem[1]=32'hffffffff; // unsupported instruction
    mem[2]=32'h00200113; // younger instruction must not commit
    repeat(3) @(posedge clk);
    @(negedge clk);rst=0;
    for(cycles=0;cycles<25;cycles=cycles+1) begin
      @(negedge clk);
      if(dmem_we)$fatal(1,"unexpected store");
      if(retire_valid) begin
        retired=retired+1;
        if(retire_pc!==32'h1000 || retire_rd_data!==1)
          $fatal(1,"wrong instruction retired before fault");
      end
      if(fault_valid) begin
        if(fault_pc!==32'h1004 || fault_instr!==32'hffffffff || retired!=1)
          $fatal(1,"incorrect illegal-instruction stop state");
        repeat(3) @(negedge clk);
        if(!fault_valid || retire_valid || debug_valid[3:1]!=0)
          $fatal(1,"core failed to remain halted");
        $display("PASS illegal instruction halts at MEM without younger side effects");
        $finish;
      end
    end
    $fatal(1,"fault was not reported");
  end
  always @(posedge clk) imem_rdata<=mem[(imem_addr-32'h1000)>>2];
  assign dmem_rdata=0;
endmodule
