`timescale 1ns/1ps
module tb_control;
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
  logic [31:0] mem[0:63];
  integer i,cycles,stores=0,fences=0,patched=0;
  logic mmio_valid,mmio_we,mmio_commit;
  logic [31:0] mmio_addr,mmio_wdata;
  logic [3:0] mmio_be;
  logic [31:0] mmio_rdata=0;
  logic mmio_ready=1;
  rv32_core #(.RESET_PC(32'h1000)) dut(.*);
  function automatic [31:0] beq(input [4:0] rs1,rs2,input integer imm);
    beq={imm[12],imm[10:5],rs2,rs1,3'b000,imm[4:1],imm[11],7'b1100011};
  endfunction
  initial begin
    $dumpfile("tests/if_control.vcd");$dumpvars(0,tb_control);
    for(i=0;i<64;i=i+1) mem[i]=32'h00000013;
    mem[0]=32'h00000097; // auipc x1,0
    mem[1]=32'h01808093; // addi x1,x1,24: patch PC 0x1018
    mem[2]=32'h00100137; // lui x2,0x00100
    mem[3]=32'h51310113; // addi x2,x2,0x513: addi x10,x0,1 encoding
    mem[4]=32'h0020a023; // sw x2,0(x1)
    mem[5]=32'h0000100f; // fence.i
    mem[6]=32'h00300513; // old instruction: addi x10,x0,3
    mem[7]=beq(0,0,12);  // redirect to 0x1028
    mem[8]=32'hffffffff; // illegal but on wrong path
    mem[9]=32'h00a02023; // wrong-path sw x10,0(x0)
    mem[10]=32'h0000006f; // stop loop
    repeat(3) @(posedge clk);
    @(negedge clk);rst=0;
    for(cycles=0;cycles<80;cycles=cycles+1) begin
      @(negedge clk);
      if(fault_valid)$fatal(1,"wrong-path illegal instruction raised fault");
      if(retire_valid) begin
        if(retire_pc==32'h1014) fences=fences+1;
        if(retire_pc==32'h1018) begin
          patched=patched+1;
          if(retire_instr!==32'h00100513 || retire_rd_data!==1)
            $fatal(1,"fence.i failed to refetch patched instruction");
        end
        if(retire_pc==32'h1020 || retire_pc==32'h1024)
          $fatal(1,"wrong-path instruction retired");
        if(retire_pc==32'h1028) begin
          if(stores!=1 || fences!=1 || patched!=1)
            $fatal(1,"control counts store=%0d fence=%0d patched=%0d",stores,fences,patched);
          $display("PASS fence.i refetch and wrong-path squash, cycles=%0d",cycles);
          $finish;
        end
      end
    end
    $fatal(1,"control test timed out");
  end
  always @(posedge clk) begin
    if(dmem_we) begin
      stores=stores+1;
      if(dmem_waddr!=32'h1018) $fatal(1,"wrong-path store reached memory");
      for(integer b=0;b<4;b=b+1)
        if(dmem_be[b]) mem[(dmem_waddr-32'h1000)>>2][8*b+:8]<=dmem_wdata[8*b+:8];
    end
    // A dual-port same-address read/write may return an undefined old value.
    if(dmem_we && imem_addr[31:2]==dmem_waddr[31:2]) imem_rdata<=32'hxxxx_xxxx;
    else imem_rdata<=mem[(imem_addr-32'h1000)>>2];
    if(dmem_re) dmem_rdata<=mem[(dmem_raddr-32'h1000)>>2];
  end
endmodule
