`timescale 1ns/1ps
module tb_core;
  logic clk=0,rst=1;
  always #5 clk=~clk;
  logic [31:0] imem_addr,imem_rdata,dmem_raddr,dmem_rdata,dmem_waddr,dmem_wdata;
  logic dmem_re,dmem_we,retire_valid,retire_rd_we,retire_mem_valid,retire_mem_we;
  logic [3:0] dmem_be,retire_mem_be;
  logic [31:0] retire_pc,retire_instr,retire_rd_data,retire_mem_addr,retire_mem_wdata,debug_pc_f;
  logic [4:0] retire_rd,debug_valid;
  logic [2:0] debug_hazard;
  logic fault_valid;
  logic [31:0] fault_pc,fault_instr;
  logic [31:0] code[0:255],data[0:255];
  integer i,cycle,retired=0,store_count=0,branch_flush=0,load_stall=0,collision=0,external_collisions=0;
  logic freeze_injected=0;
  logic [31:0] expected_pc[0:20];
  logic external_freeze=0;
  wire external_port_conflict;
  assign external_port_conflict=dmem_re && dmem_we &&
                                dmem_raddr[31:2]!=dmem_waddr[31:2];
  logic mmio_valid,mmio_we,mmio_commit;
  logic [31:0] mmio_addr,mmio_wdata;
  logic [3:0] mmio_be;
  logic [31:0] mmio_rdata=0;
  logic mmio_ready=1;
  rv32_core dut(.*);
  function automatic [31:0] addi(input [4:0] rd,rs1,input integer imm);
    addi={imm[11:0],rs1,3'b000,rd,7'b0010011};
  endfunction
  function automatic [31:0] add(input [4:0] rd,rs1,rs2);
    add={7'b0,rs2,rs1,3'b000,rd,7'b0110011};
  endfunction
  function automatic [31:0] sw(input [4:0] rs2,rs1,input integer imm);
    sw={imm[11:5],rs2,rs1,3'b010,imm[4:0],7'b0100011};
  endfunction
  function automatic [31:0] lw(input [4:0] rd,rs1,input integer imm);
    lw={imm[11:0],rs1,3'b010,rd,7'b0000011};
  endfunction
  function automatic [31:0] beq(input [4:0] rs1,rs2,input integer imm);
    beq={imm[12],imm[10:5],rs2,rs1,3'b000,imm[4:1],imm[11],7'b1100011};
  endfunction
  function automatic [31:0] jal(input [4:0] rd,input integer imm);
    jal={imm[20],imm[10:1],imm[11],imm[19:12],rd,7'b1101111};
  endfunction
  initial begin
    for(i=0;i<256;i=i+1) begin code[i]=32'h00000013;data[i]=0;end
    // x1=data base, chained ALU forwarding, store/load collision,
    // load-use, taken branch and JAL squash, x0 write suppression.
    code[0]=addi(1,0,0);
    code[1]=addi(2,0,7);
    code[2]=addi(3,2,5);
    code[3]=add(4,3,2);
    code[4]=sw(4,1,0);
    code[5]=lw(5,1,0);
    code[6]=add(6,5,2);
    code[7]=beq(6,0,8);      // not taken
    code[8]=beq(6,6,12);     // taken: squash next two
    code[9]=addi(7,0,99);
    code[10]=sw(7,1,4);
    code[11]=jal(8,12);      // squash next two
    code[12]=addi(9,0,77);
    code[13]=sw(9,1,8);
    code[14]=addi(0,0,123);
    code[15]=addi(10,0,42);
    // At the second collision, x11 is only available through WB forwarding.
    // EX must retain it while the older Store uses the memory port.
    code[16]=addi(11,0,16);
    code[17]=sw(11,11,0);
    code[18]=lw(12,11,0);
    code[19]=add(13,12,11);
    // A shared ITCM B port conflicts even for different word addresses.
    code[20]=addi(14,0,20);
    code[21]=sw(11,14,0);
    code[22]=lw(15,11,0);
    code[23]=add(16,15,11);
    code[24]=jal(0,0);       // stop loop
    expected_pc[0]=32'h1000; expected_pc[1]=32'h1004; expected_pc[2]=32'h1008;
    expected_pc[3]=32'h100c; expected_pc[4]=32'h1010; expected_pc[5]=32'h1014;
    expected_pc[6]=32'h1018; expected_pc[7]=32'h101c; expected_pc[8]=32'h1020;
    expected_pc[9]=32'h102c; expected_pc[10]=32'h1038;
    expected_pc[11]=32'h103c; expected_pc[12]=32'h1040;
    expected_pc[13]=32'h1044; expected_pc[14]=32'h1048;
    expected_pc[15]=32'h104c; expected_pc[16]=32'h1050;
    expected_pc[17]=32'h1054; expected_pc[18]=32'h1058;
    expected_pc[19]=32'h105c; expected_pc[20]=32'h1060;
    repeat(3) @(posedge clk);
    @(negedge clk);rst=0;
    for(cycle=0;cycle<120 && retired<21;cycle=cycle+1) begin
      @(negedge clk);
      if(debug_hazard[2]) branch_flush=branch_flush+1;
      if(debug_hazard[1]) collision=collision+1;
      if(debug_hazard[1] && dmem_raddr[31:2]!=dmem_waddr[31:2]) external_collisions=external_collisions+1;
      if(debug_hazard[0]) load_stall=load_stall+1;
      if(retire_valid) begin
        $display("retire pc=%08x instr=%08x rd=%0d data=%08x mem=%0d we=%0d addr=%08x",retire_pc,retire_instr,retire_rd,retire_rd_data,retire_mem_valid,retire_mem_we,retire_mem_addr);
        if(retired<21 && retire_pc!==expected_pc[retired])
          $fatal(1,"retire order: index=%0d pc=%08x expected=%08x",retired,retire_pc,expected_pc[retired]);
        if(retire_pc==32'h1024 || retire_pc==32'h1028 || retire_pc==32'h1030 || retire_pc==32'h1034)
          $fatal(1,"squashed instruction retired: %08x",retire_pc);
        if(retire_pc==32'h1018 && retire_rd_data!=26) $fatal(1,"load-use value wrong");
        if(retire_pc==32'h102c && retire_rd_data!=32'h1030) $fatal(1,"JAL link wrong");
        if(retire_pc==32'h103c && retire_rd_data!=42) $fatal(1,"final value wrong");
        if(retire_pc==32'h1048 && retire_rd_data!=16) $fatal(1,"held EX lost WB-forwarded base");
        if(retire_pc==32'h104c && retire_rd_data!=32) $fatal(1,"held EX dependent result wrong");
        if(retire_pc==32'h1058 && retire_rd_data!=16) $fatal(1,"shared-port replay returned wrong data");
        if(retire_pc==32'h105c && retire_rd_data!=32) $fatal(1,"shared-port load-use result wrong");
        if(retire_mem_valid && retire_mem_we) store_count=store_count+1;
        retired=retired+1;
      end
      // Freeze the third Store for exactly one edge. It must write once on resume.
      if(!freeze_injected && dut.m_valid && dut.m_mem_we && dut.m_addr==20) begin
        external_freeze=1;freeze_injected=1;
      end else if(external_freeze) external_freeze=0;
    end
    if(data[0]!=19 || data[1]!=0 || data[2]!=0 || data[4]!=16 || data[5]!=16) $fatal(1,"memory side effect wrong");
    if(retired!=21 || store_count!=3 || collision<3 || external_collisions<1 || load_stall<3 || branch_flush<2 || !freeze_injected)
      $fatal(1,"missing expected controls stores=%0d collision=%0d external=%0d load=%0d redirect=%0d freeze=%0d",store_count,collision,external_collisions,load_stall,branch_flush,freeze_injected);
    $display("PASS core directed test");$finish;
  end
  always @(posedge clk) begin
    if(rst) imem_rdata<=code[0];
    else imem_rdata<=code[(imem_addr-32'h1000)>>2];
    if(dmem_re) begin
      if(dmem_we) dmem_rdata<=32'hxxxx_xxxx;
      else dmem_rdata<=data[dmem_raddr[9:2]];
    end
    if(dmem_we) begin
      for(integer b=0;b<4;b=b+1) if(dmem_be[b]) data[dmem_waddr[9:2]][8*b+:8]<=dmem_wdata[8*b+:8];
    end
  end
endmodule
