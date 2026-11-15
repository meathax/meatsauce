module psychos_adpcmb(
    input                rst,
    input                clk,
    input                tick,

    input                wr,
    input        [ 4:0]  wreg,
    input        [ 7:0]  wdata,

    output       [ 2:0]  status,
    input                clr_eos,

    output reg   [20:0]  rom_addr,
    output reg           rom_cs,
    input        [ 7:0]  rom_data,
    input                rom_ok,

    output reg signed [15:0] snd,
    output reg pcm_valid
);

localparam [14:0] STEP_MIN = 15'd127;
localparam [14:0] STEP_MAX = 15'd24576;

reg  [7:0]  r0, r1, level;
reg  [15:0] start, stop, deltan;

wire execute  = r0[7];
wire record   = r0[6];
wire repeat_f = r0[4];
wire [2:0] shift = (r1[0] || r1[1]) ? 3'd5 : 3'd2;

reg         eos, brdy, playing, int_playing;
reg         latch_pend;
reg  [23:0] curaddr;
reg  [31:0] buffer;
reg  [ 3:0] nibbles;
reg  [15:0] position;
reg  signed [15:0] acc, out, prev;
reg  [14:0] step;

assign status = { playing, brdy, eos };

wire [ 3:0] nib     = buffer[31:28];
wire [18:0] dmag    = ( {nib[2:0],1'b1} * step ) >> 3;
// DECODE is split in two states (96MHz timing): the nibble*step and step*scale products are registered
// first (dmag_r/stepm_r), then accumulated/clamped. tick is sparse, so this only delays the sample by one clock.
reg [18:0] dmag_r;
reg [22:0] stepm_r;
wire signed [17:0] sum = $signed({acc[15],acc[15],acc}) + ( nib[3] ? -$signed({1'b0,dmag_r[16:0]}) : $signed({1'b0,dmag_r[16:0]}) );
wire signed [15:0] acc_n = sum > 18'sd32767 ? 16'sd32767 : sum < -18'sd32768 ? 16'sh8000 : sum[15:0];
reg  [ 7:0] scale;
always @(*) case( nib[2:0] )
    3'd4: scale = 8'd77; 3'd5: scale = 8'd102; 3'd6: scale = 8'd128; 3'd7: scale = 8'd153;
    default: scale = 8'd57;
endcase
wire [22:0] stepm  = ( step * scale ) >> 6;
wire [14:0] step_n = stepm_r > STEP_MAX ? STEP_MAX : stepm_r < STEP_MIN ? STEP_MIN : stepm_r[14:0];

localparam IDLE=0, FETCH=1, FWAIT=2, OUTP=3, DECODE=4, OUTP2=5, DECODE2=6;
reg  [2:0] st;
reg  [1:0] fwait_cnt;
wire [16:0] pos_sum = {1'b0,position} + {1'b0,deltan};
wire [23:0] unitmask = (24'd1 << shift) - 24'd1;
wire [23:0] latch_val = {8'd0, start} << shift;
wire [23:0] unitaddr  = curaddr >> shift;

wire signed [33:0] mix = $signed(prev) * $signed({1'b0, 17'h10000 - {1'b0,position}}) +
                         $signed(out)  * $signed({1'b0, 1'b0, position});
wire signed [17:0] interp = mix >>> 16;
// Interpolation and level multiply are split over two states (96MHz timing); tick is sparse,
// so the extra clock only delays snd/pcm_valid by one clock.
reg signed [17:0] interp_r;
wire signed [26:0] lvl = interp_r * $signed({1'b0, level});
wire signed [26:0] lvs = lvl >>> 11;

wire [31:0] append_buffer = buffer | ({rom_data,24'd0} >> (4*nibbles));

// Donor arithmetic; event/buffer/control semantics match MAME0.289 ymfm ADPCM-B.
// Earlier old-backend pass and first0.289 difference are retained in sim/psychos/audio.
always @(posedge clk) begin
    pcm_valid <= 0;
    if (rst) begin
        r0 <= 0; r1 <= 0; level <= 0; start <= 0; stop <= 0; deltan <= 0;
        eos <= 0; brdy <= 1; playing <= 0; int_playing <= 0; latch_pend <= 0;
        curaddr <= 0; buffer <= 0; nibbles <= 0; position <= 0;
        acc <= 0; out <= 0; prev <= 0; step <= STEP_MIN;
        st <= IDLE; rom_cs <= 0; rom_addr <= 0; snd <= 0; fwait_cnt <= 0;
    end else begin
        if (clr_eos) eos <= 0;
        if (wr) begin
            case (wreg)
                5'h00: begin
                    r0 <= wdata;
                    brdy <= 1; st <= IDLE; rom_cs <= 0;
                    if (wdata[0]) begin
                        if (int_playing) eos <= 1;
                        int_playing <= 0;
                    end else begin
                        playing <= 0; int_playing <= 0; latch_pend <= 1;
                        if (wdata[7]) begin
                            eos <= 0; playing <= 1; int_playing <= 1;
                            buffer <= 0; nibbles <= 0; position <= 0;
                            acc <= 0; out <= 0; step <= STEP_MIN;
                        end
                    end
                end
                5'h01: r1 <= wdata;
                5'h02: start[7:0] <= wdata;
                5'h03: start[15:8] <= wdata;
                5'h04: stop[7:0] <= wdata;
                5'h05: stop[15:8] <= wdata;
                5'h09: deltan[7:0] <= wdata;
                5'h0A: deltan[15:8] <= wdata;
                5'h0B: level <= wdata;
                default:;
            endcase
        end
        if (!(wr && wreg==0)) begin
            case (st)
                IDLE: if (tick) begin
                    if (!execute || record || !int_playing) begin
                        prev <= out; position <= 0; int_playing <= 0; st <= OUTP;
                    end else begin
                        position <= pos_sum[15:0];
                        if (!pos_sum[16]) st <= OUTP;
                        else if (nibbles==0) st <= FETCH;
                        else st <= DECODE;
                    end
                end
                DECODE: begin
                    dmag_r <= dmag; stepm_r <= stepm; st <= DECODE2;
                end
                DECODE2: begin
                    buffer <= buffer << 4; nibbles <= nibbles-1'b1;
                    acc <= acc_n; out <= acc_n; prev <= out; step <= step_n;
                    if (nibbles==1) begin
                        eos <= 1; acc <= 0; step <= STEP_MIN;
                        if (!repeat_f) int_playing <= 0;
                    end
                    if (nibbles<=3 && (nibbles!=1 || repeat_f)) st <= FETCH;
                    else st <= OUTP;
                end
                FETCH: begin
                    if (latch_pend) begin
                        curaddr <= latch_val; rom_addr <= latch_val[20:0]; latch_pend <= 0;
                    end else rom_addr <= curaddr[20:0];
                    rom_cs <= 1; st <= FWAIT;
                end
                FWAIT: if (rom_ok) begin
                    rom_cs <= 0; st <= OUTP;
                    if ((curaddr & unitmask)==unitmask && unitaddr=={8'd0,stop}) begin
                        // Same terminal queue operation as0.289: discard3queued nibbles.
                        buffer <= append_buffer << 12; nibbles <= nibbles-1'b1;
                        if (repeat_f) curaddr <= latch_val;
                    end else begin
                        buffer <= append_buffer; nibbles <= nibbles+2'd2;
                        if ((curaddr & unitmask)==unitmask && unitaddr==24'h00ffff) curaddr <= 0;
                        else curaddr <= curaddr+24'd1;
                    end
                end
                OUTP: begin
                    interp_r <= interp; st <= OUTP2;
                end
                OUTP2: begin
                    snd <= lvs > 27'sd32767 ? 16'sd32767 : lvs < -27'sd32768 ? 16'sh8000 : lvs[15:0];
                    pcm_valid <= 1; st <= IDLE;
                end
                default: begin st <= IDLE; rom_cs <= 0; end
            endcase
        end
    end
end
endmodule
