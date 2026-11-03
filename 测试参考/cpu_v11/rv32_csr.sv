// Machine-mode CSR file (M-mode only, no U/S): Zicsr access, trap entry,
// MRET, interrupt pending/priority, and the Zicntr/machine counters.
// mstatus.MPP is hard-wired to M; mepc is 4-byte aligned (IALIGN=32).
module rv32_csr #(
    parameter bit HAS_M = 1,
    parameter bit HAS_B = 1
) (
    input  logic clk,
    input  logic rst,
    // legality check (EX): address and whether the instruction writes
    input  logic [11:0] chk_addr,
    input  logic chk_write,
    output logic chk_illegal,
    // access (MEM commit of a CSR instruction)
    input  logic [11:0] acc_addr,
    output logic [31:0] acc_rdata,
    input  logic acc_we,
    input  logic [31:0] acc_wdata,
    // trap entry / return
    input  logic trap_take,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_pc,
    input  logic [31:0] trap_tval,
    input  logic mret_take,
    output logic [31:0] trap_vector,    // mtvec target for trap_cause
    output logic [31:0] mepc_out,
    output logic trap_en,               // mtvec programmed: traps vector, else halt
    // interrupts (level, from the SoC)
    input  logic irq_soft, irq_timer, irq_ext,
    output logic irq_pending,
    output logic [3:0] irq_code,
    // counters
    input  logic [1:0] retire_count,
    input  logic [63:0] mtime
);
    logic mie_bit, mpie;
    logic msie, mtie, meie;
    logic [31:0] mtvec, mscratch, mepc, mcause, mtval;
    logic [63:0] mcycle, minstret, minstret_now;
    logic instret_sup;   // the CSR write to minstret(h) retires next cycle uncounted
    wire [31:0] misa = {2'b01, 4'b0, 13'b0, HAS_M, 3'b0, 1'b1, 6'b0, HAS_B, 1'b0};
    wire [31:0] mstatus = {19'b0, 2'b11, 3'b0, mpie, 3'b0, mie_bit, 3'b0};
    wire [31:0] mip = {20'b0, irq_ext, 3'b0, irq_timer, 3'b0, irq_soft, 3'b0};
    wire [31:0] mie_r = {20'b0, meie, 3'b0, mtie, 3'b0, msie, 3'b0};
    // Reads include instructions retiring this cycle (they are older than the
    // reader in MEM).
    assign minstret_now = minstret + retire_count - instret_sup;

    function automatic logic known(input logic [11:0] a);
        case (a)
            12'h300, 12'h301, 12'h304, 12'h305, 12'h320, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
            12'hB00, 12'hB02, 12'hB80, 12'hB82, 12'hC00, 12'hC01, 12'hC02, 12'hC80, 12'hC81, 12'hC82,
            12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hF15,
            12'h7A0, 12'h7A1, 12'h7A2, 12'h7A3: known = 1;     // no debug triggers: tselect/tdata* read 0
            default: known = (a >= 12'h3A0 && a <= 12'h3EF);   // no PMP entries: pmpcfg*/pmpaddr* read 0
        endcase
    endfunction
    // CSR space [11:10]==2'b11 is read-only.
    assign chk_illegal = !known(chk_addr) || (chk_write && chk_addr[11:10] == 2'b11);

    always_comb begin
        case (acc_addr)
            12'h300: acc_rdata = mstatus;
            12'h301: acc_rdata = misa;
            12'h304: acc_rdata = mie_r;
            12'h305: acc_rdata = mtvec;
            12'h340: acc_rdata = mscratch;
            12'h341: acc_rdata = mepc;
            12'h342: acc_rdata = mcause;
            12'h343: acc_rdata = mtval;
            12'h344: acc_rdata = mip;
            12'hB00, 12'hC00: acc_rdata = mcycle[31:0];
            12'hB02, 12'hC02: acc_rdata = minstret_now[31:0];
            12'hB80, 12'hC80: acc_rdata = mcycle[63:32];
            12'hB82, 12'hC82: acc_rdata = minstret_now[63:32];
            12'hC01: acc_rdata = mtime[31:0];
            12'hC81: acc_rdata = mtime[63:32];
            default: acc_rdata = 32'b0;    // mcountinhibit, mvendorid, marchid, mimpid, mhartid, mconfigptr
        endcase
    end

    // Interrupt priority: external > software > timer.
    wire [31:0] pend = mip & mie_r;
    assign irq_pending = mie_bit && pend != 0;
    assign irq_code = pend[11] ? 4'd11 : pend[3] ? 4'd3 : 4'd7;
    assign trap_en = mtvec[31:2] != 0;
    assign trap_vector = (mtvec[0] && trap_cause[31]) ? {mtvec[31:2], 2'b00} + {trap_cause[29:0], 2'b00}
                                                      : {mtvec[31:2], 2'b00};
    assign mepc_out = mepc;

    always_ff @(posedge clk) begin
        if (rst) begin
            mie_bit <= 0;
            mpie <= 0;
            msie <= 0;
            mtie <= 0;
            meie <= 0;
            mtvec <= 0;
            mscratch <= 0;
            mepc <= 0;
            mcause <= 0;
            mtval <= 0;
            mcycle <= 0;
            minstret <= 0;
            instret_sup <= 0;
        end else begin
            mcycle <= mcycle + 1;
            minstret <= minstret_now;
            instret_sup <= 0;
            if (acc_we) begin
                case (acc_addr)
                    12'h300: begin mie_bit <= acc_wdata[3]; mpie <= acc_wdata[7]; end
                    12'h304: begin msie <= acc_wdata[3]; mtie <= acc_wdata[7]; meie <= acc_wdata[11]; end
                    12'h305: mtvec <= {acc_wdata[31:2], 1'b0, acc_wdata[0]};
                    12'h340: mscratch <= acc_wdata;
                    12'h341: mepc <= {acc_wdata[31:2], 2'b00};
                    12'h342: mcause <= acc_wdata;
                    12'h343: mtval <= acc_wdata;
                    12'hB00: mcycle[31:0] <= acc_wdata;
                    12'hB80: mcycle[63:32] <= acc_wdata;
                    12'hB02: begin minstret <= {minstret_now[63:32], acc_wdata}; instret_sup <= 1; end
                    12'hB82: begin minstret <= {acc_wdata, minstret_now[31:0]}; instret_sup <= 1; end
                    default: begin end
                endcase
            end
            if (trap_take) begin
                mepc <= {trap_pc[31:2], 2'b00};
                mcause <= trap_cause;
                mtval <= trap_tval;
                mpie <= mie_bit;
                mie_bit <= 0;
            end else if (mret_take) begin
                mie_bit <= mpie;
                mpie <= 1;
            end
        end
    end
endmodule
