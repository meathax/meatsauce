//============================================================================
//  Ricoh RF5C68 (ASSP 5C105 / Sega 315-5476A) — 8-voice PCM (DESIGN.md §7.4)
//  64KB wave RAM, Fs = clk/384 (12.5MHz -> 32.552 kHz).
//  Register map (per MAME rf5c68.cpp):
//    0 ENV, 1 PAN {R[7:4],L[3:0]}, 2 FDL, 3 FDH, 4 LSL, 5 LSH, 6 ST,
//    7 control {en[7], sel[6]: 1=cbank(ch) 0=wbank, val[3:0]},
//    8 channel-OFF mask (active low enables)
//  Samples: 8-bit sign-magnitude-ish (0xFF = loop marker -> jump to LS).
//============================================================================

module s32_rf5c68 #(
    // The universal System 32 profile stores mutable wave data in the unused
    // MultiPCM SDRAM aperture. Standalone device tests retain the original
    // on-chip dual-port RAM unless they explicitly exercise this interface.
    parameter EXTERNAL_WAVE_RAM = 1'b0
) (
    input             clk,          // clk_sys
    input             ce,           // 12.5 MHz clock enable
    input             rst,

    // Z80-side access: regs at 0x0000-0x000F (mirrored to 0x0FFF),
    // wave RAM window at 0x1000-0x1FFF (4KB page = wbank)
    input             cs,           // 0xC000-0xDFFF region select
    input             we,
    input      [12:0] addr,
    input       [7:0] wdata,
    output reg  [7:0] rdata,

    // External 16-bit backing store. Reads return the word containing the
    // requested byte; writes carry one byte and its exact byte address.
    output reg        wave_rd_req,
    output reg [15:0] wave_rd_addr,
    input      [15:0] wave_rd_data,
    input             wave_rd_ack,
    output reg        wave_wr_req,
    output reg [15:0] wave_wr_addr,
    output reg  [7:0] wave_wr_data,
    input             wave_wr_ack,
    output            cpu_wait,

    output reg signed [15:0] out_l,
    output reg signed [15:0] out_r
);

// Per-channel registers.
reg [7:0]  env  [0:7];
reg [7:0]  pan  [0:7];
reg [15:0] fd   [0:7];
reg [15:0] ls   [0:7];
reg [7:0]  st   [0:7];
reg [26:0] caddr[0:7];     // 16.11 address accumulator
reg [7:0]  chan_off_m;     // channel off mask
reg        enable;
reg [2:0]  cbank;
reg [3:0]  wbank;

// A synchronous RAM read takes one clock after its address is registered.  The
// explicit wait/use states also provide the extra loop-target fetch required
// when the first byte is the 0xff marker.
localparam [2:0] VS_IDLE       = 3'd0;
localparam [2:0] VS_FETCH_WAIT = 3'd1;
localparam [2:0] VS_FETCH_USE  = 3'd2;
localparam [2:0] VS_LOOP_WAIT  = 3'd3;
localparam [2:0] VS_LOOP_USE   = 3'd4;
localparam [2:0] VS_ACCUM      = 3'd5;
reg [2:0] voice_state;

// The RF5C68 needs exactly two physical RAM ports: Z80 read/write and voice
// read-only.  Instantiate the shared wrapper explicitly because Quartus 17
// expands an equivalent multi-read unpacked array into registers.  Bytes remain
// inverted so zero-initialized M10Ks represent the device's logical 0xff
// power-up state.
wire [15:0] zram_addr = {wbank, addr[11:0]};
wire        zram_we   = cs && we && addr[12];
wire [7:0]  zram_q_stored;
wire [7:0]  voice_ram_q_stored;
reg  [7:0]  zram_q_external;
reg  [7:0]  voice_ram_q_external;
wire [7:0]  zram_q = EXTERNAL_WAVE_RAM ? zram_q_external
                                        : ~zram_q_stored;
wire [7:0]  voice_ram_q = EXTERNAL_WAVE_RAM ? voice_ram_q_external
                                             : ~voice_ram_q_stored;
reg         zram_sel_q;
reg [15:0]  voice_ram_addr;

generate
    if (!EXTERNAL_WAVE_RAM) begin : g_internal_wave_ram
        s32_byte_dpram #(
            .ADDR_WIDTH(16),
            .NUM_WORDS(65536),
            .POWER_UP_UNINITIALIZED("FALSE")
        ) wave_ram (
            .clock(clk),
            .address_a(zram_addr), .data_a(~wdata),
            .rden_a(1'b1), .wren_a(zram_we), .q_a(zram_q_stored),
            .address_b(voice_ram_addr), .data_b(8'h00),
            .rden_b(1'b1), .wren_b(1'b0), .q_b(voice_ram_q_stored)
        );
    end
    else begin : g_no_internal_wave_ram
        assign zram_q_stored = 8'h00;
        assign voice_ram_q_stored = 8'h00;
    end
endgenerate

// Production clears this SDRAM aperture to zero before reset release and
// stores bytes inverted, exactly like the internal M10K implementation. Thus
// zero backing reads as logical 0xff without any on-chip validity bitmap.
reg wave_rd_voice;
reg wave_rd_lane;
reg cpu_wave_done;
reg voice_data_ready;
wire cpu_wave_cycle = cs && addr[12];
wire cpu_wave_rd = cpu_wave_cycle && !we;
wire cpu_wave_wr = cpu_wave_cycle &&  we;
assign cpu_wait = EXTERNAL_WAVE_RAM && cpu_wave_cycle && !cpu_wave_done;

always @(posedge clk) begin
    if (rst) begin
        wave_rd_req <= 1'b0;
        wave_rd_addr <= 16'd0;
        wave_wr_req <= 1'b0;
        wave_wr_addr <= 16'd0;
        wave_wr_data <= 8'd0;
        wave_rd_voice <= 1'b0;
        wave_rd_lane <= 1'b0;
        zram_q_external <= 8'hff;
        voice_ram_q_external <= 8'hff;
        cpu_wave_done <= 1'b0;
        voice_data_ready <= 1'b0;
    end
    else if (EXTERNAL_WAVE_RAM) begin
        if (!cpu_wave_cycle)
            cpu_wave_done <= 1'b0;

        if (voice_data_ready && (voice_state != VS_FETCH_WAIT) &&
                                (voice_state != VS_LOOP_WAIT))
            voice_data_ready <= 1'b0;

        if (wave_rd_req && wave_rd_ack) begin
            wave_rd_req <= 1'b0;
            if (wave_rd_voice) begin
                voice_ram_q_external <= ~(wave_rd_lane ? wave_rd_data[15:8]
                                                        : wave_rd_data[7:0]);
                voice_data_ready <= 1'b1;
            end
            else begin
                zram_q_external <= ~(wave_rd_lane ? wave_rd_data[15:8]
                                                  : wave_rd_data[7:0]);
                cpu_wave_done <= 1'b1;
            end
        end

        if (wave_wr_req && wave_wr_ack) begin
            wave_wr_req <= 1'b0;
            cpu_wave_done <= 1'b1;
        end

        // Requests are armed only after the previous stretched ACK has
        // returned low. CPU access wins because WAIT holds the Z80 bus cycle.
        if (!wave_rd_req && !wave_rd_ack) begin
            if (cpu_wave_rd && !cpu_wave_done) begin
                wave_rd_req <= 1'b1;
                wave_rd_addr <= zram_addr;
                wave_rd_voice <= 1'b0;
                wave_rd_lane <= zram_addr[0];
            end
            else if (((voice_state == VS_FETCH_WAIT) ||
                      (voice_state == VS_LOOP_WAIT)) && !voice_data_ready) begin
                wave_rd_req <= 1'b1;
                wave_rd_addr <= voice_ram_addr;
                wave_rd_voice <= 1'b1;
                wave_rd_lane <= voice_ram_addr[0];
            end
        end

        if (!wave_wr_req && !wave_wr_ack && cpu_wave_wr && !cpu_wave_done) begin
            wave_wr_req <= 1'b1;
            wave_wr_addr <= zram_addr;
            wave_wr_data <= wdata;
        end
    end
    else begin
        wave_rd_req <= 1'b0;
        wave_wr_req <= 1'b0;
        cpu_wave_done <= 1'b0;
        voice_data_ready <= 1'b0;
    end
end

always @(posedge clk)
    zram_sel_q <= addr[12];

always @* rdata = zram_sel_q ? zram_q : 8'hff;

// Fs divider: one channel is launched per 48 CE ticks (8 ch x 48 = 384).
reg [5:0]  div48;
reg [2:0]  ch;
// Eight full-scale voices exceed 16-bit range; retain the complete mix until
// the RF5C68's final 10-bit quantization and signed-16 clipping stage.
reg signed [18:0] acc_l, acc_r;

reg [2:0] voice_ch;
reg       voice_last;
reg [7:0] voice_env;
reg [7:0] voice_pan;
reg [15:0] voice_fd;
reg [15:0] voice_ls;
reg signed [18:0] voice_delta_l_q, voice_delta_r_q;
reg [26:0] voice_next_addr;
reg        voice_advance;

// Keep the multiply widths explicit.  sample[7]=1 is positive; sample[7]=0
// is negative, matching MAME's RF5C68 sign/magnitude convention.
wire [14:0] voice_mag_env = voice_ram_q[6:0] * voice_env;
wire [18:0] voice_prod_l  = voice_mag_env * voice_pan[3:0];
wire [18:0] voice_prod_r  = voice_mag_env * voice_pan[7:4];
wire [13:0] voice_mag_l   = voice_prod_l[18:5];
wire [13:0] voice_mag_r   = voice_prod_r[18:5];
wire signed [18:0] voice_delta_l = voice_ram_q[7]
                                       ? $signed({5'b00000, voice_mag_l})
                                       : -$signed({5'b00000, voice_mag_l});
wire signed [18:0] voice_delta_r = voice_ram_q[7]
                                       ? $signed({5'b00000, voice_mag_r})
                                       : -$signed({5'b00000, voice_mag_r});

// MAME models the RF5C68 as a 10-bit DAC: clear the low six bits of an
// in-range mix, then clamp excursions to signed 16-bit full scale.
function automatic signed [15:0] quantize_clip(input signed [18:0] mix);
    begin
        if (mix > 19'sd32767)
            quantize_clip = 16'sh7fff;
        else if (mix < -19'sd32768)
            quantize_clip = 16'sh8000;
        else
            quantize_clip = {mix[15:6], 6'b000000};
    end
endfunction

integer i;
always @(posedge clk) begin
    if (rst) begin
        enable      <= 1'b0;
        cbank       <= 3'd0;
        wbank       <= 4'd0;
        chan_off_m  <= 8'hff;
        div48       <= 6'd0;
        ch          <= 3'd0;
        acc_l       <= 19'sd0;
        acc_r       <= 19'sd0;
        out_l       <= 16'sd0;
        out_r       <= 16'sd0;
        voice_state <= VS_IDLE;
        voice_ram_addr <= 16'd0;
        voice_ch    <= 3'd0;
        voice_last  <= 1'b0;
        voice_env   <= 8'd0;
        voice_pan   <= 8'd0;
        voice_fd    <= 16'd0;
        voice_ls    <= 16'd0;
        voice_delta_l_q <= 19'sd0;
        voice_delta_r_q <= 19'sd0;
        voice_next_addr <= 27'd0;
        voice_advance   <= 1'b0;
        for (i = 0; i < 8; i = i + 1) begin
            env[i]   <= 8'd0;
            pan[i]   <= 8'd0;
            fd[i]    <= 16'd0;
            ls[i]    <= 16'd0;
            st[i]    <= 8'd0;
            caddr[i] <= 27'd0;
        end
    end
    else begin
        // The voice pipeline completes long before the following 48-CE slot.
        // caddr is owned by this process so CPU reloads and playback advances
        // cannot become multiple drivers in synthesis.
        case (voice_state)
            VS_FETCH_WAIT:
                if (!EXTERNAL_WAVE_RAM || voice_data_ready)
                    voice_state <= VS_FETCH_USE;

            VS_FETCH_USE: begin
                if (voice_ram_q == 8'hff) begin
                    caddr[voice_ch] <= {voice_ls, 11'b0};
                    voice_ram_addr <= voice_ls;
                    voice_state    <= VS_LOOP_WAIT;
                end
                else begin
                    voice_next_addr <= caddr[voice_ch] + {11'b0, voice_fd};
                    voice_advance   <= 1'b1;
                    voice_delta_l_q <= voice_delta_l;
                    voice_delta_r_q <= voice_delta_r;
                    voice_state     <= VS_ACCUM;
                end
            end

            VS_LOOP_WAIT:
                if (!EXTERNAL_WAVE_RAM || voice_data_ready)
                    voice_state <= VS_LOOP_USE;

            VS_LOOP_USE: begin
                // A marker at the loop target is an empty/dead voice: retain
                // the loop address and contribute silence, as MAME does.
                if (voice_ram_q != 8'hff) begin
                    voice_next_addr <= {voice_ls, 11'b0} +
                                       {11'b0, voice_fd};
                    voice_advance   <= 1'b1;
                    voice_delta_l_q <= voice_delta_l;
                    voice_delta_r_q <= voice_delta_r;
                end
                else begin
                    voice_advance   <= 1'b0;
                    voice_delta_l_q <= 19'sd0;
                    voice_delta_r_q <= 19'sd0;
                end
                voice_state <= VS_ACCUM;
            end

            VS_ACCUM: begin
                if (voice_advance)
                    caddr[voice_ch] <= voice_next_addr;
                if (voice_last) begin
                    out_l <= quantize_clip(acc_l + voice_delta_l_q);
                    out_r <= quantize_clip(acc_r + voice_delta_r_q);
                    acc_l <= 19'sd0;
                    acc_r <= 19'sd0;
                end
                else begin
                    acc_l <= acc_l + voice_delta_l_q;
                    acc_r <= acc_r + voice_delta_r_q;
                end
                voice_state <= VS_IDLE;
            end

            default: ;
        endcase

        if (ce) begin
            div48 <= (div48 == 6'd47) ? 6'd0 : div48 + 1'd1;
            if ((div48 == 6'd0) && (voice_state == VS_IDLE)) begin
                voice_ch   <= ch;
                voice_last <= (ch == 3'd7);
                voice_env  <= env[ch];
                voice_pan  <= pan[ch];
                voice_fd   <= fd[ch];
                voice_ls   <= ls[ch];
                ch         <= ch + 1'd1;
                if (enable && !chan_off_m[ch]) begin
                    voice_ram_addr <= caddr[ch][26:11];
                    voice_state    <= VS_FETCH_WAIT;
                end
                else if (ch == 3'd7) begin
                    out_l <= quantize_clip(acc_l);
                    out_r <= quantize_clip(acc_r);
                    acc_l <= 19'sd0;
                    acc_r <= 19'sd0;
                end
            end
        end

        // Z80 register writes.  These are intentionally later in the process
        // so an explicit CPU start/off write wins over a simultaneous voice
        // address advance.
        if (cs && we && !addr[12]) begin
            case (addr[3:0])
                4'h0: env[cbank] <= wdata;
                4'h1: pan[cbank] <= wdata;
                4'h2: fd[cbank][7:0]  <= wdata;
                4'h3: fd[cbank][15:8] <= wdata;
                4'h4: ls[cbank][7:0]  <= wdata;
                4'h5: ls[cbank][15:8] <= wdata;
                4'h6: begin
                    st[cbank] <= wdata;
                    if (chan_off_m[cbank]) caddr[cbank] <= {wdata, 19'b0};
                end
                4'h7: begin
                    enable <= wdata[7];
                    if (wdata[6]) cbank <= wdata[2:0];
                    else          wbank <= wdata[3:0];
                end
                4'h8: begin
                    chan_off_m <= wdata;
                    for (i = 0; i < 8; i = i + 1) begin
                        if (wdata[i]) caddr[i] <= {st[i], 19'b0};
                    end
                end
                default: ;
            endcase
        end
    end
end

endmodule
