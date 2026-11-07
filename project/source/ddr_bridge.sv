// CPU clock domain <-> Pango ips2l_hmic_s DDR3 controller (AXI 256-bit host
// port, aclk = controller core_clk). Moves one 64-byte cache line per
// operation as a 2-beat AXI burst (awlen/arlen = 1).
//
// Clock crossing: one operation outstanding. The CPU side latches the command
// (and write line) into c_* registers, then flips req_t; the DDR side sees the
// flip through a 2-FF synchroniser, performs the burst, latches read data into
// r_line and flips ack_t back. Command/data registers are stable whenever the
// other domain samples them (toggle handshake), so only req_t/ack_t/init_done
// need synchronisers; the c_* -> aclk and r_line -> clk paths are constrained
// as asynchronous (false path between the clock groups).
//
// HMIC AXI conventions (from the vendor example design):
//   address unit = one 32-bit DQ word; one 256-bit beat = 8 units
//   write data has no wvalid: the controller pulls a beat with axi_wready and
//     the current beat must already be on axi_wdata
//   read data has no rready: beats arrive with axi_rvalid and must be taken
module ddr_bridge #(
    parameter int AW = 28
) (
    // CPU domain
    input  logic clk,
    input  logic rst_n,
    input  logic req,                 // start when !busy
    input  logic req_we,
    input  logic [AW-1:0] req_addr,   // DDR word address, 16-word (line) aligned
    input  logic [511:0] req_wdata,
    output logic busy,
    output logic done,                // one-cycle pulse; rdata valid for reads
    output logic [511:0] rdata,
    output logic ddr_ready,           // controller initialised (synchronised)
    // DDR controller domain
    input  logic aclk,
    input  logic arst_n,
    input  logic init_done,
    output logic [AW-1:0] axi_awaddr,
    output logic axi_awuser_ap,
    output logic [3:0] axi_awuser_id,
    output logic [3:0] axi_awlen,
    input  logic axi_awready,
    output logic axi_awvalid,
    output logic [255:0] axi_wdata,
    output logic [31:0] axi_wstrb,
    input  logic axi_wready,
    output logic [AW-1:0] axi_araddr,
    output logic axi_aruser_ap,
    output logic [3:0] axi_aruser_id,
    output logic [3:0] axi_arlen,
    input  logic axi_arready,
    output logic axi_arvalid,
    input  logic [255:0] axi_rdata,
    input  logic axi_rlast,
    input  logic axi_rvalid
);
    // ---------------- CPU side ----------------
    logic req_t, c_we;
    logic [AW-1:0] c_addr;
    logic [511:0] c_wdata;
    (* ASYNC_REG = "TRUE" *) logic ack_s1, ack_s2, init_s1, init_s2;
    logic [511:0] r_line;
    logic ack_t;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            req_t <= 0;
            busy <= 0;
            done <= 0;
            ack_s1 <= 0; ack_s2 <= 0;
            init_s1 <= 0; init_s2 <= 0;
        end else begin
            ack_s1 <= ack_t; ack_s2 <= ack_s1;
            init_s1 <= init_done; init_s2 <= init_s1;
            done <= 0;
            if (!busy && req) begin
                c_we <= req_we;
                c_addr <= req_addr;
                c_wdata <= req_wdata;
                req_t <= ~req_t;
                busy <= 1;
            end else if (busy && ack_s2 == req_t) begin
                busy <= 0;
                done <= 1;
                rdata <= r_line;          // stable: DDR side finished before ack_t flipped
            end
        end
    end
    assign ddr_ready = init_s2;

    // ---------------- DDR side ----------------
    typedef enum logic [1:0] {A_IDLE, A_WRITE, A_READ} astate_t;
    astate_t st;
    (* ASYNC_REG = "TRUE" *) logic req_s1, req_s2;
    logic seen, aw_done, wbeat, rbeat;
    logic [1:0] wcount;
    assign axi_awuser_ap = 1'b0;
    assign axi_awuser_id = 4'd0;
    assign axi_awlen = 4'd1;
    assign axi_aruser_ap = 1'b0;
    assign axi_aruser_id = 4'd0;
    assign axi_arlen = 4'd1;
    assign axi_wdata = wbeat ? c_wdata[511:256] : c_wdata[255:0];
    assign axi_wstrb = 32'hffff_ffff;
    always_ff @(posedge aclk or negedge arst_n) begin
        if (!arst_n) begin
            st <= A_IDLE;
            req_s1 <= 0; req_s2 <= 0;
            seen <= 0;
            ack_t <= 0;
            axi_awvalid <= 0;
            axi_arvalid <= 0;
            aw_done <= 0;
            wbeat <= 0;
            wcount <= 0;
            rbeat <= 0;
        end else begin
            req_s1 <= req_t; req_s2 <= req_s1;
            case (st)
                A_IDLE: if (req_s2 != seen && init_done) begin
                    seen <= req_s2;
                    if (c_we) begin
                        st <= A_WRITE;
                        axi_awaddr <= c_addr;
                        axi_awvalid <= 1;
                        aw_done <= 0;
                        wbeat <= 0;
                        wcount <= 0;
                    end else begin
                        st <= A_READ;
                        axi_araddr <= c_addr;
                        axi_arvalid <= 1;
                        rbeat <= 0;
                    end
                end
                A_WRITE: begin
                    if (axi_awvalid && axi_awready) begin
                        axi_awvalid <= 0;
                        aw_done <= 1;
                    end
                    if (axi_wready && wcount != 2) begin
                        wbeat <= 1;
                        wcount <= wcount + 1;
                    end
                    if ((aw_done || (axi_awvalid && axi_awready)) &&
                        (wcount == 2 || (wcount == 1 && axi_wready))) begin
                        st <= A_IDLE;
                        ack_t <= ~ack_t;
                    end
                end
                A_READ: begin
                    if (axi_arvalid && axi_arready) axi_arvalid <= 0;
                    if (axi_rvalid) begin
                        if (rbeat) r_line[511:256] <= axi_rdata;
                        else r_line[255:0] <= axi_rdata;
                        rbeat <= 1;
                        if (rbeat || axi_rlast) begin
                            st <= A_IDLE;
                            ack_t <= ~ack_t;
                        end
                    end
                end
                default: st <= A_IDLE;
            endcase
        end
    end
endmodule
