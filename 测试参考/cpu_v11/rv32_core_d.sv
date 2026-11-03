// v1.1 dual-issue in-order RV32IM(+B)+Zicsr core with machine-mode traps
// (v1.0 + fetch pairs kept inside 32-byte I-cache rows for the DDR region).
// Traps: precise exceptions (taken at MEM commit, store access faults at WB)
// and interrupts (injected on the oldest instruction leaving EX). If mtvec
// was never programmed, a fault halts the core as in v0.4-v0.9 (fault_* / LED).
//  IF : two consecutive instructions per cycle from the banked ITCM; per-slot
//       BTB/2-bit/RAS prediction (a predicted-taken slot 0 ends the pair)
//  FQ : 6-entry fetch queue with decode bypass when empty
//  ID : two slots, in-order issue; slot 1 pairs with slot 0 unless it depends
//       on it, both access memory, both multiply, or either must serialise
//  EX : two lanes (ALU, Zb*, branch); one shared load issue port and divider
//  MEM: shared store/load completion unit and multiplier, two result lanes
//  WB : two register-file writes; lane 1 is always the younger instruction
// Lane 0 is older than lane 1 in the same stage; any instruction in a later
// stage is older than any in an earlier stage.
module rv32_core_d #(
    parameter logic [31:0] RESET_PC = 32'h0000_0000,
    parameter int BTB_BITS = 6,
    parameter bit BP_ENABLE = 1,
    // pc[31:16] of the 64 KiB region the predictor covers (ITCM by default)
    parameter logic [15:0] PRED_HI = 16'h0,
    parameter bit ENABLE_M = 1,
    parameter bit ENABLE_B = 1
) (
    input  logic clk,
    input  logic rst,
    input  logic external_freeze,
    output logic if_valid,
    output logic [31:0] if_addr,
    input  logic if_ready,
    input  logic if_rvalid,
    input  logic [31:0] if_rdata,
    input  logic if_error,
    input  logic [31:0] if_rdata1,     // word at if_addr + 4
    input  logic if_error1,
    output logic ld_valid,
    output logic [31:0] ld_addr,
    output logic [1:0] ld_size,
    output logic [31:0] ld_maddr,     // MEM-stage load address (registered); valid with MEM-issued loads
    input  logic ld_ready,
    input  logic ld_rvalid,
    input  logic [31:0] ld_rdata,
    input  logic ld_error,
    output logic st_valid,
    output logic [31:0] st_addr,
    output logic [1:0] st_size,
    output logic [31:0] st_wdata,
    output logic [3:0] st_wstrb,
    input  logic st_ready,
    input  logic st_done,
    input  logic st_error,
    output logic retire_valid,
    output logic [31:0] retire_pc,
    output logic [31:0] retire_instr,
    output logic retire_rd_we,
    output logic [4:0] retire_rd,
    output logic [31:0] retire_rd_data,
    output logic retire_mem_valid,
    output logic retire_mem_we,
    output logic [31:0] retire_mem_addr,
    output logic [31:0] retire_mem_wdata,
    output logic [3:0] retire_mem_be,
    output logic retire1_valid,
    output logic [31:0] retire1_pc,
    output logic [31:0] retire1_instr,
    output logic retire1_rd_we,
    output logic [4:0] retire1_rd,
    output logic [31:0] retire1_rd_data,
    output logic retire1_mem_valid,
    output logic retire1_mem_we,
    output logic [31:0] retire1_mem_addr,
    output logic [31:0] retire1_mem_wdata,
    output logic [3:0] retire1_mem_be,
    output logic fault_valid,
    output logic [3:0] fault_cause,
    output logic [31:0] fault_pc,
    output logic [31:0] fault_instr,
    output logic [31:0] fault_addr,
    output logic [4:0] debug_valid,
    // machine interrupts (level) and the platform timer for the time CSR
    input  logic irq_soft,
    input  logic irq_timer,
    input  logic irq_ext,
    input  logic [63:0] mtime
);
    import rv32_pkg::*;
    localparam int BTB_N = 1 << BTB_BITS;
    localparam int TAG_W = 14 - BTB_BITS;      // predicted region word index is pc[15:2]
    localparam int QD = 6;
    localparam logic [1:0] T_BRANCH = 2'd0, T_JUMP = 2'd1, T_CALL = 2'd2, T_RET = 2'd3;
    localparam logic [1:0] M_IDLE = 2'd0, M_WAIT = 2'd1, M_RESP = 2'd2;

    logic stop, redirect, ex_redirect, mem_redirect, fault_commit, wb_fault, kill_all;
    logic [31:0] redirect_pc, ex_redirect_pc;
    assign stop = external_freeze || fault_valid;

    // ==================================================================
    // Branch prediction: two read ports (slot 0 / slot 1) via duplicated
    // distributed-RAM tables, one registered write port.
    // ==================================================================
    logic [BTB_N-1:0] btb_v;
    logic [TAG_W-1:0] btb_tag0 [0:BTB_N-1], btb_tag1 [0:BTB_N-1];
    logic [13:0] btb_tgt0 [0:BTB_N-1], btb_tgt1 [0:BTB_N-1];
    logic [1:0] btb_type0 [0:BTB_N-1], btb_type1 [0:BTB_N-1];
    logic [1:0] btb_ctr0 [0:BTB_N-1], btb_ctr1 [0:BTB_N-1];
    logic [13:0] ras_s [0:3];
    logic [13:0] ras_c [0:3];
    logic [1:0] ras_sp, ras_cp;

    // ==================================================================
    // Fetch
    // ==================================================================
    logic [31:0] pc_f, pc_f4;
    logic [BTB_BITS-1:0] fi0, fi1;
    logic fh0, fh1, fpt0, fpt1, f_v1, f_accept;
    logic [1:0] ft0, ft1, fc0, fc1;
    logic [13:0] fg0, fg1;
    assign pc_f4 = pc_f + 4;
    assign fi0 = pc_f[BTB_BITS+1:2];
    assign fi1 = pc_f4[BTB_BITS+1:2];
    assign ft0 = btb_type0[fi0];
    assign ft1 = btb_type1[fi1];
    assign fc0 = btb_ctr0[fi0];
    assign fc1 = btb_ctr1[fi1];
    assign fh0 = BP_ENABLE && btb_v[fi0] && btb_tag0[fi0] == pc_f[15:BTB_BITS+2] && pc_f[31:16] == PRED_HI;
    assign fh1 = BP_ENABLE && btb_v[fi1] && btb_tag1[fi1] == pc_f4[15:BTB_BITS+2] && pc_f4[31:16] == PRED_HI;
    assign fpt0 = fh0 && (ft0 != T_BRANCH || fc0[1]);
    assign fpt1 = fh1 && (ft1 != T_BRANCH || fc1[1]);
    assign fg0 = ft0 == T_RET ? ras_s[ras_sp] : btb_tgt0[fi0];
    assign fg1 = ft1 == T_RET ? ras_s[ras_sp] : btb_tgt1[fi1];
    // Slot 1 exists unless slot 0 is predicted taken or the pair would wrap
    // the 64 KiB bank row.
    // In the cached DDR region a pair never crosses a 32-byte I-cache row.
    assign f_v1 = !fpt0 && pc_f[15:2] != 14'h3fff && !(pc_f[31:29] == 3'b100 && pc_f[4:2] == 3'b111);

    logic f2_valid, f2_v1;
    logic [31:0] f2_pc;
    logic f2_pt0, f2_pt1, f2_h0, f2_h1;
    logic [13:0] f2_g0, f2_g1;
    logic [1:0] f2_c0, f2_c1;

    logic [2:0] q_count;
    logic [31:0] q_pc [0:QD-1];
    logic [31:0] q_in [0:QD-1];
    logic q_err [0:QD-1], q_pt [0:QD-1], q_hit [0:QD-1];
    logic [13:0] q_ptgt [0:QD-1];
    logic [1:0] q_ctr [0:QD-1];

    assign if_valid = !stop && ({1'b0, q_count} + (f2_valid ? 4'd2 : 4'd0) <= QD - 2);
    assign if_addr = pc_f;
    assign f_accept = if_valid && if_ready;

    // Incoming pair from the RAM this cycle (discarded on any redirect).
    logic in_v0, in_v1;
    assign in_v0 = f2_valid && !redirect;
    assign in_v1 = f2_valid && f2_v1 && !redirect;

    // Instruction stream view: queue entries, then the incoming pair.
    logic [31:0] s_pc [0:1], s_in [0:1];
    logic s_v [0:1], s_err [0:1], s_pt [0:1], s_hit [0:1];
    logic [13:0] s_ptgt [0:1];
    logic [1:0] s_ctr [0:1];
    always_comb begin
        for (int k = 0; k < 2; k++) begin
            if (q_count > k) begin
                s_v[k] = 1; s_pc[k] = q_pc[k]; s_in[k] = q_in[k]; s_err[k] = q_err[k];
                s_pt[k] = q_pt[k]; s_ptgt[k] = q_ptgt[k]; s_hit[k] = q_hit[k]; s_ctr[k] = q_ctr[k];
            end else if (q_count == k) begin
                s_v[k] = f2_valid; s_pc[k] = f2_pc; s_in[k] = if_rdata; s_err[k] = if_error;
                s_pt[k] = f2_pt0; s_ptgt[k] = f2_g0; s_hit[k] = f2_h0; s_ctr[k] = f2_c0;
            end else begin
                s_v[k] = f2_valid && f2_v1; s_pc[k] = f2_pc + 4; s_in[k] = if_rdata1; s_err[k] = if_error1;
                s_pt[k] = f2_pt1; s_ptgt[k] = f2_g1; s_hit[k] = f2_h1; s_ctr[k] = f2_c1;
            end
        end
    end

    // ==================================================================
    // Decode (two slots) and register read
    // ==================================================================
    logic [3:0] d_alu [0:1];
    logic [2:0] d_branch [0:1], d_mdf3 [0:1];
    logic [1:0] d_src_a [0:1], d_src_b [0:1], d_size [0:1], d_type [0:1];
    logic d_use1 [0:1], d_use2 [0:1], d_we [0:1], d_read [0:1], d_write [0:1], d_uns [0:1];
    logic d_jal [0:1], d_jalr [0:1], d_fence_i [0:1], d_illegal [0:1], d_mul [0:1], d_div [0:1], d_bm [0:1];
    logic [4:0] d_bm_op [0:1];
    logic [31:0] d_imm [0:1];
    logic d_csr [0:1], d_ecall [0:1], d_ebreak [0:1], d_mret [0:1], d_wfi [0:1];
    for (genvar k = 0; k < 2; k++) begin : g_dec
        rv32_dslot #(.ENABLE_M(ENABLE_M), .ENABLE_B(ENABLE_B)) dec (
            .instr(s_in[k]), .alu(d_alu[k]), .branch(d_branch[k]), .src_a(d_src_a[k]),
            .src_b(d_src_b[k]), .size(d_size[k]), .ctype(d_type[k]), .use1(d_use1[k]),
            .use2(d_use2[k]), .we(d_we[k]), .read(d_read[k]), .write(d_write[k]),
            .unsigned_ld(d_uns[k]), .jal(d_jal[k]), .jalr(d_jalr[k]), .fence_i(d_fence_i[k]),
            .illegal(d_illegal[k]), .mul(d_mul[k]), .div(d_div[k]), .mdf3(d_mdf3[k]),
            .bm(d_bm[k]), .bm_op(d_bm_op[k]), .imm(d_imm[k]),
            .csr(d_csr[k]), .ecall(d_ecall[k]), .ebreak(d_ebreak[k]), .mret(d_mret[k]), .wfi(d_wfi[k]));
    end

    logic w_valid [0:1], w_we [0:1], w_write [0:1], w_mem [0:1];
    logic [4:0] w_rd [0:1];
    logic [31:0] w_data [0:1], w_pc [0:1], w_instr [0:1], w_addr [0:1], w_store [0:1];
    logic [3:0] w_be [0:1];
    logic wbf0, wbf1;
    logic [4:0] rf_ra [0:3];
    logic [31:0] rf_rd [0:3];
    assign rf_ra[0] = s_in[0][19:15];
    assign rf_ra[1] = s_in[0][24:20];
    assign rf_ra[2] = s_in[1][19:15];
    assign rf_ra[3] = s_in[1][24:20];
    rv32_regfile2 registers (
        .clk(clk),
        .we0(w_valid[0] && w_we[0] && !wbf0), .wa0(w_rd[0]), .wd0(w_data[0]),
        .we1(w_valid[1] && w_we[1] && !wbf0 && !wbf1), .wa1(w_rd[1]), .wd1(w_data[1]),
        .ra(rf_ra), .rd(rf_rd));

    // ==================================================================
    // EX lane state
    // ==================================================================
    logic e_valid [0:1];
    logic [31:0] e_pc [0:1], e_pc4 [0:1], e_br_target [0:1], e_instr [0:1];
    logic [4:0] e_rs1 [0:1], e_rs2 [0:1], e_rd [0:1];
    logic [31:0] e_value1 [0:1], e_value2 [0:1], e_imm [0:1];
    logic [3:0] e_alu [0:1];
    logic [2:0] e_branch [0:1], e_mdf3 [0:1];
    logic [1:0] e_src_a [0:1], e_src_b [0:1], e_size [0:1], e_type [0:1], e_ctr [0:1];
    logic e_we [0:1], e_read [0:1], e_write [0:1], e_uns [0:1], e_jal [0:1], e_jalr [0:1];
    logic e_fence_i [0:1], e_illegal [0:1], e_ffault [0:1], e_pt [0:1], e_hit [0:1];
    logic e_mul [0:1], e_div [0:1], e_bm [0:1];
    logic e_csr [0:1], e_ecall [0:1], e_ebreak [0:1], e_mret [0:1];
    logic [4:0] e_bm_op [0:1];
    logic [13:0] e_ptgt [0:1];

    // Issue hazards: a load or multiply in EX feeds its consumer one cycle late.
    function automatic logic ex_late_hit(input logic [4:0] r);
        ex_late_hit = r != 0 && (
            (e_valid[0] && (e_read[0] || e_mul[0] || e_csr[0]) && e_rd[0] == r) ||
            (e_valid[1] && (e_read[1] || e_mul[1] || e_csr[1]) && e_rd[1] == r));
    endfunction
    logic haz [0:1], solo [0:1], pair_ok, d_fire0, d_fire1, e_space, e_fire, e_can_go;
    always_comb begin
        for (int k = 0; k < 2; k++) begin
            haz[k] = (d_use1[k] && ex_late_hit(s_in[k][19:15])) || (d_use2[k] && ex_late_hit(s_in[k][24:20]));
            // Issue alone: serialising, faulting or multi-cycle instructions.
            solo[k] = d_fence_i[k] || d_illegal[k] || s_err[k] || d_div[k] ||
                      d_csr[k] || d_ecall[k] || d_ebreak[k] || d_mret[k] || d_wfi[k];
        end
        pair_ok = s_v[1] && !haz[1] && !solo[0] && !solo[1] &&
            !(d_we[0] && ((d_use1[1] && s_in[1][19:15] == s_in[0][11:7]) ||
                          (d_use2[1] && s_in[1][24:20] == s_in[0][11:7]))) &&
            !((d_read[0] || d_write[0]) && (d_read[1] || d_write[1])) &&
            !(d_mul[0] && d_mul[1]);
    end
    assign e_space = !(e_valid[0] || e_valid[1]) || e_fire;
    assign d_fire0 = s_v[0] && e_space && !haz[0] && !stop && !redirect;
    assign d_fire1 = d_fire0 && pair_ok;

    // ==================================================================
    // MEM lane state
    // ==================================================================
    logic m_valid [0:1], m_we [0:1], m_read [0:1], m_write [0:1], m_fence_i [0:1], m_fault [0:1], m_mul [0:1];
    logic m_irq [0:1], m_csr, m_mret;
    logic [31:0] m_pc [0:1], m_instr [0:1], m_result [0:1], m_fault_addr [0:1];
    logic [4:0] m_rd [0:1];
    logic [3:0] m_cause [0:1];
    // shared memory unit
    logic [1:0] m_state, m_size;
    logic m_lane, m_unsigned, m_ex_issued, resp_error, m_mul_hi;
    logic [31:0] m_addr, m_store_data, resp_value, load_shift, ld_aligned;
    logic [3:0] m_be;
    logic signed [32:0] m_mul_a, m_mul_b;
    logic signed [65:0] mul_product;
    logic [31:0] mul_value;
    logic m_fwd [0:1];
    logic [31:0] m_fval [0:1], m_value [0:1];
    always_comb begin
        for (int L = 0; L < 2; L++) begin
            m_fwd[L] = m_valid[L] && m_we[L] && !m_fault[L] && !m_mul[L] && !(L == 0 && m_csr) &&
                (!m_read[L] || (m_state == M_RESP && !resp_error));
            m_fval[L] = m_read[L] ? resp_value : m_result[L];
        end
    end

    // ==================================================================
    // EX datapath (per lane)
    // ==================================================================
    logic [31:0] fwd1 [0:1], fwd2 [0:1], alu_a [0:1], alu_b [0:1], alu_y [0:1], bm_y [0:1];
    logic [31:0] eff [0:1], tgt [0:1], rpc [0:1], st_data [0:1];
    logic [3:0] st_be [0:1];
    logic btaken [0:1], ataken [0:1], mispred [0:1], exf [0:1], exirq [0:1];
    logic csr_chk_illegal, irq_pending, irq_inj, csr_trap_en;
    logic [3:0] irq_code;
    logic [3:0] exc [0:1];
    logic [31:0] exa [0:1];

    function automatic logic [31:0] forward(input logic [4:0] r, input logic [31:0] v);
        forward = v;
        if (r != 0) begin
            if (m_fwd[1] && m_rd[1] == r) forward = m_fval[1];
            else if (m_fwd[0] && m_rd[0] == r) forward = m_fval[0];
            else if (w_valid[1] && w_we[1] && w_rd[1] == r) forward = w_data[1];
            else if (w_valid[0] && w_we[0] && w_rd[0] == r) forward = w_data[0];
        end
    endfunction

    for (genvar L = 0; L < 2; L++) begin : g_ex
        always_comb begin
            fwd1[L] = forward(e_rs1[L], e_value1[L]);
            fwd2[L] = forward(e_rs2[L], e_value2[L]);
            case (e_src_a[L])
                SRC_A_PC: alu_a[L] = e_pc[L];
                SRC_A_ZERO: alu_a[L] = 0;
                default: alu_a[L] = fwd1[L];
            endcase
            case (e_src_b[L])
                SRC_B_IMM: alu_b[L] = e_imm[L];
                SRC_B_FOUR: alu_b[L] = 4;
                default: alu_b[L] = fwd2[L];
            endcase
            case (e_branch[L])
                BR_EQ: btaken[L] = fwd1[L] == fwd2[L];
                BR_NE: btaken[L] = fwd1[L] != fwd2[L];
                BR_LT: btaken[L] = $signed(fwd1[L]) < $signed(fwd2[L]);
                BR_GE: btaken[L] = $signed(fwd1[L]) >= $signed(fwd2[L]);
                BR_LTU: btaken[L] = fwd1[L] < fwd2[L];
                BR_GEU: btaken[L] = fwd1[L] >= fwd2[L];
                default: btaken[L] = 0;
            endcase
            eff[L] = fwd1[L] + e_imm[L];
            tgt[L] = e_jalr[L] ? {eff[L][31:1], 1'b0} : e_br_target[L];
            ataken[L] = e_jal[L] || e_jalr[L] || btaken[L];
            if (e_pt[L])
                mispred[L] = !ataken[L] || tgt[L][31:16] != PRED_HI || tgt[L][15:2] != e_ptgt[L];
            else
                mispred[L] = ataken[L];
            rpc[L] = ataken[L] ? tgt[L] : e_pc4[L];

            st_data[L] = fwd2[L];
            st_be[L] = 4'b1111;
            case (e_size[L])
                MEM_BYTE: begin st_data[L] = {4{fwd2[L][7:0]}}; st_be[L] = 4'b0001 << eff[L][1:0]; end
                MEM_HALF: begin st_data[L] = {2{fwd2[L][15:0]}}; st_be[L] = 4'b0011 << eff[L][1:0]; end
                default: begin end
            endcase
            exf[L] = e_ffault[L] || e_illegal[L] || (L == 0 && e_csr[0] && csr_chk_illegal);
            exc[L] = e_ffault[L] ? 4'd1 : 4'd2;
            exa[L] = e_ffault[L] ? e_pc[L] : e_instr[L];
            if (!exf[L] && (e_ecall[L] || e_ebreak[L])) begin
                exf[L] = 1; exc[L] = e_ecall[L] ? 4'd11 : 4'd3; exa[L] = 0;
            end
            if (!exf[L] && ataken[L] && tgt[L][1:0] != 0) begin
                exf[L] = 1; exc[L] = 0; exa[L] = tgt[L];
            end
            if (!exf[L] && (e_read[L] || e_write[L])) begin
                exa[L] = eff[L];
                if ((e_size[L] == MEM_HALF && eff[L][0]) || (e_size[L] == MEM_WORD && eff[L][1:0] != 0)) begin
                    exf[L] = 1; exc[L] = e_write[L] ? 4'd6 : 4'd4;
                end else if (eff[L][31:28] == 4'h1 && e_size[L] != MEM_WORD) begin
                    exf[L] = 1; exc[L] = e_write[L] ? 4'd7 : 4'd5;
                end
            end
            // An enabled interrupt replaces the oldest EX instruction, which is
            // not executed and resumes after MRET (mepc = its pc).
            exirq[L] = L == 0 && irq_inj;
            if (exirq[L]) begin
                exf[L] = 1; exc[L] = irq_code; exa[L] = 0;
            end
        end
        rv32_alu alu (.op(e_alu[L]), .a(alu_a[L]), .b(alu_b[L]), .y(alu_y[L]));
        rv32_bitmanip bmu (.op(e_bm_op[L]), .a(fwd1[L]), .b(alu_b[L]), .y(bm_y[L]));
    end

    // Shared memory/multiply resources follow whichever lane uses them
    // (issue guarantees at most one memory op and one multiply per pair).
    logic e_ml, e_has_mem, e_tcm_ld, e_mul_l;
    assign e_ml = !(e_valid[0] && (e_read[0] || e_write[0]));
    assign e_has_mem = (e_valid[0] && (e_read[0] || e_write[0])) || (e_valid[1] && (e_read[1] || e_write[1]));
    assign e_tcm_ld = e_valid[e_ml] && e_read[e_ml] && !exf[e_ml] &&
        (eff[e_ml][31:16] == 16'h0 || eff[e_ml][31:15] == 17'h2);
    assign e_mul_l = !(e_valid[0] && e_mul[0]);

    // ---- divider (lane 0 only; DIV/REM always issue alone)
    logic div_busy, div_done, div_negq, div_negr, div_zero;
    logic [5:0] div_cnt;
    logic [31:0] div_q, div_r, div_d, div_result, div_a_save;
    logic [32:0] div_trial;
    assign div_trial = {div_r[31:0], div_q[31]} - {1'b0, div_d};
    always_comb begin
        if (div_zero) div_result = e_mdf3[0][1] ? div_a_save : 32'hffff_ffff;
        else if (e_mdf3[0][1]) div_result = div_negr ? -div_r : div_r;
        else div_result = div_negq ? -div_q : div_q;
    end

    // ==================================================================
    // CSR file and traps
    // ==================================================================
    logic trap_take, trap_mem, trap_wb, mret_take, csr_we;
    logic [31:0] trap_cause, trap_pc, trap_tval, trap_vector, csr_rdata, csr_wdata, mepc;
    logic [1:0] retire_count;
    wire e_csr_writes = e_instr[0][13:12] == 2'b01 || e_instr[0][19:15] != 0;
    // Interrupts wait while a CSR access or MRET is in MEM (it may change
    // MIE/mie this cycle) and never split a trap/redirect in progress.
    assign irq_inj = irq_pending && e_valid[0] && !(m_valid[0] && (m_csr || m_mret));
    rv32_csr #(.HAS_M(ENABLE_M), .HAS_B(ENABLE_B)) csrs (
        .clk(clk), .rst(rst),
        .chk_addr(e_instr[0][31:20]), .chk_write(e_csr_writes), .chk_illegal(csr_chk_illegal),
        .acc_addr(m_instr[0][31:20]), .acc_rdata(csr_rdata), .acc_we(csr_we), .acc_wdata(csr_wdata),
        .trap_take(trap_take), .trap_cause(trap_cause), .trap_pc(trap_pc), .trap_tval(trap_tval),
        .mret_take(mret_take), .trap_vector(trap_vector), .mepc_out(mepc), .trap_en(csr_trap_en),
        .irq_soft(irq_soft), .irq_timer(irq_timer), .irq_ext(irq_ext),
        .irq_pending(irq_pending), .irq_code(irq_code),
        .retire_count(retire_count), .mtime(mtime));
    always_comb begin
        // CSR instruction write data: m_result holds rs1 (or zimm) from EX.
        case (m_instr[0][13:12])
            2'b01: csr_wdata = m_result[0];
            2'b10: csr_wdata = csr_rdata | m_result[0];
            default: csr_wdata = csr_rdata & ~m_result[0];
        endcase
    end

    // ==================================================================
    // MEM completion, faults, redirects
    // ==================================================================
    logic m_any, m_has_mem, m_mem_ok, m_complete, m_release, m_ld_error, mem_ld_req;
    logic mf0, mf1;
    assign m_any = m_valid[0] || m_valid[1];
    assign m_has_mem = m_valid[m_lane] && (m_read[m_lane] || m_write[m_lane]);
    // The memory op may execute only if no older lane in the group faults.
    assign m_mem_ok = m_has_mem && !m_fault[m_lane] && !(m_lane && m_valid[0] && m_fault[0]);
    assign mem_ld_req = m_mem_ok && m_read[m_lane] && m_state == M_IDLE && !stop && !wb_fault;
    assign st_valid = m_mem_ok && m_write[m_lane] && m_state == M_IDLE && !stop && !wb_fault;
    assign st_addr = {m_addr[31:2], 2'b0};
    assign st_size = m_size;
    assign st_wdata = m_store_data;
    assign st_wstrb = m_be;
    assign m_ld_error = m_state == M_RESP ? resp_error : ld_error;
    assign load_shift = ld_rdata >> {m_addr[1:0], 3'b0};
    always_comb begin
        case (m_size)
            MEM_BYTE: ld_aligned = m_unsigned ? {24'b0, load_shift[7:0]} : {{24{load_shift[7]}}, load_shift[7:0]};
            MEM_HALF: ld_aligned = m_unsigned ? {16'b0, load_shift[15:0]} : {{16{load_shift[15]}}, load_shift[15:0]};
            default: ld_aligned = ld_rdata;
        endcase
    end
    assign mul_product = m_mul_a * m_mul_b;
    assign mul_value = m_mul_hi ? mul_product[63:32] : mul_product[31:0];
    always_comb begin
        for (int L = 0; L < 2; L++) begin
            m_value[L] = m_result[L];
            if (m_read[L]) m_value[L] = m_state == M_RESP ? resp_value : ld_aligned;
            if (ENABLE_M && m_mul[L]) m_value[L] = mul_value;
            if (L == 0 && m_csr) m_value[L] = csr_rdata;
        end
        if (!m_mem_ok) m_complete = 1;
        else if (m_write[m_lane]) m_complete = st_valid && st_ready;
        else m_complete = m_state == M_RESP || (m_state == M_WAIT && ld_rvalid && m_ex_issued);
    end
    assign m_release = m_any && m_complete && !stop && !wb_fault;
    assign mf0 = m_valid[0] && (m_fault[0] || (m_mem_ok && !m_lane && m_read[0] && m_ld_error));
    assign mf1 = !mf0 && m_valid[1] && (m_fault[1] || (m_mem_ok && m_lane && m_read[1] && m_ld_error));
    assign fault_commit = m_release && (mf0 || mf1);
    assign mem_redirect = m_release && m_valid[0] && (m_fence_i[0] || m_mret) && !fault_commit;
    assign mret_take = m_release && m_valid[0] && m_mret && !fault_commit;
    assign csr_we = m_release && m_valid[0] && m_csr && !mf0 &&
        (m_instr[0][13:12] == 2'b01 || m_instr[0][19:15] != 0);

    assign wbf0 = w_valid[0] && w_write[0] && st_done && st_error;
    assign wbf1 = w_valid[1] && w_write[1] && st_done && st_error;
    assign wb_fault = wbf0 || wbf1;
    assign kill_all = fault_commit || wb_fault;
    assign trap_wb = wb_fault && csr_trap_en;
    assign trap_mem = fault_commit && csr_trap_en && !wb_fault;
    assign trap_take = trap_wb || trap_mem;
    always_comb begin
        if (wb_fault) begin
            trap_cause = 32'd7;
            trap_pc = wbf0 ? w_pc[0] : w_pc[1];
            trap_tval = wbf0 ? w_addr[0] : w_addr[1];
        end else if (mf0) begin
            trap_cause = {m_irq[0], 27'b0, m_fault[0] ? m_cause[0] : 4'd5};
            trap_pc = m_pc[0];
            trap_tval = m_fault[0] ? m_fault_addr[0] : m_addr;
        end else begin
            trap_cause = {m_irq[1], 27'b0, m_fault[1] ? m_cause[1] : 4'd5};
            trap_pc = m_pc[1];
            trap_tval = m_fault[1] ? m_fault_addr[1] : m_addr;
        end
    end
    assign retire_count = {1'b0, retire_valid} + {1'b0, retire1_valid};

    assign e_can_go = (e_valid[0] || e_valid[1]) && !stop && !wb_fault && (!m_any || m_release) &&
        !fault_commit && !mem_redirect;
    assign e_fire = e_can_go && (!(ENABLE_M && e_valid[0] && e_div[0]) || div_done);

    logic exr0, exr1;
    assign exr0 = e_fire && e_valid[0] && !exf[0] && mispred[0];
    assign exr1 = e_fire && e_valid[1] && !exf[0] && !exf[1] && !exr0 && mispred[1];
    assign ex_redirect = exr0 || exr1;
    assign ex_redirect_pc = exr0 ? rpc[0] : rpc[1];
    assign redirect = kill_all || mem_redirect || ex_redirect;
    assign redirect_pc = trap_take ? trap_vector : mret_take ? mepc :
                         mem_redirect ? m_pc[0] + 4 : ex_redirect_pc;

    // EX load issue: only TCM index bits leave the core from EX, so B's MMIO
    // decode never sees the EX adder; non-TCM loads are reissued from MEM.
    assign ld_valid = mem_ld_req || (e_can_go && e_valid[e_ml] && e_read[e_ml]);
    assign ld_addr = mem_ld_req ? {m_addr[31:2], 2'b0} : {15'b0, eff[e_ml][16:2], 2'b0};
    assign ld_size = mem_ld_req ? m_size : e_size[e_ml];
    assign ld_maddr = {m_addr[31:2], 2'b0};

    // ==================================================================
    // Predictor update (one registered write per cycle; lane 0 first)
    // ==================================================================
    logic upd [0:1], inval [0:1], ectrl [0:1], lane_live [0:1];
    logic [1:0] uctr [0:1];
    always_comb begin
        lane_live[0] = e_fire && e_valid[0] && !exf[0];
        lane_live[1] = e_fire && e_valid[1] && !exf[0] && !exf[1] && !exr0;
        for (int L = 0; L < 2; L++) begin
            ectrl[L] = e_branch[L] != BR_NONE || e_jal[L] || e_jalr[L];
            upd[L] = 0; inval[L] = 0; uctr[L] = 2'b10;
            if (BP_ENABLE && lane_live[L] && e_pc[L][31:16] == PRED_HI) begin
                if (ectrl[L] && ataken[L] && tgt[L][31:16] == PRED_HI) begin
                    upd[L] = 1;
                    uctr[L] = !e_hit[L] ? 2'b10 : (e_ctr[L] == 2'b11 ? 2'b11 : e_ctr[L] + 2'b01);
                end else if (ectrl[L] && !ataken[L] && e_hit[L]) begin
                    upd[L] = 1;
                    uctr[L] = e_ctr[L] == 2'b00 ? 2'b00 : e_ctr[L] - 2'b01;
                end else if (e_hit[L] && !ectrl[L]) inval[L] = 1;
            end
        end
    end
    logic bsel;
    assign bsel = !(upd[0] || inval[0]);
    logic bw_en, bw_inval;
    logic [BTB_BITS-1:0] bw_idx;
    logic [TAG_W-1:0] bw_tag;
    logic [13:0] bw_tgt;
    logic [1:0] bw_type, bw_ctr;
    always_ff @(posedge clk) begin
        bw_en <= (upd[0] || upd[1] && bsel) && !rst;
        bw_inval <= (inval[0] || inval[1] && bsel) && !rst;
        bw_idx <= e_pc[bsel][BTB_BITS+1:2];
        bw_tag <= e_pc[bsel][15:BTB_BITS+2];
        bw_tgt <= ataken[bsel] ? tgt[bsel][15:2] : e_ptgt[bsel];
        bw_type <= e_type[bsel];
        bw_ctr <= uctr[bsel];
        if (bw_en) begin
            btb_tag0[bw_idx] <= bw_tag;  btb_tag1[bw_idx] <= bw_tag;
            btb_tgt0[bw_idx] <= bw_tgt;  btb_tgt1[bw_idx] <= bw_tgt;
            btb_type0[bw_idx] <= bw_type; btb_type1[bw_idx] <= bw_type;
            btb_ctr0[bw_idx] <= bw_ctr;  btb_ctr1[bw_idx] <= bw_ctr;
        end
    end

    // Committed RAS: executed calls/returns in program order (lane 0, lane 1).
    logic [13:0] ras_c_n [0:3];
    logic [1:0] ras_cp_n;
    always_comb begin
        for (int i = 0; i < 4; i++) ras_c_n[i] = ras_c[i];
        ras_cp_n = ras_cp;
        for (int L = 0; L < 2; L++) begin
            if (lane_live[L]) begin
                if (e_type[L] == T_CALL && (e_jal[L] || e_jalr[L])) begin
                    ras_cp_n = ras_cp_n + 2'd1;
                    ras_c_n[ras_cp_n] = e_pc4[L][15:2];
                end else if (e_type[L] == T_RET && e_jalr[L]) begin
                    ras_cp_n = ras_cp_n - 2'd1;
                end
            end
        end
    end

    // ==================================================================
    // Sequential: fetch, queue, predictor state
    // ==================================================================
    logic [1:0] n_pop, n_in;
    assign n_pop = d_fire1 ? 2'd2 : (d_fire0 ? 2'd1 : 2'd0);
    assign n_in = in_v1 ? 2'd2 : (in_v0 ? 2'd1 : 2'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            pc_f <= RESET_PC;
            f2_valid <= 0;
            q_count <= 0;
            btb_v <= 0;
            ras_sp <= 0;
            ras_cp <= 0;
            for (int i = 0; i < 4; i++) begin ras_s[i] <= 0; ras_c[i] <= 0; end
        end else begin
            if (bw_en) btb_v[bw_idx] <= 1;
            if (bw_inval) btb_v[bw_idx] <= 0;
            for (int i = 0; i < 4; i++) ras_c[i] <= ras_c_n[i];
            ras_cp <= ras_cp_n;

            if (f_accept) begin
                f2_valid <= 1;
                f2_pc <= pc_f;
                f2_v1 <= f_v1;
                f2_pt0 <= fpt0; f2_g0 <= fg0; f2_h0 <= fh0; f2_c0 <= fc0;
                f2_pt1 <= f_v1 && fpt1; f2_g1 <= fg1; f2_h1 <= fh1; f2_c1 <= fc1;
                if (fpt0) begin
                    pc_f <= {PRED_HI, fg0, 2'b00};
                    if (ft0 == T_CALL) begin
                        ras_sp <= ras_sp + 2'd1;
                        ras_s[ras_sp + 2'd1] <= pc_f4[15:2];
                    end else if (ft0 == T_RET) ras_sp <= ras_sp - 2'd1;
                end else if (f_v1 && fpt1) begin
                    pc_f <= {PRED_HI, fg1, 2'b00};
                    if (ft1 == T_CALL) begin
                        ras_sp <= ras_sp + 2'd1;
                        ras_s[ras_sp + 2'd1] <= pc_f4[15:2] + 14'd1;
                    end else if (ft1 == T_RET) ras_sp <= ras_sp - 2'd1;
                end else pc_f <= f_v1 ? pc_f + 8 : pc_f4;
            end else f2_valid <= 0;

            // Queue: remaining stream after popping n_pop = (queue ++ incoming)[n_pop:]
            for (int i = 0; i < QD; i++) begin
                int j;
                j = i + n_pop;
                if (j < q_count) begin
                    q_pc[i] <= q_pc[j]; q_in[i] <= q_in[j]; q_err[i] <= q_err[j]; q_pt[i] <= q_pt[j];
                    q_ptgt[i] <= q_ptgt[j]; q_hit[i] <= q_hit[j]; q_ctr[i] <= q_ctr[j];
                end else if (j == q_count) begin
                    q_pc[i] <= f2_pc; q_in[i] <= if_rdata; q_err[i] <= if_error; q_pt[i] <= f2_pt0;
                    q_ptgt[i] <= f2_g0; q_hit[i] <= f2_h0; q_ctr[i] <= f2_c0;
                end else begin
                    q_pc[i] <= f2_pc + 4; q_in[i] <= if_rdata1; q_err[i] <= if_error1; q_pt[i] <= f2_pt1;
                    q_ptgt[i] <= f2_g1; q_hit[i] <= f2_h1; q_ctr[i] <= f2_c1;
                end
            end
            q_count <= q_count + n_in - n_pop;

            if (redirect) begin
                f2_valid <= 0;
                q_count <= 0;
                if (!kill_all || trap_take) pc_f <= redirect_pc;
                for (int i = 0; i < 4; i++) ras_s[i] <= ras_c_n[i];
                ras_sp <= ras_cp_n;
            end
        end
    end

    // ==================================================================
    // Sequential: pipeline
    // ==================================================================
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int L = 0; L < 2; L++) begin
                e_valid[L] <= 0; m_valid[L] <= 0; w_valid[L] <= 0;
            end
            for (int L = 0; L < 2; L++) begin
                m_read[L] <= 0; m_write[L] <= 0; m_fault[L] <= 0; m_mul[L] <= 0;
            end
            m_lane <= 0;
            m_csr <= 0;
            m_mret <= 0;
            m_irq[0] <= 0;
            m_irq[1] <= 0;
            m_state <= M_IDLE;
            m_ex_issued <= 0;
            resp_error <= 0;
            resp_value <= 0;
            div_busy <= 0;
            div_done <= 0;
            fault_valid <= 0;
            fault_cause <= 0;
            fault_pc <= 0;
            fault_instr <= 0;
            fault_addr <= 0;
        end else begin
            // ---- WB
            w_valid[0] <= m_release && m_valid[0] && !mf0;
            w_valid[1] <= m_release && m_valid[1] && !mf0 && !mf1;
            if (m_release) begin
                for (int L = 0; L < 2; L++) begin
                    w_pc[L] <= m_pc[L];
                    w_instr[L] <= m_instr[L];
                    w_rd[L] <= m_rd[L];
                    w_we[L] <= m_we[L];
                    w_data[L] <= m_value[L];
                    w_mem[L] <= m_read[L] || m_write[L];
                    w_write[L] <= m_write[L];
                    w_addr[L] <= m_addr;
                    w_store[L] <= m_store_data;
                    w_be[L] <= m_be;
                end
            end

            // ---- shared memory unit
            if (m_mem_ok && m_read[m_lane]) begin
                if (m_state == M_IDLE && mem_ld_req && ld_ready) begin
                    m_state <= M_WAIT;
                    m_ex_issued <= 0;
                end else if (m_state == M_WAIT && ld_rvalid) begin
                    resp_value <= ld_aligned;
                    resp_error <= ld_error;
                    m_state <= M_RESP;
                end
            end
            if (st_valid && st_ready) m_state <= M_WAIT;

            if (m_release) begin m_valid[0] <= 0; m_valid[1] <= 0; end
            if (e_fire) begin
                m_valid[0] <= e_valid[0];
                m_valid[1] <= e_valid[1] && !exr0;
                for (int L = 0; L < 2; L++) begin
                    m_pc[L] <= e_pc[L];
                    m_instr[L] <= e_instr[L];
                    m_rd[L] <= e_rd[L];
                    m_we[L] <= e_we[L];
                    m_read[L] <= e_read[L];
                    m_write[L] <= e_write[L];
                    m_fence_i[L] <= e_fence_i[L];
                    m_mul[L] <= ENABLE_M && e_mul[L];
                    m_irq[L] <= exirq[L];
                    m_result[L] <= (ENABLE_M && L == 0 && e_div[0]) ? div_result :
                                   (ENABLE_B && e_bm[L]) ? bm_y[L] : alu_y[L];
                    m_fault[L] <= exf[L];
                    m_cause[L] <= exc[L];
                    m_fault_addr[L] <= exa[L];
                end
                m_csr <= e_csr[0] && !exf[0];
                m_mret <= e_mret[0] && !exf[0];
                // CSR source operand (rs1 value or zero-extended uimm) rides in m_result.
                if (e_csr[0]) m_result[0] <= e_instr[0][14] ? {27'b0, e_instr[0][19:15]} : fwd1[0];
                m_lane <= e_ml;
                m_addr <= eff[e_ml];
                m_size <= e_size[e_ml];
                m_unsigned <= e_uns[e_ml];
                m_store_data <= st_data[e_ml];
                m_be <= st_be[e_ml];
                m_state <= e_tcm_ld && ld_ready ? M_WAIT : M_IDLE;
                m_ex_issued <= e_tcm_ld && ld_ready;
                resp_error <= 0;
                m_mul_hi <= e_mdf3[e_mul_l][1:0] != 2'd0;
                m_mul_a <= {e_mdf3[e_mul_l][1:0] != 2'd3 && e_mdf3[e_mul_l][1:0] != 2'd0 && fwd1[e_mul_l][31], fwd1[e_mul_l]};
                m_mul_b <= {e_mdf3[e_mul_l][1:0] == 2'd1 && fwd2[e_mul_l][31], fwd2[e_mul_l]};
            end

            // ---- EX
            if ((e_valid[0] || e_valid[1]) && !e_fire) begin
                for (int L = 0; L < 2; L++) begin
                    e_value1[L] <= fwd1[L];
                    e_value2[L] <= fwd2[L];
                end
            end
            if (e_fire) begin e_valid[0] <= 0; e_valid[1] <= 0; end
            if (d_fire0) begin
                e_valid[0] <= 1;
                e_valid[1] <= d_fire1;
                for (int k = 0; k < 2; k++) begin
                    e_pc[k] <= s_pc[k];
                    e_pc4[k] <= s_pc[k] + 4;
                    e_br_target[k] <= s_pc[k] + d_imm[k];
                    e_instr[k] <= s_in[k];
                    e_rs1[k] <= d_use1[k] ? s_in[k][19:15] : 5'd0;
                    e_rs2[k] <= d_use2[k] ? s_in[k][24:20] : 5'd0;
                    e_rd[k] <= d_we[k] ? s_in[k][11:7] : 5'd0;
                    e_value1[k] <= rf_rd[2 * k];
                    e_value2[k] <= rf_rd[2 * k + 1];
                    e_imm[k] <= d_imm[k];
                    e_alu[k] <= d_alu[k];
                    e_src_a[k] <= d_src_a[k];
                    e_src_b[k] <= d_src_b[k];
                    e_branch[k] <= d_branch[k];
                    e_size[k] <= d_size[k];
                    e_we[k] <= d_we[k];
                    e_read[k] <= d_read[k];
                    e_write[k] <= d_write[k];
                    e_uns[k] <= d_uns[k];
                    e_jal[k] <= d_jal[k];
                    e_jalr[k] <= d_jalr[k];
                    e_fence_i[k] <= d_fence_i[k];
                    e_illegal[k] <= d_illegal[k];
                    e_ffault[k] <= s_err[k];
                    e_type[k] <= d_type[k];
                    e_pt[k] <= s_pt[k];
                    e_ptgt[k] <= s_ptgt[k];
                    e_hit[k] <= s_hit[k];
                    e_ctr[k] <= s_ctr[k];
                    e_mul[k] <= d_mul[k];
                    e_div[k] <= d_div[k];
                    e_mdf3[k] <= d_mdf3[k];
                    e_bm[k] <= d_bm[k];
                    e_bm_op[k] <= d_bm_op[k];
                    e_csr[k] <= d_csr[k];
                    e_ecall[k] <= d_ecall[k];
                    e_ebreak[k] <= d_ebreak[k];
                    e_mret[k] <= d_mret[k];
                end
            end
            if (kill_all || mem_redirect || fault_valid) begin e_valid[0] <= 0; e_valid[1] <= 0; end

            // ---- divider sequencing (lane 0)
            if (!ENABLE_M || e_fire || kill_all || mem_redirect || !e_valid[0]) begin
                div_busy <= 0;
                div_done <= 0;
            end else if (e_div[0] && !div_busy && !div_done) begin
                div_busy <= 1;
                div_cnt <= 0;
                div_zero <= fwd2[0] == 0;
                div_a_save <= fwd1[0];
                div_negq <= !e_mdf3[0][0] && (fwd1[0][31] ^ fwd2[0][31]);
                div_negr <= !e_mdf3[0][0] && fwd1[0][31];
                div_q <= !e_mdf3[0][0] && fwd1[0][31] ? -fwd1[0] : fwd1[0];
                div_d <= !e_mdf3[0][0] && fwd2[0][31] ? -fwd2[0] : fwd2[0];
                div_r <= 0;
            end else if (div_busy) begin
                if (!div_trial[32]) begin
                    div_r <= div_trial[31:0];
                    div_q <= {div_q[30:0], 1'b1};
                end else begin
                    div_r <= {div_r[30:0], div_q[31]};
                    div_q <= {div_q[30:0], 1'b0};
                end
                div_cnt <= div_cnt + 1;
                if (div_cnt == 31) begin div_busy <= 0; div_done <= 1; end
            end

            // ---- faults (oldest first)
            if (trap_take) begin
                m_valid[0] <= 0; m_valid[1] <= 0;
            end else if (wb_fault) begin
                fault_valid <= 1;
                fault_pc <= wbf0 ? w_pc[0] : w_pc[1];
                fault_instr <= wbf0 ? w_instr[0] : w_instr[1];
                fault_cause <= 4'd7;
                fault_addr <= wbf0 ? w_addr[0] : w_addr[1];
                m_valid[0] <= 0; m_valid[1] <= 0;
            end else if (fault_commit) begin
                fault_valid <= 1;
                fault_pc <= mf0 ? m_pc[0] : m_pc[1];
                fault_instr <= mf0 ? m_instr[0] : m_instr[1];
                fault_cause <= mf0 ? (m_fault[0] ? m_cause[0] : 4'd5) : (m_fault[1] ? m_cause[1] : 4'd5);
                fault_addr <= mf0 ? (m_fault[0] ? m_fault_addr[0] : m_addr) : (m_fault[1] ? m_fault_addr[1] : m_addr);
                m_valid[0] <= 0; m_valid[1] <= 0;
            end
        end
    end

    // ==================================================================
    // Retire / debug
    // ==================================================================
    assign retire_valid = w_valid[0] && !wbf0;
    assign retire_pc = w_pc[0];
    assign retire_instr = w_instr[0];
    assign retire_rd_we = retire_valid && w_we[0] && w_rd[0] != 0;
    assign retire_rd = w_rd[0];
    assign retire_rd_data = w_data[0];
    assign retire_mem_valid = retire_valid && w_mem[0];
    assign retire_mem_we = w_write[0];
    assign retire_mem_addr = w_addr[0];
    assign retire_mem_wdata = w_store[0];
    assign retire_mem_be = w_be[0];
    assign retire1_valid = w_valid[1] && !wbf0 && !wbf1;
    assign retire1_pc = w_pc[1];
    assign retire1_instr = w_instr[1];
    assign retire1_rd_we = retire1_valid && w_we[1] && w_rd[1] != 0;
    assign retire1_rd = w_rd[1];
    assign retire1_rd_data = w_data[1];
    assign retire1_mem_valid = retire1_valid && w_mem[1];
    assign retire1_mem_we = w_write[1];
    assign retire1_mem_addr = w_addr[1];
    assign retire1_mem_wdata = w_store[1];
    assign retire1_mem_be = w_be[1];
    assign debug_valid = {w_valid[0] || w_valid[1], m_any, e_valid[0] || e_valid[1], s_v[0], f2_valid};

`ifdef RV32_SIM_CHECKS
    always_ff @(posedge clk) if (!rst) begin
        if (f2_valid && !if_rvalid) $error("rv32_core_d: IF response missing one cycle after accept");
        if (q_count + n_in - n_pop > QD && !redirect) $error("rv32_core_d: fetch queue overflow");
    end
`endif
endmodule
