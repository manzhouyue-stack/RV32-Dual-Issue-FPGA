package rv32_pkg;
  // These encodings are shared by the decoder and the datapath.
  typedef enum logic [3:0] {
    ALU_ADD=4'd0, ALU_SUB=4'd1, ALU_SLL=4'd2, ALU_SLT=4'd3,
    ALU_SLTU=4'd4, ALU_XOR=4'd5, ALU_SRL=4'd6, ALU_SRA=4'd7,
    ALU_OR=4'd8, ALU_AND=4'd9
  } alu_op_t;
  typedef enum logic [2:0] {
    IMM_I=3'd0, IMM_S=3'd1, IMM_B=3'd2, IMM_U=3'd3, IMM_J=3'd4
  } imm_kind_t;
  typedef enum logic [2:0] {
    BR_NONE=3'd0, BR_EQ=3'd1, BR_NE=3'd2, BR_LT=3'd3,
    BR_GE=3'd4, BR_LTU=3'd5, BR_GEU=3'd6
  } branch_t;
  typedef enum logic [1:0] {
    SRC_A_RS1=2'd0, SRC_A_PC=2'd1, SRC_A_ZERO=2'd2
  } src_a_t;
  typedef enum logic [1:0] {
    SRC_B_RS2=2'd0, SRC_B_IMM=2'd1, SRC_B_FOUR=2'd2
  } src_b_t;
  typedef enum logic [1:0] {
    MEM_BYTE=2'd0, MEM_HALF=2'd1, MEM_WORD=2'd2
  } mem_size_t;
  // Zba/Zbb/Zbs/Zicond operations (rv32_bitmanip)
  typedef enum logic [4:0] {
    BM_ANDN=5'd0, BM_ORN=5'd1, BM_XNOR=5'd2, BM_MAX=5'd3, BM_MAXU=5'd4, BM_MIN=5'd5,
    BM_MINU=5'd6, BM_ROL=5'd7, BM_ROR=5'd8, BM_SH1ADD=5'd9, BM_SH2ADD=5'd10,
    BM_SH3ADD=5'd11, BM_ZEXTH=5'd12, BM_BCLR=5'd13, BM_BEXT=5'd14, BM_BINV=5'd15,
    BM_BSET=5'd16, BM_CLZ=5'd17, BM_CTZ=5'd18, BM_CPOP=5'd19, BM_SEXTB=5'd20,
    BM_SEXTH=5'd21, BM_ORCB=5'd22, BM_REV8=5'd23, BM_CZEQZ=5'd24, BM_CZNEZ=5'd25
  } bm_op_t;
endpackage
