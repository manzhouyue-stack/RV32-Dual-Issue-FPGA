`timescale 1ns/1ps
module tb_freeze_mmio;
  logic clk=0;
  logic rst=1;
  always #5 clk=~clk;
  logic external_freeze=0;
  logic external_port_conflict=0;
  logic [31:0] imem_addr,imem_rdata,dmem_raddr,dmem_rdata,dmem_waddr,dmem_wdata;
  logic dmem_re,dmem_we;
  logic [3:0] dmem_be;
  logic mmio_valid,mmio_we,mmio_commit;
  logic [31:0] mmio_addr,mmio_wdata,mmio_rdata=32'd41;
  logic [3:0] mmio_be;
  logic mmio_ready=1;
  logic retire_valid,retire_rd_we,retire_mem_valid,retire_mem_we;
  logic [31:0] retire_pc,retire_instr,retire_rd_data,retire_mem_addr,retire_mem_wdata;
  logic [4:0] retire_rd,debug_valid;
  logic [3:0] retire_mem_be;
  logic [31:0] debug_pc_f,fault_pc,fault_instr;
  logic [2:0] debug_hazard;
  logic fault_valid;
  logic [31:0] code[0:63];
  logic [31:0] data[0:63];
  integer i,cycles,read_count=0,write_count=0,wb_freeze_count=0,load_freeze_count=0;
  integer mmio_wait=0;
  bit wb_done=0,load_done=0,mmio_done=0;

  rv32_core dut(.*);
  function automatic [31:0] addi(input [4:0] rd,rs1,input integer imm);
    addi={imm[11:0],rs1,3'b000,rd,7'b0010011};
  endfunction
  function automatic [31:0] add(input [4:0] rd,rs1,rs2);
    add={7'b0,rs2,rs1,3'b000,rd,7'b0110011};
  endfunction
  function automatic [31:0] lw(input [4:0] rd,rs1,input integer imm);
    lw={imm[11:0],rs1,3'b010,rd,7'b0000011};
  endfunction
  function automatic [31:0] sw(input [4:0] rs2,rs1,input integer imm);
    sw={imm[11:5],rs2,rs1,3'b010,imm[4:0],7'b0100011};
  endfunction
  initial begin
    for(i=0;i<64;i=i+1) begin code[i]=32'h00000013;data[i]=0;end
    data[0]=111;
    data[1]=222;
    code[0]=addi(5,0,7);
    code[1]=32'h00000013;
    code[2]=add(6,5,5);
    code[3]=lw(7,0,0);
    code[4]=lw(8,0,4);
    code[5]=32'h100000b7; // lui x1,0x10000: MMIO_BASE
    code[6]=lw(2,1,0);
    code[7]=lw(4,1,8); // held in EX while the older MMIO read waits
    code[8]=addi(3,2,1);
    code[9]=sw(3,1,4);
    code[10]=32'h0000006f;
    repeat(3) @(posedge clk);
    @(negedge clk);
    rst=0;
    for(cycles=0;cycles<100;cycles=cycles+1) begin
      @(negedge clk);
      #1;
      if(retire_valid) begin
        if(retire_pc==32'h1008 && retire_rd_data!==14)
          $fatal(1,"freeze lost WB forwarding: %08x",retire_rd_data);
        if(retire_pc==32'h100c && retire_rd_data!==111)
          $fatal(1,"freeze overwrote first load: %08x",retire_rd_data);
        if(retire_pc==32'h1010 && retire_rd_data!==222)
          $fatal(1,"second load wrong: %08x",retire_rd_data);
        if(retire_pc==32'h1018 && retire_rd_data!==41)
          $fatal(1,"MMIO load result wrong: %08x",retire_rd_data);
        if(retire_pc==32'h101c && retire_rd_data!==41)
          $fatal(1,"held EX MMIO load wrong: %08x",retire_rd_data);
        if(retire_pc==32'h1020 && retire_rd_data!==42)
          $fatal(1,"MMIO dependency wrong: %08x",retire_rd_data);
      end
      if(!wb_done && dut.w_valid && dut.w_rd==5 && dut.e_valid && dut.e_pc==32'h1008) begin
        external_freeze=1;
        wb_done=1;
        wb_freeze_count=2;
      end else if(!load_done && dut.m_valid && dut.m_pc==32'h100c && dut.e_valid && dut.e_pc==32'h1010) begin
        external_freeze=1;
        load_done=1;
        load_freeze_count=2;
      end else if(wb_freeze_count>0 || load_freeze_count>0) begin
        if(wb_freeze_count>0) wb_freeze_count=wb_freeze_count-1;
        if(load_freeze_count>0) load_freeze_count=load_freeze_count-1;
        external_freeze=(wb_freeze_count>0 || load_freeze_count>0);
      end
      if(!mmio_done && dut.m_valid && dut.m_pc==32'h1018) begin
        mmio_done=1;
        mmio_wait=3;
      end
      if(mmio_wait>0) begin
        mmio_ready=0;
        mmio_wait=mmio_wait-1;
      end else mmio_ready=1;
      if(read_count==2 && write_count==1) begin
        if(!wb_done || !load_done || !mmio_done) $fatal(1,"target scenarios missing");
        $display("PASS freeze WB forwarding, frozen Load data, MMIO single commit");
        $finish;
      end
    end
    $fatal(1,"freeze/MMIO test timed out");
  end
  always @(posedge clk) begin
    imem_rdata<=code[(imem_addr-32'h1000)>>2];
    if(dmem_re) begin
      if(dmem_raddr[31:28]==4'h1) $fatal(1,"MMIO read escaped to data RAM");
      dmem_rdata<=data[dmem_raddr[7:2]];
    end
    if(dmem_we) $fatal(1,"MMIO write escaped to data RAM");
    if(mmio_commit) begin
      if(!mmio_valid) $fatal(1,"MMIO commit without valid");
      if(mmio_we) begin
        write_count=write_count+1;
        if(mmio_addr!==32'h10000004 || mmio_wdata!==42 || mmio_be!==4'b1111)
          $fatal(1,"MMIO Store payload wrong");
      end else begin
        read_count=read_count+1;
        if(mmio_addr!==32'h10000000 && mmio_addr!==32'h10000008)
          $fatal(1,"MMIO Load address wrong");
      end
    end
  end
endmodule
