// One issue slot of decode for the dual-issue core: RV32I base (rv32_decode)
// plus optional M (multiply/divide), B (Zba/Zbb/Zbs/Zicond) and Zicsr /
// machine-mode system instructions.
module rv32_dslot #(
    parameter bit ENABLE_M = 1,
    parameter bit ENABLE_B = 1
) (
    input  logic [31:0] instr,
    output logic [3:0] alu,
    output logic [2:0] branch,
    output logic [1:0] src_a, src_b, size, ctype,
    output logic use1, use2, we, read, write, unsigned_ld,
    output logic jal, jalr, fence_i, illegal,
    output logic mul, div,
    output logic [2:0] mdf3,
    output logic bm,
    output logic [4:0] bm_op,
    output logic [31:0] imm,
    // Zicsr / privileged (machine mode)
    output logic csr, ecall, ebreak, mret, wfi
);
    import rv32_pkg::*;
    localparam logic [1:0] T_BRANCH = 2'd0, T_JUMP = 2'd1, T_CALL = 2'd2, T_RET = 2'd3;
    logic [2:0] imm_kind;
    logic use1_r, use2_r, we_r, illegal_r, md, bm_unary;
    rv32_decode base (
        .instr(instr), .alu_op(alu), .imm_kind(imm_kind),
        .br_type(branch), .src_a(src_a), .src_b(src_b), .mem_size(size),
        .use_rs1(use1_r), .use_rs2(use2_r), .reg_we(we_r),
        .mem_re(read), .mem_we(write), .mem_unsigned(unsigned_ld),
        .is_jal(jal), .is_jalr(jalr), .is_fence_i(fence_i), .illegal(illegal_r)
    );
    rv32_imm immediate (.instr(instr), .kind(imm_kind), .imm(imm));

    assign md = ENABLE_M && instr[6:0] == 7'b0110011 && instr[31:25] == 7'b0000001;
    assign mul = md && !instr[14];
    assign div = md && instr[14];
    assign mdf3 = instr[14:12];

    always_comb begin
        logic [6:0] f7;
        logic [2:0] f3;
        logic [11:0] i12;
        f7 = instr[31:25];
        f3 = instr[14:12];
        i12 = instr[31:20];
        bm = ENABLE_B;
        bm_unary = 0;
        bm_op = BM_ANDN;
        if (instr[6:0] == 7'b0110011) begin
            case ({f7, f3})
                {7'b0100000, 3'd7}: bm_op = BM_ANDN;
                {7'b0100000, 3'd6}: bm_op = BM_ORN;
                {7'b0100000, 3'd4}: bm_op = BM_XNOR;
                {7'b0000101, 3'd6}: bm_op = BM_MAX;
                {7'b0000101, 3'd7}: bm_op = BM_MAXU;
                {7'b0000101, 3'd4}: bm_op = BM_MIN;
                {7'b0000101, 3'd5}: bm_op = BM_MINU;
                {7'b0110000, 3'd1}: bm_op = BM_ROL;
                {7'b0110000, 3'd5}: bm_op = BM_ROR;
                {7'b0010000, 3'd2}: bm_op = BM_SH1ADD;
                {7'b0010000, 3'd4}: bm_op = BM_SH2ADD;
                {7'b0010000, 3'd6}: bm_op = BM_SH3ADD;
                {7'b0100100, 3'd1}: bm_op = BM_BCLR;
                {7'b0100100, 3'd5}: bm_op = BM_BEXT;
                {7'b0110100, 3'd1}: bm_op = BM_BINV;
                {7'b0010100, 3'd1}: bm_op = BM_BSET;
                {7'b0000111, 3'd5}: bm_op = BM_CZEQZ;
                {7'b0000111, 3'd7}: bm_op = BM_CZNEZ;
                {7'b0000100, 3'd4}: begin
                    bm_op = BM_ZEXTH;
                    bm_unary = 1;
                    if (instr[24:20] != 0) bm = 0;
                end
                default: bm = 0;
            endcase
        end else if (instr[6:0] == 7'b0010011 && f3 == 3'd1) begin
            bm_unary = 1;
            case (i12)
                12'h600: bm_op = BM_CLZ;
                12'h601: bm_op = BM_CTZ;
                12'h602: bm_op = BM_CPOP;
                12'h604: bm_op = BM_SEXTB;
                12'h605: bm_op = BM_SEXTH;
                default: begin
                    bm_unary = 0;
                    case (f7)
                        7'b0100100: bm_op = BM_BCLR;
                        7'b0110100: bm_op = BM_BINV;
                        7'b0010100: bm_op = BM_BSET;
                        default: bm = 0;
                    endcase
                end
            endcase
        end else if (instr[6:0] == 7'b0010011 && f3 == 3'd5) begin
            bm_unary = 1;
            case (i12)
                12'h287: bm_op = BM_ORCB;
                12'h698: bm_op = BM_REV8;
                default: begin
                    bm_unary = 0;
                    case (f7)
                        7'b0110000: bm_op = BM_ROR;
                        7'b0100100: bm_op = BM_BEXT;
                        default: bm = 0;
                    endcase
                end
            endcase
        end else bm = 0;
    end

    // SYSTEM opcode: CSR access (f3 != 0, 4), ECALL/EBREAK/MRET/WFI.
    wire sys_op = instr[6:0] == 7'b1110011;
    assign csr = sys_op && instr[13:12] != 2'b00;
    assign ecall = instr == 32'h0000_0073;
    assign ebreak = instr == 32'h0010_0073;
    assign mret = instr == 32'h3020_0073;
    assign wfi = instr == 32'h1050_0073;

    assign use1 = use1_r || md || bm || (csr && !instr[14]);
    assign use2 = use2_r || md || (bm && instr[6:0] == 7'b0110011 && !bm_unary);
    assign we = md || bm || csr ? instr[11:7] != 0 : we_r;
    assign illegal = illegal_r && !md && !bm && !csr && !ecall && !ebreak && !mret && !wfi;

    // Control-transfer class for the BTB/RAS (RISC-V link-register hints).
    wire rd_link = instr[11:7] == 5'd1 || instr[11:7] == 5'd5;
    wire rs1_link = instr[19:15] == 5'd1 || instr[19:15] == 5'd5;
    always_comb begin
        ctype = T_BRANCH;
        if (jal) ctype = rd_link ? T_CALL : T_JUMP;
        else if (jalr) ctype = rd_link ? T_CALL : (rs1_link ? T_RET : T_JUMP);
    end
endmodule
