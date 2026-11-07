// 2-way set-associative instruction cache for the DDR region (read-only).
// 64 sets x 2 ways x 64-byte lines = 8 KiB. LRU replacement (1 bit per set).
// Fetch contract (same as the TCM): a request is accepted (ready) only on a
// hit, and both words (addr, addr+4) are returned the next cycle. The core
// never asks for a pair that crosses a 32-byte row (addr[4:2] == 7 -> slot 1
// is not used). Misses fetch the whole line through the DDR bridge.
module icache #(
    parameter int IDX_W = 6
) (
    input  logic clk,
    input  logic rst_n,
    input  logic req_valid,
    input  logic [28:0] req_addr,      // byte offset in the DDR region
    output logic req_ready,
    output logic rvalid,
    output logic [31:0] rdata0,
    output logic [31:0] rdata1,
    input  logic invalidate,            // drop all lines (after software writes code)
    // line fill (shared bridge)
    output logic fill_req,
    output logic [28:0] fill_addr,      // line-aligned byte offset
    input  logic fill_done,
    input  logic [511:0] fill_data,
    // statistics
    output logic ev_hit,
    output logic ev_miss
);
    localparam int SETS = 1 << IDX_W;
    localparam int TAG_W = 29 - 6 - IDX_W;
    logic [TAG_W-1:0] tag0 [0:SETS-1], tag1 [0:SETS-1];
    logic [SETS-1:0] v0, v1, lru;          // lru[i]: way to replace next

    wire [IDX_W-1:0] idx = req_addr[6 +: IDX_W];
    wire [TAG_W-1:0] tag = req_addr[28 -: TAG_W];
    wire hit0 = v0[idx] && tag0[idx] == tag;
    wire hit1 = v1[idx] && tag1[idx] == tag;

    typedef enum logic [1:0] {S_IDLE, S_FILL, S_WR0, S_WR1} state_t;
    state_t st;
    logic [IDX_W-1:0] f_idx;
    logic [TAG_W-1:0] f_tag;
    logic f_way;
    logic [511:0] f_line;

    assign req_ready = req_valid && (hit0 || hit1) && st == S_IDLE && !invalidate;
    assign fill_req = st == S_FILL;
    assign fill_addr = {f_tag, f_idx, 6'b0};
    assign ev_hit = req_ready;
    assign ev_miss = req_valid && !(hit0 || hit1) && st == S_IDLE && !invalidate;

    // Data arrays: synchronous read of both ways at the request row.
    logic [255:0] q0, q1;
    logic sel_way;
    logic [2:0] sel_word;
    wire wr_fill = st == S_WR0 || st == S_WR1;
    wire [255:0] fill_row = st == S_WR1 ? f_line[511:256] : f_line[255:0];
    sdp_ram #(.DW(256), .AW(IDX_W + 1)) way0 (
        .clk(clk), .we(wr_fill && !f_way), .waddr({f_idx, st == S_WR1}), .wdata(fill_row),
        .re(req_ready), .raddr({idx, req_addr[5]}), .rdata(q0));
    sdp_ram #(.DW(256), .AW(IDX_W + 1)) way1 (
        .clk(clk), .we(wr_fill && f_way), .waddr({f_idx, st == S_WR1}), .wdata(fill_row),
        .re(req_ready), .raddr({idx, req_addr[5]}), .rdata(q1));
    // Tags (distributed RAM): written only on refill.
    always_ff @(posedge clk) if (st == S_WR1) begin
        if (f_way) tag1[f_idx] <= f_tag;
        else tag0[f_idx] <= f_tag;
    end
    wire [255:0] q = sel_way ? q1 : q0;
    assign rdata0 = q[sel_word * 32 +: 32];
    assign rdata1 = sel_word == 3'd7 ? 32'h0000_0013 : q[(sel_word + 3'd1) * 32 +: 32];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            v0 <= 0;
            v1 <= 0;
            lru <= 0;
            rvalid <= 0;
        end else begin
            rvalid <= req_ready;
            if (req_ready) begin
                sel_way <= hit1;
                sel_word <= req_addr[4:2];
                lru[idx] <= hit0;               // replace the other way next
            end
            case (st)
                S_IDLE: if (req_valid && !(hit0 || hit1) && !invalidate) begin
                    st <= S_FILL;
                    f_idx <= idx;
                    f_tag <= tag;
                    f_way <= !v0[idx] ? 1'b0 : !v1[idx] ? 1'b1 : lru[idx];
                end
                S_FILL: if (fill_done) begin
                    f_line <= fill_data;
                    st <= S_WR0;
                end
                S_WR0: st <= S_WR1;
                S_WR1: begin
                    if (f_way) v1[f_idx] <= 1;
                    else v0[f_idx] <= 1;
                    lru[f_idx] <= !f_way;
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
            // Invalidate takes effect in any state (software flushes the D-cache
            // and runs from the TCM while it updates code in DDR).
            if (invalidate) begin
                v0 <= 0;
                v1 <= 0;
            end
        end
    end
endmodule
