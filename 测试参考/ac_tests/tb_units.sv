`timescale 1ns/1ps
module tb_units;
 logic clk=0;
 always #5 clk=~clk;
 logic [3:0] op;
 logic [31:0] a,b,y,ref_y,instr,imm,wdata,rdata1,rdata2;
 logic [2:0] kind,imm_kind,br_type;
 logic [1:0] src_a,src_b,mem_size;
 logic use_rs1,use_rs2,reg_we,mem_re,mem_we,mem_unsigned,is_jal,is_jalr,is_fence_i,illegal,we;
 logic [3:0] alu_op;
 logic [4:0] waddr,raddr1,raddr2;
 integer i,j;
 rv32_alu alu(.*);
 rv32_imm immgen(.*);
 rv32_decode dec(.*);
 rv32_regfile rf(.*);
 function automatic [31:0] model(input [3:0] f,input [31:0] x,z);
   case(f)
     0:model=x+z;1:model=x-z;2:model=x<<z[4:0];
     3:model=($signed(x)<$signed(z));4:model=(x<z);
     5:model=x^z;6:model=x>>z[4:0];7:model=$signed(x)>>>z[4:0];
     8:model=x|z;9:model=x&z;default:model=0;
   endcase
 endfunction
 initial begin
   we=0;waddr=0;wdata=0;raddr1=0;raddr2=0;
   for(i=0;i<10;i=i+1) for(j=0;j<200;j=j+1) begin
     op=i;a=$random;b=$random;
     if(j==0)begin a=32'h80000000;b=1;end
     if(j==1)begin a=32'hffffffff;b=31;end
     if(j==2)begin a=32'h80000000;b=0;end
     #1;ref_y=model(op,a,b);
     if(y!==ref_y)$fatal(1,"ALU op=%0d a=%h b=%h got=%h expected=%h",op,a,b,y,ref_y);
   end
   instr=32'hfff00093;kind=0;#1;if(imm!==32'hffffffff)$fatal(1,"I immediate");
   instr=32'hfe20ae23;kind=1;#1;if(imm!==32'hfffffffc)$fatal(1,"S immediate");
   instr=32'h00000063;kind=2;#1;if(imm!==0)$fatal(1,"B immediate");
   instr=32'h123450b7;kind=3;#1;if(imm!==32'h12345000)$fatal(1,"U immediate");
   instr=32'h0000006f;kind=4;#1;if(imm!==0)$fatal(1,"J immediate");
   instr=32'h00000093;#1;if(illegal || !reg_we || !use_rs1 || use_rs2)$fatal(1,"ADDI decode");
   instr=32'h0000a283;#1;if(illegal || !mem_re || use_rs2)$fatal(1,"LW decode");
   instr=32'h0040a023;#1;if(illegal || !mem_we || !use_rs2 || reg_we)$fatal(1,"SW decode");
   instr=32'h00000073;#1;if(!illegal || reg_we)$fatal(1,"SYSTEM encoding accepted");
   instr=32'h020000b3;#1;if(!illegal || reg_we)$fatal(1,"M extension accepted");
   raddr1=0;waddr=0;wdata=32'hdeadbeef;we=1;#1;
   if(rdata1!==0)$fatal(1,"x0 write-through");
   @(negedge clk);waddr=5;wdata=32'h12345678;raddr1=5;raddr2=0;
   #1;if(rdata1!==wdata || rdata2!==0)$fatal(1,"WB-to-ID bypass");
   @(posedge clk);#1;we=0;#1;
   if(rdata1!==32'h12345678)$fatal(1,"register write");
   $display("PASS unit tests: 2000 ALU vectors, decode, immediates, regfile");$finish;
 end
endmodule
