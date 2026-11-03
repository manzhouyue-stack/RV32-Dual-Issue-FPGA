`timescale 1ns/1ps
module tb_b_directed;
    localparam [31:0] BASE = 0;
    logic clk=0, rst=1;
    always #5 clk=~clk;
    `include "b_core_ports.svh"
    integer test_case=0, end_pc=0, expected_cause=-1;
    logic [31:0] expected_fault_pc=0, expected_fault_addr=0;
    logic [31:0] values[0:31];
    bit seen[0:31];
    integer freeze_left=0, block_left=0, if_hold=0;
    integer ld_requests=0, st_requests=0, st_completions=0;
    integer frozen_ld_responses=0, frozen_st_responses=0, frozen_if_responses=0;
    integer held_redirects=0, held_fences=0, fetch24=0, retired=0;
    integer before_ld, before_st;
    string wavefile;
    bit first_ld=0, first_st=0, if_hold_done=0;

    function automatic [31:0] addi(input [4:0] rd,rs1,input integer imm);
        addi={imm[11:0],rs1,3'b000,rd,7'b0010011};
    endfunction
    function automatic [31:0] load(input [4:0] rd,rs1,input integer imm,input [2:0] kind);
        load={imm[11:0],rs1,kind,rd,7'b0000011};
    endfunction
    function automatic [31:0] store(input [4:0] rs2,rs1,input integer imm,input [2:0] kind);
        store={imm[11:5],rs2,rs1,kind,imm[4:0],7'b0100011};
    endfunction
    function automatic [31:0] jal(input [4:0] rd,input integer imm);
        jal={imm[20],imm[10:1],imm[11],imm[19:12],rd,7'b1101111};
    endfunction
    task automatic expect_register(input integer rd,input [31:0] expected);
        if (!seen[rd] || values[rd] !== expected)
            $fatal(1,"case %0d x%0d expected=%h got=%h seen=%b",test_case,rd,expected,values[rd],seen[rd]);
    endtask
    task automatic finish_success;
        if (test_case==0) begin
            expect_register(3,32'hffffff80);
            expect_register(4,32'h80);
            expect_register(6,32'hfeef);
            expect_register(7,32'hfffffeef);
            expect_register(8,32'h80);
            expect_register(9,3);
            if (ram_writes!=3 || ld_count!=5 || st_count!=3 || memory.mem[8192]!==32'hfeef8000)
                $fatal(1,"subword memory effects wrong");
        end
        if (test_case==1) begin
            expect_register(2,32'h40);
            expect_register(3,32'h41);
            expect_register(4,2);
            if (uart_pops!=2 || uart_writes!=1 || ld_count!=3 || st_count!=1 ||
                frozen_ld_responses==0 || frozen_st_responses==0 || frozen_if_responses==0)
                $fatal(1,"MMIO count/frozen response coverage pops=%0d tx=%0d ldresp=%0d stresp=%0d",
                    uart_pops,uart_writes,frozen_ld_responses,frozen_st_responses);
        end
        if (test_case==2) begin
            expect_register(5,9);
            if (held_redirects==0) $fatal(1,"missing redirect while IF is unaccepted");
        end
        if (test_case==3) begin
            expect_register(10,7);
            if (ram_writes!=1 || held_fences==0 || fetch24<2) $fatal(1,"missing FENCE.I pending drain/refetch");
        end
        if (test_case==14 && (ram_writes!=1 || uart_pops!=1 || st_completions!=1))
            $fatal(1,"FENCE order effects wrong");
        if (test_case==15 && (ram_writes!=1 || !seen[2])) $fatal(1,"younger IF fault lost older Store");
        if (test_case==18) begin
            expect_register(5,9);
            if (uart_pops!=0 || uart_writes!=0 || ld_count!=0 || st_count!=0)
                $fatal(1,"branch leaked wrong-path MMIO request");
        end
        $display("PASS B-directed case=%0d retired=%0d requests=%0d/%0d/%0d",test_case,retired,if_count,ld_count,st_count);
        $finish;
    endtask

    initial begin
        if (!$value$plusargs("case=%d",test_case)) test_case=0;
        if ($value$plusargs("vcd=%s",wavefile)) begin $dumpfile(wavefile);$dumpvars(0,tb_b_directed);end
        for (integer i=0;i<16384;i=i+1) memory.mem[i]=32'h00000013;
        for (integer i=0;i<32;i=i+1) begin seen[i]=0;values[i]=0;end
        memory.mem[8192]=32'h11223344;
        // Common fault prefix: x1=DTCM; faulting instruction at PC 4.
        memory.mem[0]=32'h000100b7;
        memory.mem[1]=load(5,1,0,2);
        memory.mem[2]=32'h10000137;
        memory.mem[3]=load(6,2,0,2);
        end_pc=16;
        cfg_delay=3;
        case (test_case)
            0: begin
                cfg_delay=0;
                memory.mem[1]=addi(2,0,128);
                memory.mem[2]=store(2,1,1,0);
                memory.mem[3]=load(3,1,1,0);
                memory.mem[4]=load(4,1,1,4);
                memory.mem[5]=addi(5,0,-273);
                memory.mem[6]=store(5,1,2,1);
                memory.mem[7]=load(6,1,2,5);
                memory.mem[8]=load(7,1,2,1);
                memory.mem[9]=store(4,1,4,2);
                memory.mem[10]=load(8,1,4,2);
                memory.mem[11]=addi(0,0,123);
                memory.mem[12]=addi(9,0,3);
                memory.mem[8192]=0;
                end_pc=52;
            end
            1: begin
                memory.mem[0]=32'h100000b7;
                memory.mem[1]=load(2,1,0,2);
                memory.mem[2]=load(3,1,0,2);
                memory.mem[3]=store(2,1,0,2);
                memory.mem[4]=32'h0ff0000f;
                memory.mem[5]=load(4,1,4,2);
                end_pc=24;
            end
            2: begin
                memory.mem[0]=jal(0,16);
                memory.mem[1]=32'hffffffff;
                memory.mem[4]=addi(5,0,9);
                cfg_if_error_addr=4;
                end_pc=20;
            end
            3: begin
                memory.mem[0]=32'h00000097;
                memory.mem[1]=addi(1,1,24);
                memory.mem[2]=32'h00700137;
                memory.mem[3]=addi(2,2,32'h513);
                memory.mem[4]=store(2,1,0,2);
                memory.mem[5]=32'h0000100f;
                memory.mem[6]=addi(10,0,3);
                cfg_delay=4;
                end_pc=28;
            end
            4: begin cfg_ld_error_addr=32'h10000;expected_cause=5;expected_fault_pc=4;expected_fault_addr=32'h10000;end
            5: begin
                memory.mem[1]=addi(2,0,8);
                memory.mem[2]=store(2,1,0,2);
                memory.mem[3]=32'h10000137;
                memory.mem[4]=load(6,2,0,2);
                cfg_st_error_addr=32'h10000;
                expected_cause=7;expected_fault_pc=8;expected_fault_addr=32'h10000;
            end
            6: begin memory.mem[1]=load(5,1,1,1);expected_cause=4;expected_fault_pc=4;expected_fault_addr=32'h10001;end
            7: begin memory.mem[1]=store(0,1,2,2);expected_cause=6;expected_fault_pc=4;expected_fault_addr=32'h10002;end
            8: begin memory.mem[0]=32'h100000b7;memory.mem[1]=store(0,1,0,0);expected_cause=7;expected_fault_pc=4;expected_fault_addr=32'h10000000;end
            9: begin memory.mem[0]=32'h100000b7;memory.mem[1]=load(5,1,0,0);expected_cause=5;expected_fault_pc=4;expected_fault_addr=32'h10000000;end
            10: begin memory.mem[0]=jal(1,2);expected_cause=0;expected_fault_pc=0;expected_fault_addr=2;end
            11: begin memory.mem[0]=addi(5,0,1);cfg_if_error_addr=4;expected_cause=1;expected_fault_pc=4;expected_fault_addr=4;end
            12: begin memory.mem[0]=addi(5,0,1);memory.mem[1]=32'hffffffff;expected_cause=2;expected_fault_pc=4;expected_fault_addr=32'hffffffff;end
            13: begin
                memory.mem[0]=addi(1,0,32'h20);
                memory.mem[1]=addi(2,0,3);
                memory.mem[2]=store(2,1,0,2);
                cfg_boot_write=0;expected_cause=7;expected_fault_pc=8;expected_fault_addr=32'h20;
            end
            14: begin
                memory.mem[1]=addi(5,0,9);
                memory.mem[2]=store(5,1,0,2);
                memory.mem[3]=32'h0ff0000f;
                memory.mem[4]=32'h10000137;
                memory.mem[5]=load(3,2,0,2);
                end_pc=24;cfg_delay=5;
            end
            15: begin
                memory.mem[1]=addi(2,0,9);
                memory.mem[2]=store(2,1,0,2);
                cfg_if_error_addr=12;cfg_delay=5;
                expected_cause=1;expected_fault_pc=12;expected_fault_addr=12;
            end
            16: begin
                memory.mem[1]=32'h00008067; // jalr x0,0(x1): DTCM cannot execute
                expected_cause=1;expected_fault_pc=32'h10000;expected_fault_addr=32'h10000;
            end
            17: begin
                memory.mem[0]=32'h100000b7;memory.mem[1]=load(5,1,16,2);
                expected_cause=5;expected_fault_pc=4;expected_fault_addr=32'h10000010;
            end
            18: begin
                memory.mem[0]=32'h100000b7;
                memory.mem[1]=32'h00000663; // beq x0,x0,+12
                memory.mem[2]=load(2,1,0,2);
                memory.mem[3]=store(0,1,0,2);
                memory.mem[4]=addi(5,0,9);
                end_pc=20;
            end
            19: begin
                memory.mem[0]=addi(1,0,3);
                memory.mem[1]=32'h000082e7; // jalr x5,0(x1), bit0 clears but bit1 remains
                expected_cause=0;expected_fault_pc=4;expected_fault_addr=2;
            end
            default: $fatal(1,"unknown case");
        endcase
        if (expected_cause<0) memory.mem[end_pc>>2]=jal(0,0);
        repeat (3) @(negedge clk);
        rst=0;
        for (integer cycle=0;cycle<2000;cycle=cycle+1) begin
            @(negedge clk);
            if (retire_valid) begin
                retired=retired+1;
                if (expected_cause>=0 && retire_pc>=expected_fault_pc) $fatal(1,"fault/young instruction retired");
                if (test_case==2 && retire_pc!=0 && retire_pc!=16 && retire_pc!=20) $fatal(1,"wrong path retired");
                if (retire_rd_we) begin values[retire_rd]=retire_rd_data;seen[retire_rd]=1;end
                if (retire_pc==end_pc && expected_cause<0) finish_success();
            end
            if (fault_valid) begin
                if (expected_cause<0 || fault_cause!==expected_cause || fault_pc!==expected_fault_pc || fault_addr!==expected_fault_addr)
                    $fatal(1,"fault mismatch case=%0d cause=%d pc=%h addr=%h",test_case,fault_cause,fault_pc,fault_addr);
                if (uart_pops!=0 || uart_writes!=0) $fatal(1,"fault leaked younger MMIO effect");
                if (test_case>=6 && test_case<=10 && (ld_count!=0 || st_count!=0)) $fatal(1,"local fault issued bus transaction");
                if ((test_case==5 || test_case==13) && (ram_writes!=0 || st_count!=1)) $fatal(1,"failed Store replayed/wrote");
                if (test_case==4 && (ld_count!=1 || seen[5])) $fatal(1,"failed Load replayed/wrote register");
                before_ld=ld_count;before_st=st_count;
                repeat (12) begin
                    @(negedge clk);
                    if (!fault_valid || retire_valid || ld_count!=before_ld || st_count!=before_st)
                        $fatal(1,"fault not sticky or side effects repeated");
                end
                finish_success();
            end

            if (test_case==1) begin
                if (freeze_left>0) freeze_left=freeze_left-1;
                if (block_left>0) block_left=block_left-1;
                if (ld_valid && !first_ld) begin first_ld=1;freeze_left=12;block_left=3;end
                if (st_valid && !first_st) begin first_st=1;freeze_left=12;block_left=3;end
                external_freeze=freeze_left>0;
                cfg_ld_block=block_left>0;
                cfg_st_block=block_left>0;
            end
            if (test_case==2) begin
                if (if_valid && if_addr==4 && !if_hold_done) begin if_hold_done=1;if_hold=5;end
                cfg_if_block=if_hold>0;
                if (if_hold>0) if_hold=if_hold-1;
            end
            if (test_case==3) begin
                if (if_valid && if_addr==24 && !if_hold_done) cfg_if_block=1;
                if (held_fences>0) begin cfg_if_block=0;if_hold_done=1;end
            end
        end
        $fatal(1,"directed timeout case=%0d",test_case);
    end

    always @(posedge clk) if (!rst) begin
        if (ld_valid && ld_ready) ld_requests=ld_requests+1;
        if (st_valid && st_ready) st_requests=st_requests+1;
        if (st_done) st_completions=st_completions+1;
        if (ld_rvalid && external_freeze) frozen_ld_responses=frozen_ld_responses+1;
        if (st_done && external_freeze) frozen_st_responses=frozen_st_responses+1;
        if (if_rvalid && external_freeze) frozen_if_responses=frozen_if_responses+1;
        if (if_valid && !if_ready && dut.ex_redirect) held_redirects=held_redirects+1;
        if (if_valid && !if_ready && dut.mem_redirect) held_fences=held_fences+1;
        if (if_valid && if_ready && if_addr==24) fetch24=fetch24+1;
        if (test_case==14 && ld_valid && ld_ready && ld_addr==32'h10000000 && st_completions!=1)
            $fatal(1,"FENCE allowed I/O before older Store completion");
    end
endmodule
