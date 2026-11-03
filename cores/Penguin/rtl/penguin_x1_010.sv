// Owned Penguin derivative of Guardians gd_x1_010.sv.
// Upstream 43bb986da05aa19adb06ac575cfcc8af5c003fb7; SHA256 bcf935218e4c3d9d67e9ada532c0a04c3ab339d1f4055dbc0112275bd9b861ee
// Changes: exact sample cadence, all 16 physical banks, nonwrapping end,
// MAME integer volume, 32-bit wave/envelope phase and pre-sample keyoff.
// Seta X1-010 16-voice PCM/wavetable sound generator.
// Register layout, rate and phase arithmetic follow MAME's BSD-licensed
// x1_010 device model. The sample ROM is fetched through a toggle interface.
// SPDX-License-Identifier: GPL-3.0-or-later

module penguin_x1_010 #(parameter integer SYS_HZ = 50000000)
(
	input  logic        clk,
	input  logic        reset,
	input  logic        pause,
	input  logic        cpu_write,
	input  logic [12:0] cpu_address,
	input  logic [15:0] cpu_data,
	input  logic  [1:0] cpu_byte_enable,
	output logic [15:0] cpu_q,
	input  logic [63:0] sample_banks,

	output logic [20:0] sample_addr,
	output logic        sample_req,
	input  logic  [7:0] sample_dout,
	input  logic        sample_ack,
	output logic signed [15:0] audio_left,
	output logic signed [15:0] audio_right,
	output logic audio_valid,
	output logic [15:0] mixer_overruns
);

wire [15:0] ram_q;
logic [12:0] sound_ram_address;
wire [15:0] sound_ram_q;
gd_word_ram #(.ADDR_WIDTH(13)) register_ram
(
	.clk(clk), .address(cpu_address), .data(cpu_data),
	.byte_enable(cpu_byte_enable), .write(cpu_write), .q(ram_q),
	.video_clk(clk), .video_address(sound_ram_address), .video_q(sound_ram_q)
);

// The 128 channel bytes are cached as registers so all six parameters can
// be inspected without duplicating the 8 KiB waveform/envelope RAM.
logic [7:0] channel_reg [0:127];
logic [31:0] sample_offset [0:15];
logic [31:0] envelope_offset [0:15];

always_comb begin
	cpu_q = ram_q;
	if (cpu_address < 13'h080)
		cpu_q[7:0] = channel_reg[cpu_address[6:0]];
end

// X1-010 input clock is 50 MHz/3, and the mixer divides by 512.
// This exact rational hardware rate is 32552.083333 Hz. MAME truncates its
// integer clock/sample rate to 32552 Hz; that tiny reference difference is
// documented rather than copied into a physical-clock claim.
localparam logic [63:0] SAMPLE_DENOMINATOR = 64'(SYS_HZ) * 64'd1536;
logic [63:0] sample_accumulator;
wire [63:0] sample_sum = sample_accumulator + 64'd50000000;
wire sample_tick = sample_sum >= SAMPLE_DENOMINATOR;

typedef enum logic [3:0] {
	S_IDLE, S_CHECK, S_PCM_WAIT, S_WAVE_ADDR, S_WAVE_FETCH,
	S_ENV_ADDR, S_ENV_FETCH, S_ADVANCE, S_FINISH
} sound_state_t;
sound_state_t state;

logic [4:0] voice;
logic signed [27:0] mix_left;
logic signed [27:0] mix_right;
// Use the existing ADVANCE/CHECK slots to split the mux/product/accumulate
// path. No extra FSM cycle, ROM request or output-sample cycle is introduced.
// Small volume products stay local instead of routing between DSP columns.
(* multstyle = "logic" *) logic signed [12:0] product_left, product_right;
(* multstyle = "logic" *) logic signed [27:0] contribution_left, contribution_right;
logic product_valid, contribution_valid;
logic signed [7:0] wave_sample;
logic [7:0] wave_volume;
logic [6:0] channel_base;
logic [31:0] logical_sample_address;
logic [3:0] selected_bank;
// BEGIN PCM_REQUEST_TIMING: whole-block endpoint and speculative idle payload.
// Same-width carry-save sum: one carry chain instead of two; no new edge.
// voice_end mirrors voice[3:0] on every edge (same assignments) but drives only
// this endpoint cone, so the 295-load voice register is off the sample_req path.
(* preserve *) logic [3:0] voice_end;
// voice_is16 mirrors (voice==16); voice_wr mirrors voice[3:0] for the offset
// write ports. Same assignments as voice, separate low-fanout launch registers.
(* preserve *) logic voice_is16;
(* preserve *) logic [3:0] voice_wr;
wire ch_en_m  = channel_reg[{voice_end,3'b000}][0];
wire ch_pcm_m = !channel_reg[{voice_end,3'b000}][1];
// The end-of-sample test is evaluated for the voice the FSM is about to check:
// ADVANCE -> CHECK uses voice+1, IDLE -> CHECK uses voice 0. Neighbouring
// voices' offsets/registers are not written by the FSM in that cycle, so the
// registered result equals the combinational one on entry to S_CHECK.
wire [3:0] pcm_idx = (state == S_ADVANCE) ? (voice_end + 4'd1) : 4'd0;
wire [6:0] pcm_end_base = {pcm_idx, 3'b000};
wire [7:0] pcm_end_a=channel_reg[pcm_end_base + 7'd4];
wire [7:0] pcm_end_b=channel_reg[pcm_end_base + 7'd5];
wire [7:0] pcm_end_c=sample_offset[pcm_idx][23:16];
wire [9:0] pcm_end_block_sum = {2'b00,(pcm_end_a ^ pcm_end_b ^ pcm_end_c)}
    + {1'b0,((pcm_end_a & pcm_end_b) | (pcm_end_a & pcm_end_c) | (pcm_end_b & pcm_end_c)),1'b0};
wire pcm_at_end_next = (|sample_offset[pcm_idx][31:24]) || (|pcm_end_block_sum[9:8]);
logic pcm_at_end_q;
always_ff @(posedge clk) pcm_at_end_q <= pcm_at_end_next;
wire pcm_at_end = pcm_at_end_q;
always_ff @(posedge clk) begin
    if (reset)
        sample_addr <= 21'd0;
    else if (!pause && (state == S_CHECK))
        sample_addr <= {selected_bank,logical_sample_address[16:0]};
end
// END PCM_REQUEST_TIMING
// BEGIN PCM_VOLUME_CACHE: one existing CHECK edge precedes every PCM product.
logic [7:0] selected_pcm_volume;
always_ff @(posedge clk) begin
    if (reset)
        selected_pcm_volume <= 8'd0;
    else if (cpu_write && (cpu_address < 13'h080) && cpu_byte_enable[0]
        && (cpu_address[2:0] == 3'd1) && (cpu_address[6:3] == voice[3:0]))
        selected_pcm_volume <= cpu_data[7:0];
    else
        selected_pcm_volume <= channel_reg[{voice[3:0],3'b001}];
end
// END PCM_VOLUME_CACHE
// BEGIN AUDIO_PRODUCT_PAYLOAD: prepare data independently of pause acceptance.
logic signed [9:0] wave_three;
function automatic signed [9:0] wave_part(input logic [1:0] volume,input logic signed [7:0] sample,input logic signed [9:0] triple);
    case(volume)
        2'd0: wave_part=10'sd0;
        2'd1: wave_part={{2{sample[7]}},sample};
        2'd2: wave_part={sample[7],sample,1'b0};
        2'd3: wave_part=triple;
    endcase
endfunction
wire signed [9:0] wave_ll=wave_part(sound_ram_q[5:4],wave_sample,wave_three);
wire signed [9:0] wave_lh=wave_part(sound_ram_q[7:6],wave_sample,wave_three);
wire signed [9:0] wave_rl=wave_part(sound_ram_q[1:0],wave_sample,wave_three);
wire signed [9:0] wave_rh=wave_part(sound_ram_q[3:2],wave_sample,wave_three);
always_ff @(posedge clk) begin
    if(reset) begin
        product_left<=0;product_right<=0;wave_three<=0;
    end else begin
        wave_three <= $signed({wave_sample[7],wave_sample,1'b0}) + $signed({{2{wave_sample[7]}},wave_sample});
        if(state==S_PCM_WAIT && sample_ack==sample_req) begin
				product_left <= $signed(sample_dout)
					* $signed({1'b0, selected_pcm_volume[7:4]});
				product_right <= $signed(sample_dout)
					* $signed({1'b0, selected_pcm_volume[3:0]});
        end else if(state==S_ENV_FETCH) begin
            product_left <= $signed({{3{wave_ll[9]}},wave_ll}) + $signed({wave_lh[9],wave_lh,2'b00});
            product_right <= $signed({{3{wave_rl[9]}},wave_rl}) + $signed({wave_rh[9],wave_rh,2'b00});
        end
    end
end
// END AUDIO_PRODUCT_PAYLOAD
logic [7:0] pcm_step;
logic [31:0] envelope_delta;
localparam integer VOL_BASE = (2 * 32 * 256 / 30); // MAME integer value: 546

always_comb begin
	channel_base = {voice[3:0], 3'b000};
	logical_sample_address = {12'd0, channel_reg[channel_base + 7'd4], 12'd0}
		+ {4'd0, sample_offset[voice[3:0]][31:4]};
	case (logical_sample_address[19:17])
		3'd0: selected_bank = sample_banks[3:0];
		3'd1: selected_bank = sample_banks[11:8];
		3'd2: selected_bank = sample_banks[19:16];
		3'd3: selected_bank = sample_banks[27:24];
		3'd4: selected_bank = sample_banks[35:32];
		3'd5: selected_bank = sample_banks[43:40];
		3'd6: selected_bank = sample_banks[51:48];
		default: selected_bank = sample_banks[59:56];
	endcase
	pcm_step = channel_reg[channel_base + 7'd2] >> channel_reg[channel_base][7];
	// Retain the pinned MAME zero-frequency convention for compatibility.
	if (pcm_step == 0) pcm_step = 8'd4;
	envelope_delta = envelope_offset[voice[3:0]] >> 10;
end

function automatic signed [15:0] saturate16;
	input signed [27:0] value;
	begin
		// Normalize the summed raw MAME add_int contribution by 256.
		if (value > 28'sd8388352) saturate16 = 16'sh7fff;
		else if (value < -28'sd8388608) saturate16 = 16'sh8000;
		else saturate16 = 16'(value / 28'sd256);
	end
endfunction

integer n;
always_ff @(posedge clk) begin
	if (reset) begin
		sample_accumulator <= 64'd0;
		state <= S_IDLE;
		voice <= 5'd0;
		voice_end <= 4'd0;
		voice_is16 <= 1'b0;
		voice_wr <= 4'd0;
		mix_left <= 28'sd0;
		mix_right <= 28'sd0;

		contribution_left <= 0; contribution_right <= 0;
		product_valid <= 0; contribution_valid <= 0;
		wave_sample <= 8'sd0;
		wave_volume <= 8'd0;
		sound_ram_address <= 13'd0;

		sample_req <= 1'b0;
		audio_left <= 16'sd0;
		audio_right <= 16'sd0;
		audio_valid <= 1'b0;
		mixer_overruns <= 16'd0;
		for (n = 0; n < 128; n = n + 1) channel_reg[n] <= 8'd0;
		for (n = 0; n < 16; n = n + 1) begin
			sample_offset[n] <= 32'd0;
			envelope_offset[n] <= 32'd0;
		end
	end
	else begin
		audio_valid <= 1'b0;
		if (cpu_write && (cpu_address < 13'h080) && cpu_byte_enable[0]) begin
			for (integer key_voice=0;key_voice<16;key_voice=key_voice+1) begin
    if ((cpu_address[2:0] == 3'd0)
        && (cpu_address[6:3] == 4'(key_voice))
        && !channel_reg[key_voice*8][0] && cpu_data[0]) begin
        sample_offset[key_voice] <= 32'd0;
        envelope_offset[key_voice] <= 32'd0;
    end
end
			channel_reg[cpu_address[6:0]] <= cpu_data[7:0];
		end

		if (pause) begin
			audio_left <= 16'sd0;
			audio_right <= 16'sd0;
		end
		else begin
			sample_accumulator <= sample_tick ? sample_sum - SAMPLE_DENOMINATOR : sample_sum;
			if (sample_tick && state != S_IDLE) mixer_overruns <= mixer_overruns + 16'd1;
			case (state)
			S_IDLE: if (sample_tick) begin
				voice <= 5'd0;
				voice_end <= 4'd0;
				voice_is16 <= 1'b0;
				voice_wr <= 4'd0;
				mix_left <= 28'sd0;
				mix_right <= 28'sd0;
				state <= S_CHECK;
			end

			S_CHECK: begin
				if (contribution_valid) begin
					mix_left <= mix_left + contribution_left;
					mix_right <= mix_right + contribution_right;
				end
				contribution_valid <= 1'b0;
				if (voice_is16) state <= S_FINISH;
				else if (!ch_en_m) state <= S_ADVANCE;
				else if (ch_pcm_m) begin
					if (pcm_at_end) begin
						channel_reg[channel_base][0] <= 1'b0;
						state <= S_ADVANCE;
					end
					else begin

						sample_req <= ~sample_req;
						state <= S_PCM_WAIT;
					end
				end
				else if (channel_reg[channel_base][2] && envelope_delta >= 32'h80) begin
					channel_reg[channel_base][0] <= 1'b0;
					state <= S_ADVANCE;
				end
				else begin
					sound_ram_address <= 13'h1000
						+ {1'b0, channel_reg[channel_base + 7'd1][4:0], 7'd0}
						+ sample_offset[voice[3:0]][16:10];
					state <= S_WAVE_ADDR;
				end
			end

			S_PCM_WAIT: if (sample_ack == sample_req) begin
				wave_sample <= sample_dout;
				// Use the returned byte directly because nonblocking assignment
				// would otherwise mix the previous voice's sample.

				product_valid <= 1'b1;
				sample_offset[voice_wr] <= sample_offset[voice_wr] + {24'd0, pcm_step};
				state <= S_ADVANCE;
			end

			S_WAVE_ADDR: state <= S_WAVE_FETCH;
			S_WAVE_FETCH: begin
				wave_sample <= sound_ram_q[7:0];
				sound_ram_address <= {1'b0, channel_reg[channel_base + 7'd5][4:0], 7'd0}
					+ envelope_offset[voice[3:0]][16:10];
				state <= S_ENV_ADDR;
			end
			S_ENV_ADDR: state <= S_ENV_FETCH;
			S_ENV_FETCH: begin
				wave_volume <= sound_ram_q[7:0];

				product_valid <= 1'b1;
				sample_offset[voice_wr] <= sample_offset[voice_wr]
					+ ({channel_reg[channel_base + 7'd3],
						channel_reg[channel_base + 7'd2]} >> channel_reg[channel_base][7]);
				envelope_offset[voice_wr] <= envelope_offset[voice_wr]
					+ channel_reg[channel_base + 7'd4];
				state <= S_ADVANCE;
			end

			S_ADVANCE: begin
				contribution_left <= product_left * VOL_BASE;
				contribution_right <= product_right * VOL_BASE;
				contribution_valid <= product_valid;
				product_valid <= 1'b0;
				voice <= voice + 5'd1;
				voice_end <= voice_end + 4'd1;
				voice_is16 <= (voice_end == 4'd15);
				voice_wr <= voice_wr + 4'd1;
				state <= S_CHECK;
			end
			S_FINISH: begin
				audio_left <= saturate16(mix_left);
				audio_right <= saturate16(mix_right);
				audio_valid <= 1'b1;
				state <= S_IDLE;
			end
				default: state <= S_IDLE;
			endcase
		end
	end
end

endmodule
