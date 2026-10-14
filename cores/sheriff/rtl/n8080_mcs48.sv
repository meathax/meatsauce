// SPDX-License-Identifier: GPL-2.0-or-later
// Open Sheriff 8035 wrapper around the BSD T48 kernel. No DK wrapper code.
// Pin mapping/74123 equations: MAME 0.289 n8080_a.cpp, BSD-3-Clause.
module n8080_mcs48 (
    input wire clk, reset, pause,
    input wire [7:0] sound1, sound2,
    input wire load_wr,
    input wire [9:0] load_addr,
    input wire [7:0] load_data,
    output wire dac_bit,
    output wire [7:0] p1_out, p2_out,
    output wire [11:0] program_address,
    output wire [7:0] program_data,
    output wire irq_n,
    output wire [12:0] pins,
    output wire mono0, mono1,
    output wire ce_crystal, ce_state,
    output wire [7:0] ram_address,
    output wire ram_write,
    output wire [7:0] ram_dout,
    output wire sn_enable, sn_vco_mode, sn_mixer_b, sn_vco_5v
);
    reg [7:0] rom[0:1023];
    reg [7:0] ram[0:63];
    integer i;
    initial begin
        for(i=0;i<1024;i=i+1) rom[i]=0;
        for(i=0;i<64;i=i+1) ram[i]=0;
    end
    reg [7:0] rom_q, ram_q;
    assign program_data=rom_q;
    always @(posedge clk) begin
        rom_q<=rom[program_address[9:0]];
        ram_q<=ram[ram_address[5:0]];
        if(load_wr) rom[load_addr]<=load_data;
        if(!pause && ram_write) ram[ram_address[5:0]]<=ram_dout;
    end
    // One master domain, 6 MHz crystal enables. T48 then divides by 3 and
    // five clock states to reach the actual 400 kHz machine-cycle rate.
    reg [5:0] accumulator=0;
    assign ce_crystal=!pause && accumulator>=37;
    always @(posedge clk) begin
        if(reset) accumulator<=0;
        else if(!pause) accumulator<=ce_crystal ? accumulator-6'd37 : accumulator+6'd5;
    end
    assign pins={~sound2[5],~sound2[3],~sound2[2],~sound2[1],~sound2[0],
                 ~sound1[0],~sound1[2],~sound1[1],~sound1[4],~sound1[3],
                 ~sound2[4],~sound1[5],1'b0};
    assign irq_n=pins[2] && pins[3] && pins[5];
    wire [7:0] p1_input={pins[1],pins[2],pins[3],pins[5],pins[8],pins[9],pins[10],pins[11]} & p1_out;
    t48_core kernel (
        .xtal_i(clk), .xtal_en_i(ce_crystal), .reset_i(!reset),
        .t0_i(pins[7]), .t0_o(), .t0_dir_o(), .int_n_i(irq_n),
        .ea_i(1'b1), .rd_n_o(), .psen_n_o(), .wr_n_o(), .ale_o(),
        .db_i(rom_q), .db_o(), .db_dir_o(),
        .t1_i(pins[12]), .p2_i(p2_out), .p2_o(p2_out),
        .p2l_low_imp_o(), .p2h_low_imp_o(),
        .p1_i(p1_input), .p1_o(p1_out), .p1_low_imp_o(), .prog_n_o(),
        .clk_i(clk), .en_clk_i(ce_state), .xtal3_o(ce_state),
        .dmem_addr_o(ram_address), .dmem_we_o(ram_write),
        .dmem_data_i(ram_q), .dmem_data_o(ram_dout),
        .pmem_addr_o(program_address), .pmem_data_i(rom_q)
    );
    assign dac_bit=p2_out[7];
    reg [12:0] previous_pins=13'h1ffe;
    reg [24:0] duration0=0, duration1=0;
    localparam [24:0] MONO_TICKS=25'd30187080; // 550*33*33 us at 50.4 MHz
    assign mono0=duration0!=0;
    assign mono1=duration1!=0;
    assign sn_enable=mono0||mono1;
    assign sn_vco_mode=mono0;
    assign sn_mixer_b=!mono0;
    assign sn_vco_5v=mono1;
    always @(posedge clk) begin
        if(reset) begin previous_pins<=pins; duration0<=0; duration1<=0; end
        else if(!pause) begin
            previous_pins<=pins;
            if(duration0!=0) duration0<=duration0-1'b1;
            if(duration1!=0) duration1<=duration1-1'b1;
            if(previous_pins[6] && !pins[6]) begin duration0<=MONO_TICKS; duration1<=0; end
            if(previous_pins[4] && !pins[4]) duration1<=MONO_TICKS;
        end
    end
endmodule
