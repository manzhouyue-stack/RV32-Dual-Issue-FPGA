module rv32_decode(input logic [31:0] instr,
 output logic [3:0] alu_op, output logic [2:0] imm_kind,br_type,
 output logic [1:0] src_a,src_b,mem_size,
 output logic use_rs1,use_rs2,reg_we,mem_re,mem_we,mem_unsigned,is_jal,is_jalr,is_fence_i,illegal);
  import rv32_pkg::*;
  // Named encodings are defined in rv32_pkg.sv.
  logic [6:0] opc,funct7;
  logic [2:0] f3;
  always_comb begin
    opc=instr[6:0];
 f3=instr[14:12];
 funct7=instr[31:25];
    alu_op=ALU_ADD;
 imm_kind=IMM_I;
 br_type=BR_NONE;
 src_a=SRC_A_RS1;
 src_b=SRC_B_RS2;
 mem_size=MEM_WORD;
    use_rs1=0;
    use_rs2=0;
    reg_we=0;
    mem_re=0;
    mem_we=0;
    mem_unsigned=0;
    is_jal=0;
    is_jalr=0;
    is_fence_i=0;
    illegal=0;
    case(opc)
      7'b0110111: begin src_a=SRC_A_ZERO;
      src_b=SRC_B_IMM;
      imm_kind=IMM_U;
      reg_we=1;
      end // LUI
      7'b0010111: begin src_a=SRC_A_PC;
      src_b=SRC_B_IMM;
      imm_kind=IMM_U;
      reg_we=1;
      end // AUIPC
      7'b1101111: begin src_a=SRC_A_PC;
      src_b=SRC_B_FOUR;
      imm_kind=IMM_J;
      reg_we=1;
      is_jal=1;
      end
      7'b1100111: begin src_a=SRC_A_PC;
      src_b=SRC_B_FOUR;
      use_rs1=1;
      reg_we=1;
      is_jalr=1;
        if(f3!=0) illegal=1;
        end
      7'b1100011: begin imm_kind=IMM_B;
      use_rs1=1;
      use_rs2=1;
        case(f3)
          0:br_type=BR_EQ;
          1:br_type=BR_NE;
          4:br_type=BR_LT;
          5:br_type=BR_GE;
          6:br_type=BR_LTU;
          7:br_type=BR_GEU;
          default:illegal=1;
        endcase
      end
      7'b0000011: begin src_b=SRC_B_IMM;
      use_rs1=1;
      mem_re=1;
      reg_we=1;
        case(f3)
          0:mem_size=MEM_BYTE;
          1:mem_size=MEM_HALF;
          2:mem_size=MEM_WORD;
          4:begin mem_size=MEM_BYTE;
          mem_unsigned=1;
          end
          5:begin mem_size=MEM_HALF;
          mem_unsigned=1;
          end
          default:illegal=1;
        endcase
      end
      7'b0100011: begin src_b=SRC_B_IMM;
      imm_kind=IMM_S;
      use_rs1=1;
      use_rs2=1;
      mem_we=1;
        case(f3)
          0:mem_size=MEM_BYTE;
          1:mem_size=MEM_HALF;
          2:mem_size=MEM_WORD;
          default:illegal=1;
        endcase
      end
      7'b0010011: begin src_b=SRC_B_IMM;
      use_rs1=1;
      reg_we=1;
        case(f3)
          0:alu_op=ALU_ADD;
          2:alu_op=ALU_SLT;
          3:alu_op=ALU_SLTU;
          4:alu_op=ALU_XOR;
          6:alu_op=ALU_OR;
          7:alu_op=ALU_AND;
          1:begin alu_op=ALU_SLL;
          if(funct7!=0)illegal=1;
          end
          5:begin alu_op=instr[30]?ALU_SRA:ALU_SRL;
          if(funct7!=0 && funct7!=7'b0100000)illegal=1;
          end
        endcase
      end
      7'b0110011: begin use_rs1=1;
      use_rs2=1;
      reg_we=1;
        case(f3)
          0:begin alu_op=instr[30]?ALU_SUB:ALU_ADD;
          if(funct7!=0 && funct7!=7'b0100000)illegal=1;
          end
          1:begin alu_op=ALU_SLL;
          if(funct7!=0)illegal=1;
          end
          2:begin alu_op=ALU_SLT;
          if(funct7!=0)illegal=1;
          end
          3:begin alu_op=ALU_SLTU;
          if(funct7!=0)illegal=1;
          end
          4:begin alu_op=ALU_XOR;
          if(funct7!=0)illegal=1;
          end
          5:begin alu_op=instr[30]?ALU_SRA:ALU_SRL;
          if(funct7!=0 && funct7!=7'b0100000)illegal=1;
          end
          6:begin alu_op=ALU_OR;
          if(funct7!=0)illegal=1;
          end
          7:begin alu_op=ALU_AND;
          if(funct7!=0)illegal=1;
          end
        endcase
      end
      7'b0001111: begin
        if(f3==1) is_fence_i=1;
        else if(f3!=0) illegal=1;
      end
      default:illegal=1;
    endcase
    if(illegal) begin use_rs1=0;
    use_rs2=0;
    reg_we=0;
    mem_re=0;
    mem_we=0;
      is_jal=0;
      is_jalr=0;
      is_fence_i=0;
      br_type=BR_NONE;
      end
    if(instr[11:7]==0) reg_we=0;
  end
endmodule
