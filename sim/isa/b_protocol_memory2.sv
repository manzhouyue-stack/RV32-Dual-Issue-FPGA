// Dual-fetch variant (if_rdata1 = word at if_addr+4) of the
// B v0.3 protocol test double, NOT B's vendor RAM or actual subsystem RTL.
// Delay zero means accept at E0, registered response after E0, capture E1.
module b_protocol_memory2 #(
    parameter logic [31:0] BASE = 0
) (
    input logic clk, rst,
    input logic if_valid,
    input logic [31:0] if_addr,
    output logic if_ready, if_rvalid,
    output logic [31:0] if_rdata,
    output logic if_error,
    output logic [31:0] if_rdata1,
    output logic if_error1,
    input logic ld_valid,
    input logic [31:0] ld_addr,
    input logic [1:0] ld_size,
    output logic ld_ready, ld_rvalid,
    output logic [31:0] ld_rdata,
    output logic ld_error,
    input logic st_valid,
    input logic [31:0] st_addr, st_wdata,
    input logic [1:0] st_size,
    input logic [3:0] st_wstrb,
    output logic st_ready, st_done, st_error,
    input logic cfg_if_block, cfg_ld_block, cfg_st_block, cfg_boot_write,
    input logic [31:0] cfg_if_error_addr, cfg_ld_error_addr, cfg_st_error_addr,
    input integer cfg_delay, inject,
    output integer if_count, ld_count, st_count, ram_writes, uart_pops, uart_writes
);
    logic [31:0] mem [0:16383];
    logic [31:0] random_state;
    integer if_delay, ld_delay, st_delay;
    logic if_pending, ld_pending, st_pending;
    logic [31:0] saved_if_data, saved_ld_data;
    logic saved_if_error, saved_ld_error, saved_st_error;
    logic if_waited, ld_waited, st_waited;
    logic [31:0] previous_if, previous_ld, previous_st, previous_data;
    logic [1:0] previous_ld_size, previous_st_size;
    logic [3:0] previous_be;
    integer index;
    logic error_value;
    logic [31:0] read_value;

    function automatic integer ram_index(input logic [31:0] addr);
        if (BASE != 0) begin
            if (addr >= BASE && (addr - BASE) < 65536) ram_index = (addr - BASE) >> 2;
            else ram_index = -1;
        end else if (addr < 32'h8000) ram_index = addr >> 2;
        else if (addr >= 32'h10000 && addr < 32'h18000)
            ram_index = 8192 + ((addr - 32'h10000) >> 2);
        else ram_index = -1;
    endfunction
    function automatic logic device_address(input logic [31:0] addr);
        device_address = addr == 32'h10000000 || addr == 32'h10000004 ||
            addr == 32'h10000008 || addr == 32'h1000000c ||
            addr == 32'h10001000 || addr == 32'h10001004 || addr == 32'h10002000;
    endfunction

    assign st_ready = !st_pending && !cfg_st_block && (inject == 0 || random_state[3:0] > 3);
    assign ld_ready = !ld_pending && !cfg_ld_block &&
        (inject == 0 || random_state[7:4] > 3) && !(st_valid && st_ready);
    assign if_ready = !if_pending && !cfg_if_block &&
        (inject == 0 || random_state[11:8] > 3) &&
        !(st_valid && st_ready && st_wstrb != 0 && st_addr == if_addr && ram_index(st_addr) >= 0);

    always @(posedge clk) begin
        if (rst) begin
            random_state <= 32'hb7e1a953;
            if_rvalid <= 0;
            ld_rvalid <= 0;
            st_done <= 0;
            if_pending <= 0;
            ld_pending <= 0;
            st_pending <= 0;
            if_count <= 0;
            ld_count <= 0;
            st_count <= 0;
            ram_writes <= 0;
            uart_pops <= 0;
            uart_writes <= 0;
            if_waited <= 0;
            ld_waited <= 0;
            st_waited <= 0;
        end else begin
            random_state <= {random_state[30:0], random_state[31]^random_state[21]^random_state[1]^random_state[0]};
            if_rvalid <= 0;
            ld_rvalid <= 0;
            st_done <= 0;
            if (if_waited && (!if_valid || if_addr !== previous_if)) $fatal(1,"IF waiting request changed");
            // rv32_core_p may withdraw a refused EX load and reissue it from MEM;
            // B v0.3's subsystem keeps no state for unaccepted loads.
            if (st_waited && (!st_valid || st_addr !== previous_st || st_size !== previous_st_size ||
                st_wdata !== previous_data || st_wstrb !== previous_be)) $fatal(1,"ST waiting request changed");
            if_waited <= if_valid && !if_ready;
            ld_waited <= ld_valid && !ld_ready;
            st_waited <= st_valid && !st_ready;
            previous_if <= if_addr;
            previous_ld <= ld_addr;
            previous_st <= st_addr;
            previous_ld_size <= ld_size;
            previous_st_size <= st_size;
            previous_data <= st_wdata;
            previous_be <= st_wstrb;

            if (if_pending) begin
                if (if_delay == 1) begin
                    if_rvalid <= 1;
                    if_rdata <= saved_if_data;
                    if_error <= saved_if_error;
                    if_pending <= 0;
                end else if_delay <= if_delay - 1;
            end
            if (ld_pending) begin
                if (ld_delay == 1) begin
                    ld_rvalid <= 1;
                    ld_rdata <= saved_ld_data;
                    ld_error <= saved_ld_error;
                    ld_pending <= 0;
                end else ld_delay <= ld_delay - 1;
            end
            if (st_pending) begin
                if (st_delay == 1) begin
                    st_done <= 1;
                    st_error <= saved_st_error;
                    st_pending <= 0;
                end else st_delay <= st_delay - 1;
            end

            if (if_valid && if_ready) begin
                if_count <= if_count + 1;
                index = ram_index(if_addr);
                error_value = index < 0 || (BASE == 0 && if_addr >= 32'h8000) ||
                    if_addr[1:0] != 0 || if_addr == cfg_if_error_addr;
                read_value = error_value ? 0 : mem[index];
                if (cfg_delay == 0) begin
                    if_rvalid <= 1;
                    if_rdata <= read_value;
                    if_error <= error_value;
                    // dual-issue fetch: word at if_addr + 4
                    if_error1 <= ram_index(if_addr + 4) < 0 || if_addr[1:0] != 0;
                    if_rdata1 <= ram_index(if_addr + 4) < 0 ? 0 : mem[ram_index(if_addr + 4)];
                end else begin
                    if_pending <= 1;
                    if_delay <= cfg_delay;
                    saved_if_data <= read_value;
                    saved_if_error <= error_value;
                end
            end
            if (ld_valid && ld_ready) begin
                ld_count <= ld_count + 1;
                index = ram_index(ld_addr);
                error_value = ld_size == 3 || ld_addr[1:0] != 0 || ld_addr == cfg_ld_error_addr;
                read_value = 0;
                if (index >= 0) read_value = mem[index];
                else if (device_address(ld_addr) && ld_size == 2) begin
                    if (ld_addr == 32'h10000000) begin
                        read_value = 32'h40 + uart_pops;
                        if (!error_value) uart_pops <= uart_pops + 1;
                    end else read_value = 2;
                end else error_value = 1;
                if (cfg_delay == 0) begin
                    ld_rvalid <= 1;
                    ld_rdata <= error_value ? 0 : read_value;
                    ld_error <= error_value;
                end else begin
                    ld_pending <= 1;
                    ld_delay <= cfg_delay;
                    saved_ld_data <= error_value ? 0 : read_value;
                    saved_ld_error <= error_value;
                end
            end
            if (st_valid && st_ready) begin
                st_count <= st_count + 1;
                index = ram_index(st_addr);
                error_value = st_size == 3 || st_addr[1:0] != 0 || st_addr == cfg_st_error_addr;
                if (index >= 0) begin
                    if (BASE == 0 && st_addr < 4096 && !cfg_boot_write) error_value = 1;
                    if (!error_value && st_wstrb != 0) begin
                        ram_writes <= ram_writes + 1;
                        for (integer b=0; b<4; b=b+1)
                            if (st_wstrb[b]) mem[index][8*b+:8] <= st_wdata[8*b+:8];
                    end
                end else if (device_address(st_addr) && st_size == 2) begin
                    if (st_addr == 32'h10000004 || st_addr == 32'h10001004) error_value = 1;
                    if (!error_value && st_addr == 32'h10000000) uart_writes <= uart_writes + 1;
                end else error_value = 1;
                if (cfg_delay == 0) begin
                    st_done <= 1;
                    st_error <= error_value;
                end else begin
                    st_pending <= 1;
                    st_delay <= cfg_delay;
                    saved_st_error <= error_value;
                end
            end
        end
    end
endmodule
