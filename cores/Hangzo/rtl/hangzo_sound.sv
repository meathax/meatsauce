// SPDX-License-Identifier: GPL-3.0-or-later
// Hangzo physical sound map from MAME0.289 rohga.cpp, pinned chip engines.
// One clk domain throughout. External ROM ready/data acknowledge a held
// request; the accepted reply is retained until the HuC consumer edge.
`timescale 1ns/1ns
module hangzo_sound (
    input wire clk,reset,pause,sample_ce,
    input wire [7:0] command,
    input wire command_write,
    output wire program_request,
    output wire [15:0] program_address,
    input wire [7:0] program_data,
    input wire program_ready,
    output wire [18:0] oki1_address,oki2_address,
    input wire [7:0] oki1_data,oki2_data,
    input wire oki1_ready,oki2_ready,
    output wire signed [15:0] left,right,
    output wire sample,
    output wire [20:0] bus_address,
    output wire [7:0] bus_write_data,bus_read_data,
    output wire bus_read,bus_write,bus_accepted,
    output wire command_pending,command_read,chip_reset_out,
    output wire [4:0] debug_enables
);
    wire ce_huc,ce_ym,ce_oki1,ce_oki2,ce_osc;
    // Clock-driven chips need reset edges while their state pipelines clear.
    // CEs start after outer reset, before the CPU/chip reset hold expires.
    reg [12:0] reset_hold;
    wire chip_reset=reset||!(&reset_hold);
    always @(posedge clk)begin
        if(reset)reset_hold<=0;
        else if(!(&reset_hold))reset_hold<=reset_hold+13'd1;
    end
    assign chip_reset_out=chip_reset;
    hangzo_audio_clocks clocks(.clk(clk),.reset(reset),.run_enable(!pause||chip_reset),
        .ce_osc(ce_osc),.ce_huc(ce_huc),.ce_ym(ce_ym),.ce_oki1(ce_oki1),.ce_oki2(ce_oki2));
    assign debug_enables={ce_oki2,ce_oki1,ce_ym,ce_huc,ce_osc};
    wire rd_n,wr_n,cpu_ce,sx,wait_n;
    wire ym_irq_n,ym_ct1,ym_ct2;
    wire [7:0] ym_data,oki1_status,oki2_status;
    wire rom_select=bus_address[20:16]==5'd0;
    wire ram_select=bus_address[20:13]==8'hf8;
    wire ym_select=bus_address[20:1]==20'h88000;
    wire oki1_select=bus_address[20:1]==20'h90000;
    wire oki2_select=bus_address[20:1]==20'h98000;
    wire latch_select=bus_address==21'h140000;
    assign bus_read=!rd_n;
    assign bus_write=!wr_n;
    assign bus_accepted=cpu_ce&&!chip_reset;
    assign program_address=bus_address[15:0];
    reg reply_valid;
    reg [15:0] reply_address;
    reg [7:0] reply_data;
    wire rom_read=rom_select&&!rd_n;
    wire held_reply=reply_valid&&reply_address==program_address;
    assign program_request=rom_read&&!held_reply&&!chip_reset;
    assign wait_n=!rom_read||held_reply||program_ready;
    always @(posedge clk)begin
        if(chip_reset)reply_valid<=0;
        else if(bus_accepted||!rom_read)reply_valid<=0;
        else if(program_request&&program_ready)begin
            reply_valid<=1;reply_address<=program_address;reply_data<=program_data;
        end
    end
    reg [7:0] work_ram[0:8191];
    reg [7:0] ram_data;
    // Power-up initialization is implemented as a RAM image, not a reset sweep.
    integer n;
    initial for(n=0;n<8192;n=n+1)work_ram[n]=0;
    always @(posedge clk)begin
        ram_data<=work_ram[bus_address[12:0]];
        if(bus_accepted&&ram_select&&!wr_n)work_ram[bus_address[12:0]]<=bus_write_data;
    end
    reg [7:0] latch;
    reg pending;
    assign command_pending=pending;
    assign command_read=bus_accepted&&latch_select&&!rd_n;
    always @(posedge clk)begin
        if(chip_reset)begin pending<=0;latch<=0;end
        else if(command_write)begin latch<=command;pending<=1;end
        else if(command_read)pending<=0;
    end
    assign bus_read_data=ram_select?ram_data:
        ym_select?ym_data:oki1_select?oki1_status:oki2_select?oki2_status:
        latch_select?latch:rom_select?(held_reply?reply_data:program_data):8'hff;
    hangzo_sound_cpu cpu(.clk(clk),.reset(chip_reset),.global_ce(ce_huc),
        .data_in(bus_read_data),.address(bus_address),.data_out(bus_write_data),
        .rd_n(rd_n),.wr_n(wr_n),.sx(sx),.ce(cpu_ce),.irq1_n(!pending),
        .irq2_n(ym_irq_n),.wait_n(wait_n));
    wire signed [15:0] ym_left,ym_right;
    wire signed [13:0] pcm1,pcm2;
    jtikaopm ym(.rst(chip_reset),.clk(clk),.cen(ce_ym),
        .cs_n(!(ym_select&&(!rd_n||!wr_n))),.rd_n(rd_n),.wr_n(wr_n),
        .a0(bus_address[0]),.din(bus_write_data),.dout(ym_data),
        .ct1(ym_ct1),.ct2(ym_ct2),.irq_n(ym_irq_n),.left(ym_left),.right(ym_right));
    wire [17:0] oki1_raw_address,oki2_raw_address;
    // MAME sound_bankswitch_w: bit0 -> OKI1, bit1 -> OKI2.
    assign oki1_address={ym_ct1,oki1_raw_address};
    assign oki2_address={ym_ct2,oki2_raw_address};
    jt6295 #(.INTERPOL(0)) oki1(.rst(chip_reset),.clk(clk),.cen(ce_oki1),.ss(1'b1),
        .wrn(!(oki1_select&&!wr_n)),.din(bus_write_data),.dout(oki1_status),
        .rom_addr(oki1_raw_address),.rom_data(oki1_data),.rom_ok(oki1_ready),.sound(pcm1),.sample());
    jt6295 #(.INTERPOL(0)) oki2(.rst(chip_reset),.clk(clk),.cen(ce_oki2),.ss(1'b1),
        .wrn(!(oki2_select&&!wr_n)),.din(bus_write_data),.dout(oki2_status),
        .rom_addr(oki2_raw_address),.rom_data(oki2_data),.rom_ok(oki2_ready),.sound(pcm2),.sample());
    hangzo_audio_mix mixer(.clk(clk),.reset(chip_reset),.sample_ce(sample_ce&&!pause),
        .ym_left(ym_left),.ym_right(ym_right),.oki1(pcm1),.oki2(pcm2),
        .left(left),.right(right),.sample(sample));
endmodule
