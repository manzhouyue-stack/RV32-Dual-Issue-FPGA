// 32x32 register file, 4 read / 2 write ports (dual-issue). Port 1 is the
// younger instruction and wins when both write the same register. Reads see
// the value being written in the same cycle (WB -> ID write-through).
module rv32_regfile2 (
    input  logic clk,
    input  logic we0, we1,
    input  logic [4:0] wa0, wa1,
    input  logic [31:0] wd0, wd1,
    input  logic [4:0] ra [0:3],
    output logic [31:0] rd [0:3]
);
    logic [31:0] rf [1:31];
    always_ff @(posedge clk) begin
        if (we0 && wa0 != 0 && !(we1 && wa1 == wa0)) rf[wa0] <= wd0;
        if (we1 && wa1 != 0) rf[wa1] <= wd1;
    end
    always_comb begin
        for (int i = 0; i < 4; i++) begin
            if (ra[i] == 0) rd[i] = 0;
            else if (we1 && wa1 == ra[i]) rd[i] = wd1;
            else if (we0 && wa0 == ra[i]) rd[i] = wd0;
            else rd[i] = rf[ra[i]];
        end
    end
endmodule
