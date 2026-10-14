/*  This file is part of JT89.

    JT89 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT89 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT89.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: March, 8th 2017

    This work was originally based in the implementation found on the
    SMS core of MiST

    ------------------------------------------------------------------------
    MODIFIED 2026-07-28 for the Arcade-Ikki MiSTer core.

    Upstream JT89 implements the Sega VDP PSG noise generator: a 16-bit LFSR
    seeded to 0x8000 with feedback shift[0]^shift[3].  In MAME's terms that is
    segapsg_device (feedback mask 0x8000, taps 0x01 / 0x08).

    Ikki uses SN76489A parts, which MAME describes as feedback mask 0x10000
    (a 17-bit register) with taps 0x04 / 0x08.  The shift register width, seed
    and taps are now parameters, and the update is a direct transcription of
    sn76496_base_device::sound_stream_update:

        if (((RNG & tap1) != 0) != (((RNG & tap2) != 0) && noise_mode))
            { RNG >>= 1; RNG |= feedback; }
        else
            { RNG >>= 1; }
        output = RNG & 1;

    Tone rate, noise period reloads and the tone-2 tracking mode are unchanged;
    those already matched MAME.  See docs/AUDIT.md A9.
    ------------------------------------------------------------------------
    */

module jt89_noise #(
    // SN76489A (MAME sn76489a_device).  For the Sega VDP PSG use
    // LFSR_W = 16, SEED = 16'h8000, TAP1 = 1, TAP2 = 8.
    parameter LFSR_W = 17,
    parameter [LFSR_W-1:0] SEED = 17'h10000,
    parameter [LFSR_W-1:0] TAP1 = 17'h00004,
    parameter [LFSR_W-1:0] TAP2 = 17'h00008
)(
    input               clk,
(* direct_enable = 1 *) input   clk_en,
    input               rst,
    input               clr,
    input         [2:0] ctrl3,
    input         [3:0] vol,
    input         [9:0] tone2_reg,   // tone generator 2 period register
    output        [8:0] snd
);

reg [LFSR_W-1:0] shift;
reg              nout;   // noise output, updated only when the LFSR is clocked
reg [11:0] cnt;
wire       up = cnt==12'd1;

// MAME (sn76496_base_device::write): in tone-2 mode the noise shifter runs from
// its own counter reloaded with 2x the tone-2 period, and a tone-2 register of
// 0 counts as 0x400.  It does not follow the tone-2 output, so it keeps clocking
// when tone 2 is muted or set to a "sample" period (<=5), which the games use
// for snare/footstep noise.
wire [11:0] tone2_per = {(tone2_reg==10'd0) ? 11'h400 : {1'b0,tone2_reg}, 1'b0};

jt89_vol u_vol(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .clk_en ( clk_en    ),
    .din    ( nout      ),
    .vol    ( vol       ),
    .snd    ( snd       )
);

always @(posedge clk)
    if( rst ) begin
        cnt <= 0;
    end else if( clk_en ) begin
        if( cnt==12'd1 ) begin
            case( ctrl3[1:0] )
                2'd0: cnt <= 12'h20; // clk_en already divides by 16
                2'd1: cnt <= 12'h40;
                2'd2: cnt <= 12'h80;
                default: cnt <= tone2_per;
            endcase
        end else begin
            cnt <= cnt-12'b1;
        end
    end

// ctrl3[2] selects white noise; in periodic mode MAME holds the second tap at 0.
wire fb = ((shift & TAP1) != 0) ^ (((shift & TAP2) != 0) & ctrl3[2]);

always @(posedge clk)
    if( rst || clr )
        shift <= SEED;
    else if( clk_en ) begin
        if( up ) shift <= {fb, shift[LFSR_W-1:1]};
    end

// MAME latches the output (RNG & 1) at each noise clock only; resetting the
// LFSR on a register-6 write leaves the previous output level in place until
// the next clock.
always @(posedge clk)
    if( rst )
        nout <= SEED[0];
    else if( clk_en && up && !clr )
        nout <= shift[1];

endmodule
