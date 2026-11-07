// Zba/Zbb/Zbs/Zicond execution unit (RV32). a = rs1, b = rs2 or I-immediate.
module rv32_bitmanip (
    input  logic [4:0] op,
    input  logic [31:0] a, b,
    output logic [31:0] y
);
    import rv32_pkg::*;
    logic [4:0] sh;
    logic [31:0] bit_mask, rev;
    logic [5:0] lz, tz, pc;
    assign sh = b[4:0];
    assign bit_mask = 32'd1 << sh;
    always_comb begin
        for (int i = 0; i < 32; i++) rev[i] = a[31 - i];
        lz = 6'd32;
        for (int i = 0; i < 32; i++) if (a[i]) lz = 6'(31 - i);
        tz = 6'd32;
        for (int i = 31; i >= 0; i--) if (a[i]) tz = 6'(i);
        pc = 0;
        for (int i = 0; i < 32; i++) pc = pc + 6'(a[i]);
        case (op)
            BM_ANDN:  y = a & ~b;
            BM_ORN:   y = a | ~b;
            BM_XNOR:  y = ~(a ^ b);
            BM_MAX:   y = $signed(a) > $signed(b) ? a : b;
            BM_MAXU:  y = a > b ? a : b;
            BM_MIN:   y = $signed(a) < $signed(b) ? a : b;
            BM_MINU:  y = a < b ? a : b;
            BM_ROL:   y = (a << sh) | (a >> (6'd32 - {1'b0, sh}));
            BM_ROR:   y = (a >> sh) | (a << (6'd32 - {1'b0, sh}));
            BM_SH1ADD: y = (a << 1) + b;
            BM_SH2ADD: y = (a << 2) + b;
            BM_SH3ADD: y = (a << 3) + b;
            BM_ZEXTH: y = {16'b0, a[15:0]};
            BM_BCLR:  y = a & ~bit_mask;
            BM_BEXT:  y = {31'b0, a[sh]};
            BM_BINV:  y = a ^ bit_mask;
            BM_BSET:  y = a | bit_mask;
            BM_CLZ:   y = {26'b0, lz};
            BM_CTZ:   y = {26'b0, tz};
            BM_CPOP:  y = {26'b0, pc};
            BM_SEXTB: y = {{24{a[7]}}, a[7:0]};
            BM_SEXTH: y = {{16{a[15]}}, a[15:0]};
            BM_ORCB:  y = {{8{|a[31:24]}}, {8{|a[23:16]}}, {8{|a[15:8]}}, {8{|a[7:0]}}};
            BM_REV8:  y = {a[7:0], a[15:8], a[23:16], a[31:24]};
            BM_CZEQZ: y = b == 0 ? 32'b0 : a;
            BM_CZNEZ: y = b != 0 ? 32'b0 : a;
            default:  y = 32'b0;
        endcase
    end
endmodule
