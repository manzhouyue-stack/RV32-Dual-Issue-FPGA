logic external_freeze = 0;
logic if_valid, if_ready, if_rvalid, if_error;
logic [31:0] if_addr, if_rdata;
logic ld_valid, ld_ready, ld_rvalid, ld_error;
logic [31:0] ld_addr, ld_rdata;
logic [1:0] ld_size;
logic st_valid, st_ready, st_done, st_error;
logic [31:0] st_addr, st_wdata;
logic [1:0] st_size;
logic [3:0] st_wstrb;
logic retire_valid, retire_rd_we, retire_mem_valid, retire_mem_we;
logic [31:0] retire_pc, retire_instr, retire_rd_data, retire_mem_addr, retire_mem_wdata;
logic [4:0] retire_rd, debug_valid;
logic [3:0] retire_mem_be, fault_cause;
logic fault_valid;
logic [31:0] fault_pc, fault_instr, fault_addr;
logic cfg_if_block = 0, cfg_ld_block = 0, cfg_st_block = 0;
logic cfg_boot_write = 1;
logic [31:0] cfg_if_error_addr = 32'hffffffff;
logic [31:0] cfg_ld_error_addr = 32'hffffffff;
logic [31:0] cfg_st_error_addr = 32'hffffffff;
integer cfg_delay = 0;
integer inject = 0;
integer if_count, ld_count, st_count, ram_writes, uart_pops, uart_writes;
rv32_core_p #(.RESET_PC(BASE), .PRED_HI(BASE[31:15])
`ifdef CPU_M
    , .ENABLE_M(1)
`endif
`ifdef CPU_B
    , .ENABLE_B(1)
`endif
    ) dut(.*);
b_protocol_memory #(.BASE(BASE)) memory(.*);
