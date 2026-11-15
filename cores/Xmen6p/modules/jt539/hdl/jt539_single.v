/* jt539_single compatibility adapter (X-Men MiSTer staging, 2026-11-05)
 * Upstream jotego/jt539 is not public. This wraps the Violent Storm K054539
 * implementation (module k054539, files jtviostorm_k054539*.v, copied from
 * D:/Arcade/AI/aCORES/Violent storm/cores/viostorm/hdl; identical except for
 * the .hex paths, checked 2026-11-06)
 * behind the port list used by cores/xmen/hdl/jtxmen_sound.v.
 *
 * Differences from the original jt539_single:
 *  - rom_ok is required: PCM ROM data comes from shared SDRAM and is not
 *    zero-latency. rb_wait must stall the Z80 during data-port readback.
 *  - The chip core is PCM only; its dry output is DC blocked and scaled by
 *    PCM_GAIN (board gain, see below), aux_l/aux_r (YM2151) are added and
 *    the mix goes through a peak limiter to 16 bits.
 */
module jt539_single #(parameter VOLSHIFT=0, parameter PCM_GAIN=148) (
    input               rst,
    input               clk,
    input               cen,
    output              timeout,

    input      [ 8:0]   addr,
    input               we,
    input               rd,
    input               cs,
    input      [ 7:0]   din,
    output     [ 7:0]   dout,

    output              rom_cs,
    output     [23:0]   rom_addr,
    input      [ 7:0]   rom_data,
    input               rom_ok,
    output              rb_wait,

    input signed [15:0] aux_l,
    input signed [15:0] aux_r,

    output reg signed [15:0] left,
    output reg signed [15:0] right,

    input      [ 7:0]   debug_bus,
    output     [ 7:0]   st_dout
);

wire signed [15:0] pcm_l, pcm_r;

// JTFRAME ROM slots latch data_ok (OKLATCH=1): ok stays high for one clock
// after the address changes. k054539 moves to the next byte address and tests
// rom_ok on the following clock, so the stale ok captured the previous byte.
// A stale 0x80/0x8000 reads as the end-of-sample marker and cuts effects short.
// Accept ok only when the request and address were already present last clock.
reg  [23:0] rom_addr_l;
reg         rom_cs_l;
wire        rom_ok_safe = rom_ok && rom_cs && rom_cs_l && rom_addr == rom_addr_l;

always @(posedge clk) begin
    rom_addr_l <= rom_addr;
    rom_cs_l   <= rom_cs;
end
wire signed [15:0] wet_l, wet_r;
// Outputs used: the chip's dry banks only (D/B), as on the Violent Storm board
// (jtviostorm_k054321_mix WET_MIX=0). The effect-loop returns are already
// mixed into the dry banks, which is what MAME outputs (reverb buffer + dry
// voices). The wet banks (C/A) are an extra effect-panned copy of each voice.
//
// DC blocker: when a DPCM voice ends the chip keeps outputting its last value
// (native behaviour; the PCB output capacitors remove it). Measured up to 49
// native units of DC, -17 dBFS after the gain, stuck for seconds. A one-pole
// high pass (~7.5 Hz) per chip sample stands in for those capacitors:
//   H = H - H/1024 + (pcm - pcm_prev)*1024 ; hp = H/1024
//
// Board gain: the native K054539 datapath (volume x global x pan, each keeping
// product[31:16], then the ACCE half) leaves its output ~40 dB below full
// scale. Violent Storm scales it up on the board side (x8..x32). Without that
// gain the PCM (effects, voices, drums) sat ~30 dB under the YM2151 and most
// game sound was inaudible. PCM_GAIN=148 matches MAME xmen's mix (YM2151 0.20,
// K054539 1.00) on the dry banks, measured per device over all 253 sound codes
// (Xmen/build/sndall) and over gameplay (Xmen/build/snd6p, MAME per-device
// levels via the Lua sound hook).
localparam signed [8:0] PCM_G = PCM_GAIN;
reg  signed [15:0] hp_prev_l, hp_prev_r;
reg  signed [29:0] hp_acc_l,  hp_acc_r;
wire signed [29:0] hp_next_l = hp_acc_l - (hp_acc_l >>> 10) +
                               ($signed({{14{pcm_l[15]}},pcm_l}) - $signed({{14{hp_prev_l[15]}},hp_prev_l})) * 30'sd1024;
wire signed [29:0] hp_next_r = hp_acc_r - (hp_acc_r >>> 10) +
                               ($signed({{14{pcm_r[15]}},pcm_r}) - $signed({{14{hp_prev_r[15]}},hp_prev_r})) * 30'sd1024;
wire signed [19:0] hp_l = hp_acc_l[29:10];
wire signed [19:0] hp_r = hp_acc_r[29:10];
// Concatenations are unsigned in Verilog: keep every term $signed or a
// negative PCM word is zero-extended and saturates high.
wire signed [28:0] mix_l = hp_l * PCM_G + $signed({{13{aux_l[15]}},aux_l});
wire signed [28:0] mix_r = hp_r * PCM_G + $signed({{13{aux_r[15]}},aux_r});
// Output level and limiter. jtframe_rcmix applies the mem.yaml channel gain
// (1.98) and then saturates, so this output must stay below 32767/1.98=16549.
// The whole mix (PCM:FM balance unchanged) is scaled by 1/2 and passed through
// a peak limiter, once per chip sample (sample_valid):
//   y = x*g/32768;  |y|>LIM_T -> g -= g/8 (-1.16 dB/sample, fast attack)
//                   else      -> g += 2 up to unity (~170 ms from -6 dB)
// A final clamp at +-LIM_CLAMP covers the first sample of a transient, so the
// mixer never clips. On the MAME-matched 40 s capture (attract + gameplay)
// the peak is -0.4 dBFS after the mixer and the limiter acts on 2 samples;
// gameplay peaks sit around -4 dBFS. Bit-exact model: build/snd6p/limiter.py.
localparam signed [26:0] LIM_T     = 27'sd14500;
localparam signed [15:0] LIM_CLAMP = 16'sd16500;
localparam        [15:0] G_UNITY   = 16'h8000;

wire                 smp_valid;
reg  [ 1:0]          lim_st;
reg  signed [27:0]   x_l, x_r;      // mix/2
reg  signed [26:0]   y_l, y_r;      // x*g/32768
reg  [15:0]          lim_g;
wire signed [44:0]   gx_l = x_l * $signed({1'b0,lim_g});
wire signed [44:0]   gx_r = x_r * $signed({1'b0,lim_g});

function signed [26:0] sat27(input signed [44:0] v);    // v/32768, saturated
    sat27 = (v[44:41]==4'b0000 || v[44:41]==4'b1111) ? v[41:15] :
            {v[44],{26{~v[44]}}};
endfunction

function signed [26:0] abs27(input signed [26:0] v);
    abs27 = v[26] ? -v : v;
endfunction

function signed [15:0] clamp(input signed [26:0] v);
    clamp = v >  $signed({{11{1'b0}},LIM_CLAMP}) ?  LIM_CLAMP :
            v < -$signed({{11{1'b0}},LIM_CLAMP}) ? -LIM_CLAMP : v[15:0];
endfunction

always @(posedge clk) begin
    if( rst ) begin
        lim_st <= 0;
        lim_g  <= G_UNITY;
        x_l <= 0; x_r <= 0; y_l <= 0; y_r <= 0;
        hp_prev_l <= 0; hp_prev_r <= 0; hp_acc_l <= 0; hp_acc_r <= 0;
        left <= 0; right <= 0;
    end else begin
        case( lim_st )
            0: if( smp_valid ) begin   // DC blocker, once per chip sample
                hp_acc_l  <= hp_next_l;
                hp_acc_r  <= hp_next_r;
                hp_prev_l <= pcm_l;
                hp_prev_r <= pcm_r;
                lim_st    <= 1;
            end
            1: begin
                x_l    <= mix_l >>> 1;
                x_r    <= mix_r >>> 1;
                lim_st <= 2;
            end
            2: begin
                y_l    <= sat27(gx_l);
                y_r    <= sat27(gx_r);
                lim_st <= 3;
            end
            default: begin
                left  <= clamp(y_l);
                right <= clamp(y_r);
                if( abs27(y_l) > LIM_T || abs27(y_r) > LIM_T )
                    lim_g <= lim_g - (lim_g>>3);
                else if( lim_g < G_UNITY )
                    lim_g <= (lim_g > G_UNITY-16'd2) ? G_UNITY : lim_g + 16'd2;
                lim_st <= 0;
            end
        endcase
    end
end

k054539 #(.VOLSHIFT(VOLSHIFT)) u_k054539(
    .rst            ( rst       ),
    .clk            ( clk       ),
    .cen            ( cen       ),
    .timeout        ( timeout   ),
    .addr           ( addr      ),
    .we             ( we        ),
    .rd             ( rd        ),
    .cs             ( cs        ),
    .din            ( din       ),
    .dout           ( dout      ),
    .rom_cs         ( rom_cs    ),
    .rom_addr       ( rom_addr  ),
    .rb_wait        ( rb_wait   ),
    .rom_data       ( rom_data  ),
    .rom_ok         ( rom_ok_safe ),
    .left           ( pcm_l     ),
    .right          ( pcm_r     ),
    .wet_left       ( wet_l     ),
    .wet_right      ( wet_r     ),
    .sample_valid   ( smp_valid ),
    .sample_epoch   (           ),
    .output_enabled (           ),
    .axword_a       ( 16'sd0    ),
    .axword_b       ( 16'sd0    ),
    .debug_bus      ( debug_bus ),
    .st_dout        ( st_dout   )
);

endmodule
