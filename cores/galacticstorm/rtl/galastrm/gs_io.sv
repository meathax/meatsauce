// SPDX-License-Identifier: GPL-3.0-or-later
// Galastrm TC0510NIO, ADC0809 and EEPROM wiring.
// Register behavior from BSD-3-Clause MAME 0.289 taitoio.cpp (Nicola Salmoria)
// and adc0808.cpp (Dirk Best). EEPROM uses the separately preserved F3 donor.
module gs_io #(
    parameter integer SYS_HZ = 32_000_000,
    parameter integer ADC_HZ = 500_000
)(
    input logic clk, reset, pause,
    input logic cpu_req, cpu_write,
    input logic [23:0] cpu_addr,
    input logic [1:0] cpu_be,
    input logic [15:0] cpu_wdata,
    output logic cpu_ack,
    output logic [15:0] cpu_rdata,
    input logic [7:0] in0, in2,
    input logic [7:0] stick_x, stick_y,
    input logic vblank, iack5,
    output wire [2:0] irq_n,
    output logic frame_counter,
    output logic watchdog_kick,
    output wire [3:0] coin_control,
    input logic nvram_ld_wr,
    input logic [5:0] nvram_ld_addr,
    input logic [15:0] nvram_ld_data,
    input logic [5:0] nvram_sv_addr,
    output wire [15:0] nvram_sv_data,
    output wire nvram_dirty
);
    // The intermediate product exceeds signed 32-bit range at 64 MHz.
    localparam integer CONVERSION_TICKS = int'((64'd66*SYS_HZ)/ADC_HZ);
    localparam integer TIMER_BITS = $clog2(CONVERSION_TICKS+1);
    logic [7:0] nio_reg [0:7];
    logic irq5, irq6;
    logic [TIMER_BITS-1:0] adc_timer;
    logic [2:0] adc_channel;
    logic [7:0] adc_result;
    wire nio_sel = cpu_addr[23:3] == (24'h400000 >> 3);
    wire adc_sel = cpu_addr[23:3] == (24'h500000 >> 3);
    wire [2:0] nio_even = {cpu_addr[2:1],1'b0};
    wire eeprom_do;

    rf_eeprom_93c46 eeprom (
        .clk(clk), .reset(reset), .cs(nio_reg[3][4]),
        .sk(nio_reg[3][5]), .di(nio_reg[3][6]), .do_out(eeprom_do),
        .ld_wr(nvram_ld_wr), .ld_addr(nvram_ld_addr), .ld_data(nvram_ld_data),
        .sv_addr(nvram_sv_addr), .sv_data(nvram_sv_data), .wrote(nvram_dirty)
    );
    assign coin_control = nio_reg[4][3:0];
    assign irq_n = irq6 ? 3'b001 : irq5 ? 3'b010 : 3'b111;

    function automatic [7:0] nio_read(input [2:0] port_index);
        case (port_index)
            0,1: nio_read = 8'h00; // unbound MAME input callbacks default to zero
            2: nio_read = {in0[7:2],frame_counter,in0[0]};
            3: nio_read = {eeprom_do,6'b111111,1'b0};
            4: nio_read = nio_reg[4];
            7: nio_read = in2;
            default: nio_read = 8'hff;
        endcase
    endfunction

    integer port_index;
    always_ff @(posedge clk) begin
        cpu_ack <= 1'b0;
        watchdog_kick <= 1'b0;
        if (reset) begin
            for (port_index=0;port_index<8;port_index=port_index+1) nio_reg[port_index]<=0;
            cpu_rdata <= 0;
            frame_counter <= 0;
            irq5 <= 0;
            irq6 <= 0;
            adc_timer <= 0;
            adc_channel <= 0;
            adc_result <= 0;
        end else begin
            if (iack5) irq5 <= 0;
            if (!pause && vblank) begin
                frame_counter <= ~frame_counter;
                irq5 <= 1;
            end
            // Finish requests that were already issued when pause began.
            if (cpu_req && !cpu_ack && (nio_sel || adc_sel)) begin
                cpu_ack <= 1;
                if (nio_sel) begin
                    if (cpu_write) begin
                        if (cpu_be[1]) nio_reg[nio_even] <= cpu_wdata[15:8];
                        if (cpu_be[0]) nio_reg[nio_even+3'd1] <= cpu_wdata[7:0];
                        if (nio_even==0 && cpu_be[1]) watchdog_kick <= 1;
                    end else cpu_rdata <= {nio_read(nio_even),nio_read(nio_even+3'd1)};
                end else begin
                    if (cpu_write && |cpu_be) begin
                        // The byte-addressed ADC map selects a channel on each
                        // active lane; a word write ends at the low-byte channel.
                        adc_channel <= cpu_be[0] ? nio_even+3'd1 : nio_even;
                        adc_timer <= TIMER_BITS'(CONVERSION_TICKS);
                    end else if (!cpu_write) begin
                        cpu_rdata <= {adc_result,adc_result};
                        irq6 <= 0; // OE clears MAME's EOC flip-flop
                    end
                end
            end
            if (!pause && adc_timer!=0) begin
                adc_timer <= adc_timer-1'b1;
                if (adc_timer==1) begin
                    case (adc_channel)
                        0: adc_result <= stick_x;
                        1: adc_result <= stick_y;
                        default: adc_result <= 0;
                    endcase
                    irq6 <= 1;
                end
            end
            // A restart must override the old timer decrement/completion.
            if (cpu_req && !cpu_ack && adc_sel && cpu_write && |cpu_be)
                adc_timer <= TIMER_BITS'(CONVERSION_TICKS);
        end
    end
endmodule
