// 2-way set-associative write-back, write-allocate data cache for the DDR
// region. 64 sets x 2 ways x 64-byte lines = 8 KiB, LRU replacement.
// Core contract (same as the TCM/MMIO paths):
//   load : accepted (ld_ready) on a hit; aligned word returned next cycle
//   store: accepted (st_ready) on a hit; byte-enable write, st_done next cycle
// A miss evicts the LRU/invalid way (64-byte burst write-back if dirty) and
// refills the line (64-byte burst read), then the held request hits.
// flush: write back every dirty line and invalidate (software coherence,
// e.g. before executing code it wrote, or before handing data to DMA).
module dcache #(
    parameter int IDX_W = 6
) (
    input  logic clk,
    input  logic rst_n,
    input  logic ld_valid,
    input  logic [28:0] ld_addr,
    output logic ld_ready,
    output logic ld_rvalid,
    output logic [31:0] ld_rdata,
    input  logic st_valid,
    input  logic [28:0] st_addr,
    input  logic [31:0] st_wdata,
    input  logic [3:0] st_wstrb,
    output logic st_ready,
    output logic st_done,
    input  logic flush,                 // pulse
    output logic flush_busy,
    // line transfers (shared bridge)
    output logic mem_req,
    output logic mem_we,
    output logic [28:0] mem_addr,        // line-aligned byte offset
    output logic [511:0] mem_wdata,
    input  logic mem_done,
    input  logic [511:0] mem_rdata,
    // statistics
    output logic ev_hit,
    output logic ev_miss,
    output logic ev_writeback
);
    localparam int SETS = 1 << IDX_W;
    localparam int TAG_W = 29 - 6 - IDX_W;
    logic [TAG_W-1:0] tag0 [0:SETS-1], tag1 [0:SETS-1];
    logic [SETS-1:0] v0, v1, d0, d1, lru;
    // Data: per way, 32 byte columns of 2*SETS entries (row = {set, addr[5]}),
    // each an sdp_ram (one write port, one read port).

    typedef enum logic [2:0] {S_IDLE, S_RD0, S_RD1, S_WB, S_FILL, S_WR0, S_WR1, S_FLUSH} state_t;
    state_t st;
    logic f_flushing;
    logic rd_half;   // victim row 1 is in rd_row this cycle (first S_WB cycle)

    // ---- lookup (load has priority only when no store is waiting)
    wire use_st = st_valid;
    wire [28:0] a = use_st ? st_addr : ld_addr;
    wire [IDX_W-1:0] idx = a[6 +: IDX_W];
    wire [TAG_W-1:0] tag = a[28 -: TAG_W];
    wire hit0 = v0[idx] && tag0[idx] == tag;
    wire hit1 = v1[idx] && tag1[idx] == tag;
    wire hit = hit0 || hit1;
    wire idle = st == S_IDLE && !flush;
    assign st_ready = st_valid && hit && idle;
    assign ld_ready = ld_valid && !st_valid && hit && idle;
    assign ev_hit = st_ready || ld_ready;
    assign ev_miss = (st_valid || ld_valid) && !hit && idle;
    assign flush_busy = st == S_FLUSH || (st != S_IDLE && f_flushing);

    // ---- miss / flush bookkeeping
    logic [IDX_W-1:0] f_idx, fl_idx;
    logic [TAG_W-1:0] f_tag;
    logic f_way, fl_way;
    logic [511:0] wb_line, fill_line;
    logic [TAG_W-1:0] wb_tag;

    // One read address (hit load or victim row) and one write address (store
    // on hit or refill row) per way; both ways are read together.
    wire rd_victim = st == S_RD0 || st == S_RD1;
    wire wr_fill = st == S_WR0 || st == S_WR1;
    wire [IDX_W:0] r_row = rd_victim ? {f_idx, st == S_RD1} : {idx, a[5]};
    wire [IDX_W:0] w_row = wr_fill ? {f_idx, st == S_WR1} : {idx, a[5]};
    wire [255:0] fill_row = st == S_WR1 ? fill_line[511:256] : fill_line[255:0];
    wire [255:0] st_row = {8{st_wdata}};
    logic [255:0] q_row [0:1];
    for (genvar w = 0; w < 2; w++) begin : g_way
        for (genvar c = 0; c < 32; c++) begin : g_col
            // byte c of the row belongs to word c/4, byte lane c%4
            wire we_st = st_ready && (hit1 == w) && a[4:2] == c / 4 && st_wstrb[c % 4];
            wire we_fill = wr_fill && f_way == w;
            sdp_ram #(.DW(8), .AW(IDX_W + 1)) col (
                .clk(clk), .we(we_st || we_fill), .waddr(w_row),
                .wdata(we_fill ? fill_row[8*c +: 8] : st_row[8*c +: 8]),
                .re(ld_ready || rd_victim), .raddr(r_row), .rdata(q_row[w][8*c +: 8]));
        end
    end
    logic r_way;
    logic [2:0] r_lane;
    always_ff @(posedge clk) if (ld_ready) begin
        r_way <= hit1;
        r_lane <= a[4:2];
    end
    assign ld_rdata = q_row[r_way][32*r_lane +: 32];
    // Victim row lands in the RAM output register one cycle after its read.
    wire [255:0] rd_row = q_row[f_way];
    // Tags (distributed RAM): written only on refill.
    always_ff @(posedge clk) if (st == S_WR1) begin
        if (f_way) tag1[f_idx] <= f_tag;
        else tag0[f_idx] <= f_tag;
    end

    assign mem_req = st == S_WB || st == S_FILL;
    assign mem_we = st == S_WB;
    assign mem_addr = st == S_WB ? {wb_tag, f_idx, 6'b0} : {f_tag, f_idx, 6'b0};
    // The second victim row is still in rd_row during the first S_WB cycle,
    // which is when the bridge latches the line.
    assign mem_wdata = {rd_half ? rd_row : wb_line[511:256], wb_line[255:0]};
    assign ev_writeback = st == S_WB && mem_done;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE;
            v0 <= 0; v1 <= 0; d0 <= 0; d1 <= 0; lru <= 0;
            ld_rvalid <= 0;
            st_done <= 0;
            f_flushing <= 0;
            rd_half <= 0;
        end else begin
            ld_rvalid <= ld_ready;
            st_done <= st_ready;
            if (ld_ready || st_ready) lru[idx] <= hit0;
            if (st_ready) begin
                if (hit1) d1[idx] <= 1; else d0[idx] <= 1;
            end
            rd_half <= st == S_RD1;
            if (rd_half) wb_line[511:256] <= rd_row;
            else if (st == S_RD1) wb_line[255:0] <= rd_row;
            case (st)
                S_IDLE: begin
                    if (flush) begin
                        st <= S_FLUSH;
                        f_flushing <= 1;
                        fl_idx <= 0;
                        fl_way <= 0;
                    end else if ((st_valid || ld_valid) && !hit) begin
                        f_flushing <= 0;
                        f_idx <= idx;
                        f_tag <= tag;
                        // victim: an invalid way first, else LRU
                        if (!v0[idx]) begin f_way <= 0; st <= S_FILL; end
                        else if (!v1[idx]) begin f_way <= 1; st <= S_FILL; end
                        else begin
                            f_way <= lru[idx];
                            if (lru[idx] ? d1[idx] : d0[idx]) begin
                                wb_tag <= lru[idx] ? tag1[idx] : tag0[idx];
                                st <= S_RD0;
                            end else st <= S_FILL;
                        end
                    end
                end
                S_RD0: st <= S_RD1;
                S_RD1: st <= S_WB;                       // second row lands in wb_line next cycle
                S_WB: if (mem_done) begin
                    if (f_way) d1[f_idx] <= 0; else d0[f_idx] <= 0;
                    if (f_flushing) begin
                        if (f_way) v1[f_idx] <= 0; else v0[f_idx] <= 0;
                        st <= S_FLUSH;
                    end else st <= S_FILL;
                end
                S_FILL: if (mem_done) begin
                    fill_line <= mem_rdata;
                    st <= S_WR0;
                end
                S_WR0: st <= S_WR1;
                S_WR1: begin
                    if (f_way) begin v1[f_idx] <= 1; d1[f_idx] <= 0; end
                    else begin v0[f_idx] <= 1; d0[f_idx] <= 0; end
                    lru[f_idx] <= !f_way;
                    st <= S_IDLE;
                end
                S_FLUSH: begin
                    // visit (set, way) pairs; write back dirty ones, invalidate all
                    if (fl_way ? (v1[fl_idx] && d1[fl_idx]) : (v0[fl_idx] && d0[fl_idx])) begin
                        f_idx <= fl_idx;
                        f_way <= fl_way;
                        wb_tag <= fl_way ? tag1[fl_idx] : tag0[fl_idx];
                        st <= S_RD0;
                    end else begin
                        if (fl_way) v1[fl_idx] <= 0; else v0[fl_idx] <= 0;
                        fl_way <= !fl_way;
                        if (fl_way) fl_idx <= fl_idx + 1;
                        if (fl_way && fl_idx == SETS - 1) begin
                            st <= S_IDLE;
                            f_flushing <= 0;
                        end
                    end
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
