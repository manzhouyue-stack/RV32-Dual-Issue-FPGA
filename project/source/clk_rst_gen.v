`timescale 1ns/1ps

// MES2L676-100HP clock/reset boundary. KEY0 is active low.
// Keep the PLL reset asserted through power-on and until KEY0 has stayed
// released for 20 ms in the independent, continuously running 27 MHz domain.
// Never feed !pll_locked into PLL reset: that would prevent initial locking.
module clk_rst_gen #(
    parameter integer REF_RELEASE_CYCLES = 540000
) (
    input wire clk_ref,
    input wire key0_n,
    output wire clk_sys,
    output wire rst_sys_n,
    output wire pll_locked
);
    (* syn_preserve = 1 *) reg key_meta = 1'b0;
    (* syn_preserve = 1 *) reg key_sync = 1'b0;
    reg [19:0] release_count = 20'd0;
    reg pll_rst = 1'b1;

    always @(posedge clk_ref or negedge key0_n) begin
        if (!key0_n) begin
            key_meta <= 1'b0;
            key_sync <= 1'b0;
        end else begin
            key_meta <= 1'b1;
            key_sync <= key_meta;
        end
    end

    always @(posedge clk_ref or negedge key0_n) begin
        if (!key0_n) begin
            release_count <= 20'd0;
            pll_rst <= 1'b1;
        end else if (!key_sync) begin
            release_count <= 20'd0;
            pll_rst <= 1'b1;
        end else if (release_count == REF_RELEASE_CYCLES - 1) begin
            pll_rst <= 1'b0;
        end else begin
            release_count <= release_count + 1'b1;
        end
    end

    pll_27_to_50 u_pll (
        .clkin1(clk_ref), .rst(pll_rst),
        .clkout0(clk_sys), .lock(pll_locked)
    );

    // Assertion works even if the PLL output clock is absent. Release can
    // only progress on three rising edges after all reset causes disappear.
    wire async_reset = !key0_n || pll_rst || !pll_locked;
    reset_release_sync u_sys_reset (
        .clk(clk_sys), .async_reset(async_reset), .rst_n(rst_sys_n)
    );
endmodule

module reset_release_sync (
    input wire clk,
    input wire async_reset,
    output wire rst_n
);
    (* syn_preserve = 1 *) reg [2:0] release_pipe = 3'b000;
    always @(posedge clk or posedge async_reset) begin
        if (async_reset)
            release_pipe <= 3'b000;
        else
            release_pipe <= {release_pipe[1:0], 1'b1};
    end
    assign rst_n = release_pipe[2];
endmodule
