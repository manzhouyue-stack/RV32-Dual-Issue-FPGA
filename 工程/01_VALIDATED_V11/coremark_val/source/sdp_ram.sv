// Simple dual-port RAM: one synchronous write port, one synchronous read port
// (read data registered). Written in the plain inference style so synthesis
// maps it to block or distributed RAM.
module sdp_ram #(
    parameter int DW = 8,
    parameter int AW = 7
) (
    input  logic clk,
    input  logic we,
    input  logic [AW-1:0] waddr,
    input  logic [DW-1:0] wdata,
    input  logic re,
    input  logic [AW-1:0] raddr,
    output logic [DW-1:0] rdata
);
    logic [DW-1:0] mem [0:(1 << AW) - 1];
    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        if (re) rdata <= mem[raddr];
    end
endmodule
