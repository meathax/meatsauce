// SPDX-License-Identifier: GPL-3.0-or-later
// Crystal System GPIO latch with a genuine DS1302 serial slave on pins24/25/28 and the cartridge
// protection PIC16F84A on pins 29 (data) / 30 (reset), as MAME master crystal.cpp.
module vr0_gpio #(
    parameter int SECOND_CYCLES=85909080,
    parameter int COUNTER_BITS=$clog2(SECOND_CYCLES)
) (
    input logic clk,initialize,reset,
    input logic reg_valid,output logic reg_ready,
    input logic [3:0] reg_address,input logic [31:0] reg_data,
    input logic [3:0] reg_strobe,input logic reg_write,
    output logic reg_rsp_valid,output logic [31:0] reg_rsp_data,output logic reg_rsp_error,
    input logic seed_valid,input logic [55:0] seed_bcd,
    input logic restore_valid,input logic [5:0] state_address,
    input logic [7:0] restore_data,output logic [7:0] state_data,
    output logic state_changed,output logic [31:0] latched_output,
    // Protection PIC (Office Yeoin Cheonha): enable and firmware words (MAME image layout, MRA index 3).
    input logic pic_enable,pic_load_we,input logic [13:0] pic_load_address,input logic [15:0] pic_load_data
);
    logic [COUNTER_BITS-1:0] second_counter;
    logic second_tick,seconds_written,rtc_read,rtc_output,rtc_enable;
    logic [31:0] mask,pins;
    always_comb begin
        reg_ready=1;
        mask={{8{reg_strobe[3]}},{8{reg_strobe[2]}},{8{reg_strobe[1]}},{8{reg_strobe[0]}}};
        pins=latched_output;
        if(reg_valid && reg_write && reg_address==4) pins=(latched_output&~mask)|(reg_data&mask);
        second_tick=second_counter==COUNTER_BITS'(SECOND_CYCLES-1);
    end
    ds1302 rtc (.clk,.initialize,.reset,.ce(pins[24]),.serial_clock(pins[25]),.io_input(pins[28]),
        .io_output(rtc_output),.io_enable(rtc_enable),.io_read(rtc_read),.second_tick,
        .seed_valid,.seed_bcd,.restore_valid,.state_address,.restore_data,.state_data,
        .seconds_written,.state_changed);
    // The game sends a challenge and receives code words plus a 32-byte answer over a 9600-baud software
    // UART on bit 29. Without the answer its timer interrupt overwrites eight pseudo-random RAM words every
    // ~80 frames and several routines spin forever (random freezes); MAME 0.289 only patches the code words.
    // PIC instruction cycle = 3.579545 MHz / 4 = clk_sys (85.90908 MHz) / 96.
    logic pic_data,pic_port_write;
    logic [7:0] pic_port_value,pic_port_mask;
    logic [6:0] pic_divider;
    wire pic_cycle=pic_divider==7'd95;
    always_ff @(posedge clk) pic_divider<=reset || pic_cycle ? 7'd0 : pic_divider+7'd1;
    crystal_pic16 pic (.clk,.rst_n(!reset),.model_628(1'b0),.hold(!pic_enable || latched_output[30]),.cyc(pic_cycle),
        .porta_in({7'd0,pic_data}),.porta_we(pic_port_write),.porta_val(pic_port_value),.porta_mask(pic_port_mask),
        .ld_we(pic_load_we),.ld_addr(pic_load_address),.ld_data(pic_load_data),
        .dbg_pc(),.dbg_w(),.dbg_status(),.dbg_retire(),.dbg_count());
    always_ff @(posedge clk) begin
        if(initialize || seconds_written) second_counter<=0;
        else second_counter<=second_tick ? '0:second_counter+1'b1;
        if(reset) begin latched_output<=0;reg_rsp_valid<=0;reg_rsp_data<=0;reg_rsp_error<=0;pic_data<=1;end
        else begin
            reg_rsp_valid<=reg_valid;
            if(reg_valid) begin
                reg_rsp_error<=reg_address!=4 && reg_address!=8;
                // bit29: PIC data line (pull-up). Without a PIC it is the inverted CPU-driven bit29 (MAME master).
                reg_rsp_data<=reg_address==4 ? latched_output:{2'b0,pic_enable ? pic_data : ~latched_output[29],rtc_read,28'b0};
                if(reg_write && reg_address==4) latched_output<=pins;
            end
            // MAME master pioldat_w/pic_porta_w: every PIO latch write sets the line to !bit29; a PIC port A
            // write with RA0 as an output drives it.
            if(reg_valid && reg_write && reg_address==4) pic_data<=!pins[29];
            if(pic_enable && pic_port_write && pic_port_mask[0]) pic_data<=pic_port_value[0];
        end
    end
endmodule
