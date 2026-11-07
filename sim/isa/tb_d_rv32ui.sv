`timescale 1ns/1ps
module tb_d_rv32ui;
    localparam [31:0] BASE = 32'h80001000;
    logic clk=0, rst=1;
    always #5 clk=~clk;
    `include "d_core_ports.svh"
    string memfile, tracefile;
    integer words, trace_fd=0, retired=0;
    logic [31:0] tohost;
    logic [31:0] prng=32'hf4713529;
    initial begin
        if (!$value$plusargs("mem=%s",memfile)) $fatal(1,"missing mem");
        if (!$value$plusargs("words=%d",words)) $fatal(1,"missing words");
        if (!$value$plusargs("tohost=%h",tohost)) $fatal(1,"missing tohost");
        if (!$value$plusargs("inject=%d",inject)) inject=0;
        if ($value$plusargs("trace=%s",tracefile)) trace_fd=$fopen(tracefile,"w");
        for (integer i=0;i<16384;i=i+1) memory.mem[i]=0;
        $readmemh(memfile,memory.mem,0,words-1);
        repeat (3) @(negedge clk);
        rst=0;
        for (integer cycle=0;cycle<50000;cycle=cycle+1) begin
            @(negedge clk);
            if (fault_valid) $fatal(1,"unexpected fault pc=%h cause=%d addr=%h",fault_pc,fault_cause,fault_addr);
            if (retire_valid) begin
                retired=retired+1;
                if (trace_fd!=0) $fdisplay(trace_fd,"%08x %08x %0d %0d %08x %0d %0d %08x %08x %01x",
                    retire_pc,retire_instr,retire_rd_we,retire_rd,retire_rd_data,
                    retire_mem_valid,retire_mem_we,retire_mem_addr,retire_mem_wdata,retire_mem_be);
                if (retire_mem_valid && retire_mem_we && retire_mem_addr==tohost) begin
                    if (retire_mem_wdata!==1) $fatal(1,"tohost fail=%h",retire_mem_wdata);
                    $display("PASS D-core rv32ui retired=%0d cycles=%0d",retired,cycle);
                    $finish;
                end
            end
            if (retire1_valid) begin
                retired=retired+1;
                if (trace_fd!=0) $fdisplay(trace_fd,"%08x %08x %0d %0d %08x %0d %0d %08x %08x %01x",
                    retire1_pc,retire1_instr,retire1_rd_we,retire1_rd,retire1_rd_data,
                    retire1_mem_valid,retire1_mem_we,retire1_mem_addr,retire1_mem_wdata,retire1_mem_be);
                if (retire1_mem_valid && retire1_mem_we && retire1_mem_addr==tohost) begin
                    if (retire1_mem_wdata!==1) $fatal(1,"tohost fail=%h",retire1_mem_wdata);
                    $display("PASS D-core rv32ui retired=%0d cycles=%0d",retired,cycle);
                    $finish;
                end
            end
            prng={prng[30:0],prng[31]^prng[21]^prng[1]^prng[0]};
            external_freeze=inject!=0 && prng[7:0]<26;
            cfg_delay=inject!=0 ? prng[10:8]%4 : 0;
        end
        $fatal(1,"D-core rv32ui timeout");
    end
endmodule
