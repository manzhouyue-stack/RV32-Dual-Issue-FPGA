// DDR region (0x8000_0000 - 0x9FFF_FFFF, 512 MiB) memory system:
// I-cache + D-cache (2-way, 8 KiB each, 64-byte lines) sharing one line bridge
// to the HMIC DDR3 controller (2-beat AXI bursts across the clock domains).
// Register page 0x1000_4000 (word offsets, all 32-bit):
//   0x00 STATUS  r : bit0 DDR initialised, bit1 D-cache flush in progress
//   0x04 CTRL    w : bit0 flush D-cache (write back + invalidate), bit1 invalidate I-cache,
//                    bit2 clear statistics
//   0x08 IC_HITS  0x0C IC_FILLS  0x10 DC_HITS  0x14 DC_FILLS  0x18 DC_WRITEBACKS
//   0x1C BUS_BUSY (CPU cycles with a line transfer outstanding)
//   0x20 BUS_LINES (64-byte bursts completed: fills + write-backs)
module ddr_cache_top (
    input  logic clk,
    input  logic rst_n,
    // fetch
    input  logic if_valid,
    input  logic [28:0] if_off,
    output logic if_ready,
    output logic if_rvalid,
    output logic [31:0] if_rdata0,
    output logic [31:0] if_rdata1,
    // load / store
    input  logic ld_valid,
    input  logic [28:0] ld_off,
    output logic ld_ready,
    output logic ld_rvalid,
    output logic [31:0] ld_rdata,
    input  logic st_valid,
    input  logic [28:0] st_off,
    input  logic [31:0] st_wdata,
    input  logic [3:0] st_wstrb,
    output logic st_ready,
    output logic st_done,
    // register page (accepted accesses only)
    input  logic reg_rd,
    input  logic [7:0] reg_rd_off,
    output logic [31:0] reg_rdata,
    input  logic reg_wr,
    input  logic [7:0] reg_wr_off,
    input  logic [31:0] reg_wdata,
    // DDR controller (aclk domain)
    input  logic aclk,
    input  logic arst_n,
    input  logic ddr_init_done,
    output logic [27:0] axi_awaddr,
    output logic axi_awuser_ap,
    output logic [3:0] axi_awuser_id,
    output logic [3:0] axi_awlen,
    input  logic axi_awready,
    output logic axi_awvalid,
    output logic [255:0] axi_wdata,
    output logic [31:0] axi_wstrb,
    input  logic axi_wready,
    output logic [27:0] axi_araddr,
    output logic axi_aruser_ap,
    output logic [3:0] axi_aruser_id,
    output logic [3:0] axi_arlen,
    input  logic axi_arready,
    output logic axi_arvalid,
    input  logic [255:0] axi_rdata,
    input  logic axi_rlast,
    input  logic axi_rvalid
);
    logic ddr_ready, ctrl_flush, ctrl_inv, flush_busy;
    logic ic_fill_req, ic_fill_done, dc_req, dc_we, dc_done;
    logic [28:0] ic_fill_addr, dc_addr;
    logic [511:0] dc_wdata, br_rdata;
    logic ic_ev_hit, ic_ev_miss, dc_ev_hit, dc_ev_miss, dc_ev_wb;

    // Nothing in the DDR region is served until the controller is calibrated.
    logic ic_ready_raw, ld_ready_raw, st_ready_raw;
    assign if_ready = ic_ready_raw && ddr_ready;
    assign ld_ready = ld_ready_raw && ddr_ready;
    assign st_ready = st_ready_raw && ddr_ready;

    icache icache (
        .clk(clk), .rst_n(rst_n),
        .req_valid(if_valid && ddr_ready), .req_addr(if_off), .req_ready(ic_ready_raw),
        .rvalid(if_rvalid), .rdata0(if_rdata0), .rdata1(if_rdata1),
        .invalidate(ctrl_inv),
        .fill_req(ic_fill_req), .fill_addr(ic_fill_addr), .fill_done(ic_fill_done), .fill_data(br_rdata),
        .ev_hit(ic_ev_hit), .ev_miss(ic_ev_miss));

    dcache dcache (
        .clk(clk), .rst_n(rst_n),
        .ld_valid(ld_valid && ddr_ready), .ld_addr(ld_off), .ld_ready(ld_ready_raw),
        .ld_rvalid(ld_rvalid), .ld_rdata(ld_rdata),
        .st_valid(st_valid && ddr_ready), .st_addr(st_off), .st_wdata(st_wdata), .st_wstrb(st_wstrb),
        .st_ready(st_ready_raw), .st_done(st_done),
        .flush(ctrl_flush), .flush_busy(flush_busy),
        .mem_req(dc_req), .mem_we(dc_we), .mem_addr(dc_addr), .mem_wdata(dc_wdata),
        .mem_done(dc_done), .mem_rdata(br_rdata),
        .ev_hit(dc_ev_hit), .ev_miss(dc_ev_miss), .ev_writeback(dc_ev_wb));

    // ---- bridge arbitration: one line transfer at a time, D-cache first
    logic [1:0] owner;              // 0 none, 1 D-cache, 2 I-cache
    logic started, br_busy, br_done, br_req;
    assign br_req = !br_busy && !started &&
        ((owner == 2'd1 && dc_req) || (owner == 2'd2 && ic_fill_req));
    assign dc_done = br_done && owner == 2'd1;
    assign ic_fill_done = br_done && owner == 2'd2;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner <= 0;
            started <= 0;
        end else begin
            if (owner == 0) begin
                if (dc_req) owner <= 2'd1;
                else if (ic_fill_req) owner <= 2'd2;
            end
            if (br_req) started <= 1;
            if (br_done) begin
                owner <= 0;
                started <= 0;
            end
        end
    end

    ddr_bridge #(.AW(28)) bridge (
        .clk(clk), .rst_n(rst_n),
        .req(br_req), .req_we(owner == 2'd1 && dc_we),
        .req_addr(owner == 2'd1 ? {1'b0, dc_addr[28:2]} : {1'b0, ic_fill_addr[28:2]}),
        .req_wdata(dc_wdata),
        .busy(br_busy), .done(br_done), .rdata(br_rdata), .ddr_ready(ddr_ready),
        .aclk(aclk), .arst_n(arst_n), .init_done(ddr_init_done),
        .axi_awaddr(axi_awaddr), .axi_awuser_ap(axi_awuser_ap), .axi_awuser_id(axi_awuser_id),
        .axi_awlen(axi_awlen), .axi_awready(axi_awready), .axi_awvalid(axi_awvalid),
        .axi_wdata(axi_wdata), .axi_wstrb(axi_wstrb), .axi_wready(axi_wready),
        .axi_araddr(axi_araddr), .axi_aruser_ap(axi_aruser_ap), .axi_aruser_id(axi_aruser_id),
        .axi_arlen(axi_arlen), .axi_arready(axi_arready), .axi_arvalid(axi_arvalid),
        .axi_rdata(axi_rdata), .axi_rlast(axi_rlast), .axi_rvalid(axi_rvalid));

    // ---- control and statistics
    logic [31:0] c_ic_hits, c_ic_fills, c_dc_hits, c_dc_fills, c_dc_wbs, c_busy, c_lines;
    // A flush request waits until the D-cache is idle and starts it.
    logic flush_pend;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) flush_pend <= 0;
        else if (reg_wr && reg_wr_off == 8'h04 && reg_wdata[0]) flush_pend <= 1;
        else if (flush_busy) flush_pend <= 0;
    end
    assign ctrl_flush = flush_pend;
    assign ctrl_inv = reg_wr && reg_wr_off == 8'h04 && reg_wdata[1];
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n || (reg_wr && reg_wr_off == 8'h04 && reg_wdata[2])) begin
            c_ic_hits <= 0; c_ic_fills <= 0; c_dc_hits <= 0; c_dc_fills <= 0;
            c_dc_wbs <= 0; c_busy <= 0; c_lines <= 0;
        end else begin
            c_ic_hits <= c_ic_hits + ic_ev_hit;
            c_ic_fills <= c_ic_fills + ic_fill_done;
            c_dc_hits <= c_dc_hits + dc_ev_hit;
            c_dc_fills <= c_dc_fills + (dc_done && !dc_we);
            c_dc_wbs <= c_dc_wbs + dc_ev_wb;
            c_busy <= c_busy + br_busy;
            c_lines <= c_lines + br_done;
        end
    end
    always_comb begin
        case (reg_rd_off)
            8'h00: reg_rdata = {30'b0, flush_busy || flush_pend, ddr_ready};
            8'h08: reg_rdata = c_ic_hits;
            8'h0C: reg_rdata = c_ic_fills;
            8'h10: reg_rdata = c_dc_hits;
            8'h14: reg_rdata = c_dc_fills;
            8'h18: reg_rdata = c_dc_wbs;
            8'h1C: reg_rdata = c_busy;
            8'h20: reg_rdata = c_lines;
            default: reg_rdata = 32'b0;
        endcase
    end
endmodule
