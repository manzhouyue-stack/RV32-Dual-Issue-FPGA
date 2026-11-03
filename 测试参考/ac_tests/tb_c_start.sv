`timescale 1ns/1ps
// Protocol RAM plus register/8N1 UART model, not B's actual subsystem/IP.
module tb_c_start;
    localparam integer BIT_CYCLES=434;
    logic clk=0, rst=1;
    always #10 clk=~clk; // 50 MHz
    logic external_freeze=0;
    logic if_valid,if_ready,if_rvalid,if_error;
    logic [31:0] if_addr,if_rdata;
    logic ld_valid,ld_ready,ld_rvalid,ld_error;
    logic [31:0] ld_addr,ld_rdata;
    logic [1:0] ld_size;
    logic st_valid,st_ready,st_done,st_error;
    logic [31:0] st_addr,st_wdata;
    logic [1:0] st_size;
    logic [3:0] st_wstrb;
    logic retire_valid,retire_rd_we,retire_mem_valid,retire_mem_we;
    logic [31:0] retire_pc,retire_instr,retire_rd_data,retire_mem_addr,retire_mem_wdata;
    logic [4:0] retire_rd,debug_valid;
    logic [3:0] retire_mem_be,fault_cause;
    logic fault_valid;
    logic [31:0] fault_pc,fault_instr,fault_addr;
    logic ram_ld_ready,ram_ld_rvalid,ram_ld_error,ram_st_ready,ram_st_done,ram_st_error;
    logic [31:0] ram_ld_rdata;
    logic io_ld_rvalid,io_ld_error,io_st_done,io_st_error;
    logic [31:0] io_ld_rdata,ctrl=0,baud=618475,led=0,result=0;
    logic result_valid=0,tx_busy=0;
    logic [9:0] tx_frame;
    integer tx_bit=0,tx_timer=0,tx_accepted=0,tx_completed=0;
    wire uart_tx=tx_busy ? tx_frame[tx_bit] : 1'b1;
    wire io_load=ld_addr[31:28]==4'h1;
    wire io_store=st_addr[31:28]==4'h1;
    integer unused_if,unused_ld,unused_st,unused_ram,unused_rx,unused_tx;
    integer decoded=0,total_decoded=0,round=0,retired=0;
    logic [7:0] expected[0:11];
    string itcm_file;
    logic [31:0] data_word_addr,bss_word_addr;
    logic [31:0] data_load_addr;
    integer negative=0, expected_fail=0;
    rv32_core_b #(.RESET_PC(0)) dut(.*);
    b_protocol_memory #(.BASE(0)) memory(
        .clk(clk),.rst(rst),.if_valid(if_valid),.if_addr(if_addr),.if_ready(if_ready),
        .if_rvalid(if_rvalid),.if_rdata(if_rdata),.if_error(if_error),
        .ld_valid(ld_valid && !io_load),.ld_addr(ld_addr),.ld_size(ld_size),
        .ld_ready(ram_ld_ready),.ld_rvalid(ram_ld_rvalid),.ld_rdata(ram_ld_rdata),.ld_error(ram_ld_error),
        .st_valid(st_valid && !io_store),.st_addr(st_addr),.st_size(st_size),
        .st_wdata(st_wdata),.st_wstrb(st_wstrb),.st_ready(ram_st_ready),.st_done(ram_st_done),.st_error(ram_st_error),
        .cfg_if_block(1'b0),.cfg_ld_block(1'b0),.cfg_st_block(1'b0),.cfg_boot_write(1'b0),
        .cfg_if_error_addr(32'hffffffff),.cfg_ld_error_addr(32'hffffffff),.cfg_st_error_addr(32'hffffffff),
        .cfg_delay(0),.inject(0),.if_count(unused_if),.ld_count(unused_ld),.st_count(unused_st),
        .ram_writes(unused_ram),.uart_pops(unused_rx),.uart_writes(unused_tx));
    assign ld_ready=io_load ? 1'b1 : ram_ld_ready;
    assign st_ready=io_store ? 1'b1 : ram_st_ready;
    assign ld_rvalid=io_ld_rvalid || ram_ld_rvalid;
    assign ld_rdata=io_ld_rvalid ? io_ld_rdata : ram_ld_rdata;
    assign ld_error=io_ld_rvalid ? io_ld_error : ram_ld_error;
    assign st_done=io_st_done || ram_st_done;
    assign st_error=io_st_done ? io_st_error : ram_st_error;

    always @(posedge clk) begin
        if (rst) begin
            io_ld_rvalid<=0;io_ld_error<=0;io_st_done<=0;io_st_error<=0;
            ctrl<=0;baud<=618475;led<=0;result<=0;result_valid<=0;
            tx_busy<=0;tx_bit<=0;tx_timer<=0;tx_accepted<=0;tx_completed<=0;
        end else begin
            io_ld_rvalid<=0;io_st_done<=0;result_valid<=0;
            if (tx_busy) begin
                if (tx_timer==1) begin
                    if (tx_bit==9) begin tx_busy<=0;tx_completed<=tx_completed+1;end
                    else begin tx_bit<=tx_bit+1;tx_timer<=BIT_CYCLES;end
                end else tx_timer<=tx_timer-1;
            end
            if (ld_valid && ld_ready && io_load) begin
                io_ld_rvalid<=1;io_ld_error<=0;
                if (ld_size!=2 || ld_addr[1:0]!=0) io_ld_error<=1;
                case(ld_addr)
                    32'h10000000:io_ld_rdata<=32'h80000000;
                    32'h10000004:io_ld_rdata<=tx_busy ? (negative==3 ? 3 : 1) : 2;
                    32'h10000008:io_ld_rdata<=ctrl;
                    32'h1000000c:io_ld_rdata<=negative==2 ? baud ^ 1 : baud;
                    32'h10001000:io_ld_rdata<=led;
                    32'h10002000:io_ld_rdata<=result;
                    default:begin io_ld_error<=1;io_ld_rdata<=0;end
                endcase
            end
            if (st_valid && st_ready && io_store) begin
                io_st_done<=1;io_st_error<=0;
                if (st_size!=2 || st_wstrb!=15 || st_addr[1:0]!=0) $fatal(1,"bad MMIO format");
                case(st_addr)
                    32'h10000000:begin
                        if (!ctrl[0] || tx_busy) $fatal(1,"UART write while disabled/full");
                        tx_frame<={1'b1,st_wdata[7:0],1'b0};
                        tx_busy<=1;tx_bit<=0;tx_timer<=BIT_CYCLES;tx_accepted<=tx_accepted+1;
                    end
                    32'h10000008:ctrl<=st_wdata & 3;
                    32'h1000000c:begin
                        if (ctrl!=0 || tx_busy || st_wdata!=618475) $fatal(1,"bad BAUD sequence");
                        baud<=st_wdata;
                    end
                    32'h10001000:led<=st_wdata & 255;
                    32'h10002000:begin
                        if (st_wdata==0 || !st_wdata[0]) $fatal(1,"bad RESULT code");
                        if (st_wdata==1 && (tx_busy || tx_completed!=12 || decoded!=12))
                            $fatal(1,"PASS before serial transmission completed");
                        result<=st_wdata;result_valid<=1;
                    end
                    default:io_st_error<=1;
                endcase
            end
        end
    end

    // Negative peripheral-model defects: overwrite a neighbouring lane that
    // was NOT enabled. The firmware must detect these and report FAIL 25.
    always @(posedge clk) if (!rst && st_valid && st_ready && !io_store &&
        st_addr>=32'h10000 && st_addr<32'h18000) begin
        if (negative==4 && st_size==0 && st_wstrb==4'b0010)
            memory.mem[8192+((st_addr-32'h10000)>>2)][7:0] <= 0;
        if (negative==5 && st_size==1 && st_wstrb==4'b1100)
            memory.mem[8192+((st_addr-32'h10000)>>2)][15:0] <= 0;
    end

    initial begin : serial_monitor
        logic [7:0] byte_value;
        forever begin
            @(negedge uart_tx);
            if (!rst) begin
                repeat(BIT_CYCLES/2) @(negedge clk);
                if (uart_tx!==0) $fatal(1,"bad UART start bit");
                for(integer b=0;b<8;b=b+1) begin
                    repeat(BIT_CYCLES) @(negedge clk);
                    byte_value[b]=uart_tx;
                end
                repeat(BIT_CYCLES) @(negedge clk);
                if (uart_tx!==1) $fatal(1,"bad UART stop bit");
                if (decoded>=12 || byte_value!==expected[decoded])
                    $fatal(1,"serial mismatch round=%0d byte=%0d got=%h",round,decoded,byte_value);
                decoded=decoded+1;total_decoded=total_decoded+1;
            end
        end
    end

    initial begin : run_program
        if (!$value$plusargs("itcm=%s",itcm_file)) $fatal(1,"missing itcm image");
        if (!$value$plusargs("dataword=%h",data_word_addr)) $fatal(1,"missing data symbol");
        if (!$value$plusargs("bssword=%h",bss_word_addr)) $fatal(1,"missing bss symbol");
        if (!$value$plusargs("datalma=%h",data_load_addr)) $fatal(1,"missing data LMA");
        if (!$value$plusargs("negative=%d",negative)) negative=0;
        if (negative==1) expected_fail=3;
        if (negative==2) expected_fail=15;
        if (negative==4 || negative==5) expected_fail=25;
        expected[0]="C";expected[1]=" ";expected[2]="S";expected[3]="T";
        expected[4]="A";expected[5]="R";expected[6]="T";expected[7]=" ";
        expected[8]="O";expected[9]="K";expected[10]=13;expected[11]=10;
        $readmemh(itcm_file,memory.mem,0,8191);
        if (negative==1) memory.mem[data_load_addr>>2]=memory.mem[data_load_addr>>2] ^ 1;
        for(integer i=8192;i<16384;i=i+1) memory.mem[i]=32'hbeefcafe;
        for(round=1;round<=2;round=round+1) begin
            rst=1;decoded=0;retired=0;
            repeat(8) @(negedge clk);
            rst=0;
            begin : watchdog
                for(integer cycle=0;cycle<10000000;cycle=cycle+1) begin
                    @(negedge clk);
                    if (fault_valid) $fatal(1,"CPU fault pc=%h instr=%h cause=%d addr=%h",fault_pc,fault_instr,fault_cause,fault_addr);
                    if (retire_valid) retired=retired+1;
                    if (result_valid) begin
                        if (expected_fail!=0) begin
                            if (result!==expected_fail || decoded!=0 || tx_accepted!=0)
                                $fatal(1,"negative did not select expected failure code=%0d got=%h",expected_fail,result);
                            repeat(20) begin
                                @(negedge clk);
                                if (fault_valid || result==1 || tx_accepted!=0)
                                    $fatal(1,"negative escaped FAIL path");
                            end
                            $display("PASS negative=%0d expected firmware FAIL=%0d",negative,expected_fail);
                            $finish;
                        end
                        if (result!==1) $fatal(1,"software FAIL code=%h",result);
                        if (decoded!=12 || tx_completed!=12 || tx_accepted!=12) $fatal(1,"wrong UART counts");
                        if (memory.mem[8192+((data_word_addr-32'h10000)>>2)]!==32'hdeadc0de ||
                            memory.mem[8192+((bss_word_addr-32'h10000)>>2)]!==32'ha5a5a5a5)
                            $fatal(1,"software did not dirty startup variables");
                        $display("PASS C startup round=%0d UART=C START OK+CRLF bytes=12 cycles=%0d retired=%0d",round,cycle,retired);
                        disable watchdog;
                    end
                end
                $fatal(1,"C startup timeout round=%0d",round);
            end
            repeat(20) @(negedge clk);
        end
        if (total_decoded!=24) $fatal(1,"two-reset byte count wrong");
        $display("PASS C startup: two resets, retained dirty RAM, data/BSS/stack/calls, serial complete before PASS");
        $finish;
    end
endmodule
