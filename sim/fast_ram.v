`timescale 1ns/1ps
// Fast-simulation stand-ins. NOT for synthesis.
// - soc_itcm_ram / soc_dtcm_ram: behavioral true dual-port RAM with the same
//   ports as the Pango IP: synchronous read, output held while clk_en is low,
//   per-byte write enables. Initial image from +ITCM_HEX / +DTCM_HEX.
// - uart_transport: instant TX (never full, always idle) that prints bytes;
//   RX idle. Lets CoreMark run without bit-accurate 115200 baud timing.
module fast_dpram #(parameter string PLUSARG = "ITCM_HEX") (
    input a_clk, a_clk_en, a_rst, a_wr_en, input [12:0] a_addr, input [31:0] a_wr_data,
    input [3:0] a_wr_byte_en, output reg [31:0] a_rd_data,
    input b_clk, b_clk_en, b_rst, b_wr_en, input [12:0] b_addr, input [31:0] b_wr_data,
    input [3:0] b_wr_byte_en, output reg [31:0] b_rd_data
);
    reg [31:0] mem [0:8191];
    string file;
    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1) mem[i] = 0;
        if ($value$plusargs({PLUSARG, "=%s"}, file)) $readmemh(file, mem);
        else $fatal(1, "missing +%s", PLUSARG);
    end
    always @(posedge a_clk) if (a_clk_en) begin
        if (a_wr_en) for (i = 0; i < 4; i = i + 1) if (a_wr_byte_en[i]) mem[a_addr][8*i+:8] <= a_wr_data[8*i+:8];
        a_rd_data <= mem[a_addr];
    end
    always @(posedge b_clk) if (b_clk_en) begin
        if (b_wr_en) begin
            for (i = 0; i < 4; i = i + 1) if (b_wr_byte_en[i]) mem[b_addr][8*i+:8] <= b_wr_data[8*i+:8];
        end
        b_rd_data <= mem[b_addr];
    end
endmodule

module soc_itcm_ram (
    input a_clk, a_clk_en, a_rst, a_wr_en, input [12:0] a_addr, input [31:0] a_wr_data,
    input [3:0] a_wr_byte_en, output [31:0] a_rd_data,
    input b_clk, b_clk_en, b_rst, b_wr_en, input [12:0] b_addr, input [31:0] b_wr_data,
    input [3:0] b_wr_byte_en, output [31:0] b_rd_data
);
    fast_dpram #("ITCM_HEX") ram(.*);
endmodule

module soc_dtcm_ram (
    input a_clk, a_clk_en, a_rst, a_wr_en, input [12:0] a_addr, input [31:0] a_wr_data,
    input [3:0] a_wr_byte_en, output [31:0] a_rd_data,
    input b_clk, b_clk_en, b_rst, b_wr_en, input [12:0] b_addr, input [31:0] b_wr_data,
    input [3:0] b_wr_byte_en, output [31:0] b_rd_data
);
    fast_dpram #("DTCM_HEX") ram(.*);
endmodule


// v0.8 banked ITCM (word-interleaved even/odd banks, 8192 words each)
module soc_itcm_ram_b0 (
    input a_clk, a_clk_en, a_rst, a_wr_en, input [12:0] a_addr, input [31:0] a_wr_data,
    input [3:0] a_wr_byte_en, output [31:0] a_rd_data,
    input b_clk, b_clk_en, b_rst, b_wr_en, input [12:0] b_addr, input [31:0] b_wr_data,
    input [3:0] b_wr_byte_en, output [31:0] b_rd_data
);
    fast_dpram #("ITCM0_HEX") ram(.*);
endmodule

module soc_itcm_ram_b1 (
    input a_clk, a_clk_en, a_rst, a_wr_en, input [12:0] a_addr, input [31:0] a_wr_data,
    input [3:0] a_wr_byte_en, output [31:0] a_rd_data,
    input b_clk, b_clk_en, b_rst, b_wr_en, input [12:0] b_addr, input [31:0] b_wr_data,
    input [3:0] b_wr_byte_en, output [31:0] b_rd_data
);
    fast_dpram #("ITCM1_HEX") ram(.*);
endmodule
