logic external_freeze = 0;
logic if_valid, if_ready, if_rvalid, if_error, if_error1;
logic [31:0] if_rdata1;
logic [31:0] ld_maddr;   // v1.1 core output (unused by the protocol model)
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
// v1.0 machine interrupts / platform time (tied off for ISA suites)
logic irq_soft = 0, irq_timer = 0, irq_ext = 0;
logic [63:0] mtime = 0;
logic retire1_valid, retire1_rd_we, retire1_mem_valid, retire1_mem_we;
logic [31:0] retire1_pc, retire1_instr, retire1_rd_data, retire1_mem_addr, retire1_mem_wdata;
logic [4:0] retire1_rd;
logic [3:0] retire1_mem_be;
logic [31:0] fault_pc, fault_instr, fault_addr;
logic cfg_if_block = 0, cfg_ld_block = 0, cfg_st_block = 0;
logic cfg_boot_write = 1;
logic [31:0] cfg_if_error_addr = 32'hffffffff;
logic [31:0] cfg_ld_error_addr = 32'hffffffff;
logic [31:0] cfg_st_error_addr = 32'hffffffff;
integer cfg_delay = 0;
integer inject = 0;
integer if_count, ld_count, st_count, ram_writes, uart_pops, uart_writes;
rv32_core_d #(.RESET_PC(BASE), .PRED_HI(BASE[31:16])
`ifdef CPU_NO_M
    , .ENABLE_M(0)
`endif
`ifdef CPU_NO_B
    , .ENABLE_B(0)
`endif
    ) dut(.*);
b_protocol_memory2 #(.BASE(BASE)) memory(.*);
