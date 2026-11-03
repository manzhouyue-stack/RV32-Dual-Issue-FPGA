`timescale 1ns/1ps
// Behavioural stand-in for the Pango ips2l_hmic_s DDR3 controller's AXI host
// port (simulation only). Follows the conventions used by the vendor example:
//   address unit = one 32-bit DQ word, 256-bit beats (8 units per beat)
//   AW/AR: valid/ready; burst length = len + 1 beats
//   W: no wvalid - the model pulls beats with wready (data must be present)
//   R: no rready - beats are pushed with rvalid, rlast on the final beat
// Randomised accept delays, read latency and beat gaps; init_done after a
// calibration delay. Unwritten memory reads as a deterministic pattern.
module ddr_axi_model #(
    parameter int INIT_CYCLES = 200,
    parameter int RD_LAT_MIN = 12,
    parameter int RD_LAT_MAX = 24
) (
    input  logic aclk,
    input  logic arst_n,
    output logic init_done,
    input  logic [27:0] axi_awaddr,
    input  logic [3:0] axi_awlen,
    output logic axi_awready,
    input  logic axi_awvalid,
    input  logic [255:0] axi_wdata,
    input  logic [31:0] axi_wstrb,
    output logic axi_wready,
    input  logic [27:0] axi_araddr,
    input  logic [3:0] axi_arlen,
    output logic axi_arready,
    input  logic axi_arvalid,
    output logic [255:0] axi_rdata,
    output logic axi_rlast,
    output logic axi_rvalid
);
    logic [255:0] mem [int];
    int init_cnt, seed;
    int wr_beats_left, rd_beats_left, rd_wait;
    logic [24:0] wr_beat_addr, rd_beat_addr;
    int writes, reads;

    function automatic logic [255:0] fetch(input logic [24:0] beat);
        if (mem.exists(beat)) fetch = mem[beat];
        else fetch = {8{beat * 32'h9e3779b9 ^ 32'hdead_beef}};
    endfunction

    always_ff @(posedge aclk or negedge arst_n) begin
        if (!arst_n) begin
            init_done <= 0;
            init_cnt <= 0;
            seed <= 32'h1234_5678;
            axi_awready <= 0;
            axi_wready <= 0;
            axi_arready <= 0;
            axi_rvalid <= 0;
            axi_rlast <= 0;
            wr_beats_left <= 0;
            rd_beats_left <= 0;
            rd_wait <= 0;
            writes <= 0;
            reads <= 0;
        end else begin
            seed <= seed * 1103515245 + 12345;
            if (init_cnt < INIT_CYCLES) init_cnt <= init_cnt + 1;
            else init_done <= 1;
            axi_awready <= 0;
            axi_arready <= 0;
            axi_wready <= 0;
            axi_rvalid <= 0;
            axi_rlast <= 0;
            // ---- write address, then pull the data beats
            if (init_done && wr_beats_left == 0 && axi_awvalid && !axi_awready && seed[17:16] != 0) begin
                axi_awready <= 1;
                wr_beats_left <= axi_awlen + 1;
                wr_beat_addr <= axi_awaddr[27:3];
                if (axi_awaddr[2:0] != 0) $fatal(1, "ddr_axi_model: unaligned AW address %h", axi_awaddr);
            end
            if (wr_beats_left != 0 && !axi_awready && seed[19:18] != 0) begin
                // wready this cycle: the beat currently on axi_wdata is taken
                axi_wready <= 1;
            end
            if (axi_wready) begin
                logic [255:0] old;
                old = fetch(wr_beat_addr);
                for (int b = 0; b < 32; b++) if (axi_wstrb[b]) old[8*b +: 8] = axi_wdata[8*b +: 8];
                mem[wr_beat_addr] = old;
                wr_beat_addr <= wr_beat_addr + 1;
                wr_beats_left <= wr_beats_left - 1;
                if (wr_beats_left - 1 != 0 && seed[19:18] != 0) axi_wready <= 1;
                else axi_wready <= 0;
                writes <= writes + 1;
            end
            // ---- read address, latency, then push the beats
            if (init_done && rd_beats_left == 0 && rd_wait == 0 && axi_arvalid && !axi_arready && seed[21:20] != 0) begin
                axi_arready <= 1;
                rd_beats_left <= axi_arlen + 1;
                rd_beat_addr <= axi_araddr[27:3];
                rd_wait <= RD_LAT_MIN + (seed[27:24] % (RD_LAT_MAX - RD_LAT_MIN + 1));
                if (axi_araddr[2:0] != 0) $fatal(1, "ddr_axi_model: unaligned AR address %h", axi_araddr);
            end else if (rd_wait > 1) rd_wait <= rd_wait - 1;
            else if (rd_wait == 1 && rd_beats_left != 0) begin
                axi_rvalid <= 1;
                axi_rdata <= fetch(rd_beat_addr);
                axi_rlast <= rd_beats_left == 1;
                rd_beat_addr <= rd_beat_addr + 1;
                rd_beats_left <= rd_beats_left - 1;
                reads <= reads + 1;
                if (rd_beats_left == 1) rd_wait <= 0;
            end
        end
    end
endmodule
