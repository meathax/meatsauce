// SPDX-License-Identifier: GPL-3.0-or-later
// VRender0 UART channel as MAME 0.289 vr0uart (machine/vr0uart.cpp): UCON (reset 0x001), USTAT, UTXB,
// URXB, UBDR (reset 1). No receiver is attached on the Crystal System board, so the receive FIFO stays
// empty. A transmitted byte keeps USTAT bits 5/6 set for one serial frame at MAME's rate
// (clock 3.5795 MHz: baud = clock/2/((UBDR+1)*16), one bit = 768*(UBDR+1) clk_sys at 85.909 MHz), then
// clears them and requests the channel's TX interrupt (tra_complete). With the UART disabled (UCON bit 8)
// MAME's serial rate is zero: the byte never completes and USTAT bit 5 stays set.
module vr0_uart (
    input logic clk, reset,
    input logic sel, write,
    input logic [4:0] offset,
    input logic [31:0] data,
    input logic [3:0] strobe,
    output logic [31:0] read_data,
    output logic tx_done
);
    logic [31:0] ucon, ubdr;
    logic [7:0] ustat;
    logic [29:0] remaining;
    logic [31:0] mask;
    logic [3:0] frame_bits;
    always_comb begin
        mask = {{8{strobe[3]}},{8{strobe[2]}},{8{strobe[1]}},{8{strobe[0]}}};
        frame_bits = 4'd1 + (ucon[0] ? 4'd8 : 4'd7) + (ucon[3] ? 4'd1 : 4'd0) + (ucon[1] ? 4'd2 : 4'd1);
        case (offset[4:2])
            3'd0: read_data = ucon;
            3'd1: read_data = {24'b0, ustat};
            3'd4: read_data = ubdr;
            default: read_data = 32'b0; // UTXB is write-only; URXB reads 0 with an empty FIFO
        endcase
    end
    always_ff @(posedge clk) begin
        tx_done <= 0;
        if (reset) begin
            ucon <= 32'h001; ubdr <= 32'd1; ustat <= 0; remaining <= 0;
        end else begin
            if (remaining != 0) begin
                remaining <= remaining - 30'd1;
                if (remaining == 30'd1) begin ustat[6:5] <= 2'b00; tx_done <= 1; end
            end
            if (sel && write) case (offset[4:2])
                3'd0: ucon <= (ucon & ~mask) | (data & mask);
                3'd2: if (strobe[0]) begin
                    if (ucon[8]) begin
                        ustat[6:5] <= 2'b11;
                        remaining <= 30'(frame_bits) * 30'd768 * (30'(ubdr[15:0]) + 30'd1);
                    end else ustat[5] <= 1'b1;
                end
                3'd4: ubdr <= (ubdr & ~mask) | (data & mask);
                default: ;
            endcase
            if (sel && !write && offset[4:2] == 3'd1) ustat[3:0] <= 4'b0; // status read clears error bits
        end
    end
endmodule
