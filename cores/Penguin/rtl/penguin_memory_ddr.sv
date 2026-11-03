// Penguin derivative: samples2MiB at canonical17MiB; work320KiB at19MiB.
// Request RAM port is18-bit WORD address; DDR storage remains byte-lane little-endian.
// MiSTer DDR3 transport for program, sample and graphics ROM plus board RAM.
// Each runtime client has an independent one-line cache. Sequential 68000
// instruction fetches therefore amortize DDR3 latency across four words.
// SPDX-License-Identifier: GPL-3.0-or-later

module penguin_memory_ddr
(
	input  logic        clk,
	input  logic        reset,

	input  logic        load_wr,
	input  logic [25:0] load_addr,
	input  logic  [7:0] load_data,
	output logic        load_wait,
	output logic        load_idle,
	output wire         transaction_idle,
	output wire         audio_guard,

	// Read the MRA's direct-to-DDR staging image back into the normal loader.
	input  logic [25:0] preload_addr,
	input  logic        preload_req,
	output logic [63:0] preload_data,
	output logic        preload_ack,

	input  logic [20:0] cpu_addr,
	input  logic        cpu_req,
	output logic [15:0] cpu_dout,
	(* altera_attribute = "-name ALLOW_SYNCH_CTRL_USAGE OFF" *)
	output logic        cpu_ack,

	input  logic [20:0] sound_addr,
	input  logic        sound_req,
	output logic  [7:0] sound_dout,
	output logic        sound_ack,

	input  logic [17:0] ram_word_addr,
	input  logic        ram_req,
	input  logic        ram_write,
	input  logic [15:0] ram_data,
	input  logic  [1:0] ram_be,
	output logic [15:0] ram_dout,
	(* altera_attribute = "-name ALLOW_SYNCH_CTRL_USAGE OFF" *) output logic        ram_ack,

	input  logic [24:0] gfx_addr,
	input  logic        gfx_req,
	output logic [255:0] gfx_dout,
	output logic        gfx_ack,

	output logic        ddr_clk,
	input  logic        ddr_busy,
	output logic  [7:0] ddr_burstcount,
	output logic [28:0] ddr_addr,
	input  logic [63:0] ddr_dout,
	input  logic        ddr_dout_ready,
	output logic        ddr_rd,
	output logic [63:0] ddr_din,
	output logic  [7:0] ddr_be,
	output logic        ddr_we
);

wire [18:0] ram_addr = {ram_word_addr,1'b0};

// DDRAM_ADDR is expressed in 64-bit words. Physical byte base 0x30000000.
localparam logic [28:0] DDR_WORD_BASE = 29'h06000000;

typedef enum logic [2:0] {
	IDLE, WAIT_CPU, WAIT_SOUND, WAIT_SOUND_CACHE, WAIT_RAM_READ, WAIT_RAM_WRITE, WAIT_GFX,
	WAIT_PRELOAD
} state_t;
state_t state;

logic [63:0] load_pack;
logic        load_pack_pending;
logic        gfx_turn;

logic        cpu_cache_valid;
logic [17:0] cpu_cache_tag;
logic [63:0] cpu_cache_data;
logic [20:0] cpu_addr_latched;
logic        cpu_req_latched;

logic [31:0] sound_cache_valid;
logic [17:0] sound_cache_tag [0:31];
(* ramstyle="M10K" *) logic [63:0] sound_cache_data [0:31];
logic [63:0] sound_cache_q;
logic [4:0] sound_replace,sound_hit_index;
// Keep hit detection independent of the priority encoder. Highest matching
// entry still wins, including duplicate tags, without a 32-entry priority cone.
(* keep *) logic [31:0] sound_hit_vector;
// Active-low six-input leaves avoid an extra preserved leaf inverter.
(* keep *) wire [5:0] sound_miss_group6;
genvar sound_group6_index;
generate for(sound_group6_index=0;sound_group6_index<5;sound_group6_index=sound_group6_index+1)begin: sound_hit_reduction6
    assign sound_miss_group6[sound_group6_index]=~|sound_hit_vector[sound_group6_index*6+:6];
end endgenerate
assign sound_miss_group6[5]=~|sound_hit_vector[31:30];
(* keep *) wire sound_cache_hit = ~&sound_miss_group6;
always_comb begin
    sound_hit_vector=0;
    for(integer i=0;i<32;i++)if(sound_cache_valid[i]&&sound_cache_tag[i]==sound_addr[20:3])begin
        sound_hit_vector[i]=1'b1;
    end
end
function automatic [2:0] sound_parallel8(input logic [7:0] h);
    begin
        sound_parallel8[2]=|h[7:4];
        sound_parallel8[1]=(|h[7:6]) || ((~|h[7:4]) && (|h[3:2]));
        sound_parallel8[0]=h[7] || ((~|h[7:6]) && h[5])
            || ((~|h[7:4]) && h[3]) || ((~|h[7:2]) && h[1]);
    end
endfunction
wire [2:0] sound_local0=sound_parallel8(sound_hit_vector[7:0]);
wire [2:0] sound_local1=sound_parallel8(sound_hit_vector[15:8]);
wire [2:0] sound_local2=sound_parallel8(sound_hit_vector[23:16]);
wire [2:0] sound_local3=sound_parallel8(sound_hit_vector[31:24]);
wire sound_above2_empty=~|sound_hit_vector[31:24];
wire sound_above1_empty=~|sound_hit_vector[31:16];
wire sound_above0_empty=~|sound_hit_vector[31:8];
assign sound_hit_index[4]=|sound_hit_vector[31:16];
assign sound_hit_index[3]=(|sound_hit_vector[31:24])
    || (sound_above1_empty && (|sound_hit_vector[15:8]));
assign sound_hit_index[2:0]=sound_local3
    | (sound_local2 & {3{sound_above2_empty}})
    | (sound_local1 & {3{sound_above1_empty}})
    | (sound_local0 & {3{sound_above0_empty}});
always_ff @(posedge clk)sound_cache_q<=sound_cache_data[sound_hit_index];
logic [20:0] sound_addr_latched;
logic        sound_req_latched;

logic        ram_cache_valid;
logic [15:0] ram_cache_tag;
logic [63:0] ram_cache_data;
logic [18:0] ram_addr_latched;
logic        ram_req_latched;

logic [24:0] gfx_addr_latched;
logic        gfx_req_latched;
logic  [2:0] gfx_burst_word;

wire cpu_pending = (cpu_req != cpu_ack);
wire sound_pending = (sound_req != sound_ack);
wire ram_pending = (ram_req != ram_ack);
wire gfx_pending = (gfx_req != gfx_ack);
wire cpu_cache_hit = cpu_cache_valid
	&& (cpu_cache_tag == cpu_addr[20:3]);

wire ram_cache_hit = ram_cache_valid
	&& (ram_cache_tag == ram_addr[18:3]);
// Known-one predicates preserve procedural-if behavior for X/Z as well.
wire idle_ram_outer = ((!load_wr && !load_pack_pending && !ddr_we && !ddr_rd) === 1'b1);
wire idle_ram_cached = ((ram_pending && !ram_write && ram_cache_hit) === 1'b1);
wire idle_free_port_claim = ((!ddr_busy && ((preload_req != preload_ack) || sound_pending)) === 1'b1);
wire idle_sound_hit_claim = ((sound_pending && sound_cache_hit) === 1'b1);
wire idle_ram_hit_grant = idle_ram_outer && idle_ram_cached && !idle_free_port_claim && !idle_sound_hit_claim;


// BEGIN CPU_ACK_PARALLEL: preserve original priority at the same clock edge.
wire idle_cpu_cached = ((cpu_pending && cpu_cache_hit) === 1'b1);
wire idle_ram_cache_claim = ((ram_pending && !ram_write && ram_cache_hit) === 1'b1);
wire idle_ram_port_claim = ((!ddr_busy && !audio_guard && ram_pending) === 1'b1);
wire cpu_cached_ack = (((state == IDLE) && idle_ram_outer && idle_cpu_cached
    && !idle_free_port_claim && !idle_sound_hit_claim
    && !idle_ram_cache_claim && !idle_ram_port_claim) === 1'b1);
wire cpu_completed_ack = (((state == WAIT_CPU) && ddr_dout_ready) === 1'b1);
always_ff @(posedge clk) begin
    if (reset) cpu_ack <= 1'b0;
    else begin
        unique case (1'b1)
            cpu_cached_ack: cpu_ack <= cpu_req;
            cpu_completed_ack: cpu_ack <= cpu_req_latched;
            default: cpu_ack <= cpu_ack;
        endcase
    end
end
// END CPU_ACK_PARALLEL

// BEGIN RAM_ACK_PARALLEL: same-edge, four-state procedural-if predicates.
wire ram_cached_ack = (((state == IDLE) && idle_ram_hit_grant) === 1'b1);
wire ram_completed_ack = ((((state == WAIT_RAM_READ) && ddr_dout_ready)
    || ((state == WAIT_RAM_WRITE) && !ddr_busy)) === 1'b1);
always_ff @(posedge clk) begin
    if (reset) ram_ack <= 1'b0;
    else begin
        unique case (1'b1)
            ram_cached_ack: ram_ack <= ram_req;
            ram_completed_ack: ram_ack <= ram_req_latched;
            default: ram_ack <= ram_ack;
        endcase
    end
end
// END RAM_ACK_PARALLEL

assign ddr_clk = clk;
// Graphics misses fetch an aligned group of four 64-bit tile rows. The
// outer graphics cache retains all four, amortizing DDR command latency
// without rendering future scanlines ahead of the physical raster.
assign ddr_burstcount = (state == WAIT_GFX) ? 8'd4 : 8'd1;
assign load_wait = ddr_busy || ddr_we || (state != IDLE) || ddr_rd;
assign load_idle = !load_pack_pending && !ddr_we && !ddr_busy
	&& (state == IDLE) && !ddr_rd;

function automatic [15:0] cpu_word_from_line;
	input [63:0] line;
	input [1:0] select;
	begin
		case (select)
			2'd0: cpu_word_from_line = {line[7:0], line[15:8]};
			2'd1: cpu_word_from_line = {line[23:16], line[31:24]};
			2'd2: cpu_word_from_line = {line[39:32], line[47:40]};
			default: cpu_word_from_line = {line[55:48], line[63:56]};
		endcase
	end
endfunction

function automatic [7:0] byte_from_line;
	input [63:0] line;
	input [2:0] select;
	begin
		case (select)
			3'd0: byte_from_line = line[7:0];
			3'd1: byte_from_line = line[15:8];
			3'd2: byte_from_line = line[23:16];
			3'd3: byte_from_line = line[31:24];
			3'd4: byte_from_line = line[39:32];
			3'd5: byte_from_line = line[47:40];
			3'd6: byte_from_line = line[55:48];
			default: byte_from_line = line[63:56];
		endcase
	end
endfunction

function automatic [63:0] gfx_row_from_line;
	input [63:0] line;
	begin
		// Match the four big-endian 16-bit words formerly returned by the
		// board SDRAM: byte 0 is the high byte of row word 0.
		gfx_row_from_line = {
			line[55:48], line[63:56],
			line[39:32], line[47:40],
			line[23:16], line[31:24],
			line[7:0], line[15:8]
		};
	end
endfunction

// BEGIN CPU_READ_PAYLOAD: completion arbitration remains unchanged.
always_ff @(posedge clk) begin
    if(reset) cpu_dout <= 16'd0;
    else if(state==IDLE && cpu_pending && cpu_cache_hit)
        cpu_dout <= cpu_word_from_line(cpu_cache_data,cpu_addr[2:1]);
    else if(state==WAIT_CPU && ddr_dout_ready)
        cpu_dout <= cpu_word_from_line(ddr_dout,cpu_addr_latched[2:1]);
end
// END CPU_READ_PAYLOAD
// BEGIN RAM_READ_PAYLOAD: acknowledgement arbitration remains unchanged.
// A cache value may be prepared while a higher-priority owner is serviced.
// Consumers only sample it after their request is acknowledged.
always_ff @(posedge clk) begin
    if (reset)
        ram_dout <= 16'd0;
    else if ((state == IDLE) && ram_pending && !ram_write && ram_cache_hit)
        ram_dout <= cpu_word_from_line(ram_cache_data,ram_addr[2:1]);
    else if ((state == WAIT_RAM_READ) && ddr_dout_ready)
        ram_dout <= cpu_word_from_line(ddr_dout,ram_addr_latched[2:1]);
end
// END RAM_READ_PAYLOAD
// BEGIN DDR_COMMAND_ADDRESS: no payload change during an outstanding command.
always_ff @(posedge clk) begin
    if (reset) ddr_addr <= 29'd0;
    else if (load_wr && !load_wait && (load_addr[2:0] == 3'd7))
        ddr_addr <= DDR_WORD_BASE + {6'd0, load_addr[25:3]};
    else if ((state == IDLE) && !ddr_busy && !load_wr && !load_pack_pending && !ddr_we && !ddr_rd) begin
        if (preload_req != preload_ack) ddr_addr <= DDR_WORD_BASE + {6'd0, preload_addr[25:3]};
        else if (sound_pending) ddr_addr <= DDR_WORD_BASE + 29'h00220000
							+ {11'd0, sound_addr[20:3]};
        else if (ram_pending && !audio_guard) ddr_addr <= DDR_WORD_BASE + 29'h00260000
							+ {13'd0, ram_addr[18:3]};
        else if (gfx_pending && (!cpu_pending || gfx_turn)) ddr_addr <= DDR_WORD_BASE + 29'h00080000
							+ {7'd0, gfx_addr[24:5], 2'b00};
        else if (cpu_pending && !audio_guard) ddr_addr <= DDR_WORD_BASE + {11'd0, cpu_addr[20:3]};
        else if (gfx_pending) ddr_addr <= DDR_WORD_BASE + 29'h00080000
							+ {7'd0, gfx_addr[24:5], 2'b00};
    end
end
// END DDR_COMMAND_ADDRESS
logic [3:0] audio_burst_hold;
assign audio_guard=sound_pending||(audio_burst_hold!=0);
always_ff @(posedge clk) begin
    if(reset)audio_burst_hold<=0;
    else if(sound_pending)audio_burst_hold<=4'd12;
    else if(audio_burst_hold!=0)audio_burst_hold<=audio_burst_hold-1'b1;
end

// BEGIN RAM_READ_ADMISSION: direct equivalent predicate, independent of priority encoding.
wire ram_read_admit = (state==IDLE) && !load_wr && !load_pack_pending && !ddr_we && !ddr_rd
    && !ddr_busy && (preload_req==preload_ack) && !audio_guard
    && ram_pending && !ram_write && !ram_cache_hit;
// END RAM_READ_ADMISSION
always_ff @(posedge clk) begin
	// Avalon requests stay asserted while waitrequest is high, then drop on
	// the first accepted cycle.
	if (!ddr_busy) begin
		ddr_rd <= 1'b0;
		ddr_we <= 1'b0;
	end

	if (reset) begin
		state <= IDLE;
		load_pack <= 64'd0;
		load_pack_pending <= 1'b0;
		gfx_turn <= 1'b1;
		cpu_cache_valid <= 1'b0;
		cpu_cache_tag <= 18'd0;
		cpu_cache_data <= 64'd0;
		cpu_addr_latched <= 21'd0;
		cpu_req_latched <= 1'b0;


		sound_cache_valid <= 32'd0;sound_replace<=0;


		sound_addr_latched <= 20'd0;
		sound_req_latched <= 1'b0;
		sound_dout <= 8'd0;
		sound_ack <= 1'b0;
		ram_cache_valid <= 1'b0;
		ram_cache_tag <= 14'd0;
		ram_cache_data <= 64'd0;
		ram_addr_latched <= 17'd0;
		ram_req_latched <= 1'b0;

		gfx_addr_latched <= 25'd0;
		gfx_req_latched <= 1'b0;
		gfx_burst_word <= 3'd0;
		gfx_dout <= 256'd0;
		gfx_ack <= 1'b0;
		preload_data <= 64'd0;
		preload_ack <= 1'b0;

		ddr_rd <= 1'b0;
		ddr_din <= 64'd0;
		ddr_be <= 8'hff;
		ddr_we <= 1'b0;
	end
	else begin
        // Independent cache-hit ack avoids the shared multi-client state cone.

		if (load_wr && !load_wait) begin
			cpu_cache_valid <= 1'b0;
			sound_cache_valid <= 32'd0;sound_replace<=0;
			ram_cache_valid <= 1'b0;
			case (load_addr[2:0])
				3'd0: begin load_pack[7:0]   <= load_data; load_pack_pending <= 1'b1; end
				3'd1: load_pack[15:8]  <= load_data;
				3'd2: load_pack[23:16] <= load_data;
				3'd3: load_pack[31:24] <= load_data;
				3'd4: load_pack[39:32] <= load_data;
				3'd5: load_pack[47:40] <= load_data;
				3'd6: load_pack[55:48] <= load_data;
				default: begin

					ddr_din <= {load_data, load_pack[55:0]};
					ddr_be <= 8'hff;
					ddr_we <= 1'b1;
					load_pack_pending <= 1'b0;
				end
			endcase
		end

		case (state)
			IDLE: begin
                    // Snapshot only while idle, independently of cache-hit
                    // decoding. Every admitted request captures on its original
                    // edge; WAIT states retain that exact payload/phase.
                    sound_addr_latched <= sound_addr;
                    sound_req_latched <= sound_req;
				if (!load_wr && !load_pack_pending && !ddr_we && !ddr_rd) begin
					if (!ddr_busy && (preload_req != preload_ack)) begin

						ddr_rd <= 1'b1;
						state <= WAIT_PRELOAD;
					end
					else if (sound_pending && sound_cache_hit) begin
                        state<=WAIT_SOUND_CACHE;
					end
					else if (!ddr_busy && sound_pending) begin

						ddr_rd <= 1'b1;
						state <= WAIT_SOUND;
					end
					else if (ram_pending && !ram_write && ram_cache_hit) begin


						gfx_turn <= 1'b1;
					end
					else if (!ddr_busy && !audio_guard && ram_pending) begin
						ram_addr_latched <= ram_addr;
						ram_req_latched <= ram_req;

						if (ram_write) begin
							ddr_din <= 64'd0;
							ddr_be <= 8'd0;
							if (ram_be[1]) begin
								ddr_din[{ram_addr[2:1],4'd0} +: 8] <= ram_data[15:8];
								ddr_be[{ram_addr[2:1],1'b0}] <= 1'b1;
							end
							if (ram_be[0]) begin
								ddr_din[{ram_addr[2:1],4'd0} + 5'd8 +: 8] <= ram_data[7:0];
								ddr_be[{ram_addr[2:1],1'b0} + 3'd1] <= 1'b1;
							end
							if (ram_cache_hit) begin
								if (ram_be[1]) ram_cache_data[
									{ram_addr[2:1],4'd0} +: 8] <= ram_data[15:8];
								if (ram_be[0]) ram_cache_data[
									{ram_addr[2:1],4'd0} + 5'd8 +: 8] <= ram_data[7:0];
							end
							ddr_we <= 1'b1;
							state <= WAIT_RAM_WRITE;
						end
						else begin
							ddr_rd <= 1'b1;

						end
					end
					else if (cpu_pending && cpu_cache_hit) begin


						gfx_turn <= 1'b1;
					end
					else if (!ddr_busy && gfx_pending
					         && (!cpu_pending || gfx_turn)) begin
						gfx_addr_latched <= gfx_addr;
						gfx_req_latched <= gfx_req;

						gfx_burst_word <= 3'd0;
						ddr_rd <= 1'b1;
						state <= WAIT_GFX;
					end
					else if (!ddr_busy && !audio_guard && cpu_pending) begin
						cpu_addr_latched <= cpu_addr;
						cpu_req_latched <= cpu_req;

						ddr_rd <= 1'b1;
						state <= WAIT_CPU;
					end
					else if (!ddr_busy && gfx_pending) begin
						gfx_addr_latched <= gfx_addr;
						gfx_req_latched <= gfx_req;

						gfx_burst_word <= 3'd0;
						ddr_rd <= 1'b1;
						state <= WAIT_GFX;
					end
				end
			end

			WAIT_CPU: if (ddr_dout_ready) begin
				cpu_cache_valid <= 1'b1;
				cpu_cache_tag <= cpu_addr_latched[20:3];
				cpu_cache_data <= ddr_dout;


				gfx_turn <= 1'b1;
				state <= IDLE;
			end

			WAIT_SOUND_CACHE:begin
                sound_dout<=byte_from_line(sound_cache_q,sound_addr_latched[2:0]);
                sound_ack<=sound_req_latched;gfx_turn<=1;state<=IDLE;
            end
            WAIT_SOUND: if (ddr_dout_ready) begin
				sound_cache_valid[sound_replace] <= 1'b1;
				sound_cache_tag[sound_replace] <= sound_addr_latched[20:3];
				sound_cache_data[sound_replace] <= ddr_dout;sound_replace<=sound_replace+1'b1;
				sound_dout <= byte_from_line(ddr_dout,
					sound_addr_latched[2:0]);
				sound_ack <= sound_req_latched;
				gfx_turn <= 1'b1;
				state <= IDLE;
			end

			WAIT_RAM_READ: if (ddr_dout_ready) begin
				ram_cache_valid <= 1'b1;
				ram_cache_tag <= ram_addr_latched[18:3];
				ram_cache_data <= ddr_dout;

				gfx_turn <= 1'b1;
				state <= IDLE;
			end

			WAIT_RAM_WRITE: if (!ddr_busy) begin

				gfx_turn <= 1'b1;
				state <= IDLE;
			end

			WAIT_GFX: if (ddr_dout_ready) begin
				gfx_dout[gfx_burst_word * 64 +: 64]
					<= gfx_row_from_line(ddr_dout);
				if (gfx_burst_word == 3'd3) begin
					gfx_ack <= gfx_req_latched;
					gfx_turn <= 1'b0;
					state <= IDLE;
				end
				else gfx_burst_word <= gfx_burst_word + 3'd1;
			end

			WAIT_PRELOAD: if (ddr_dout_ready) begin
				preload_data <= ddr_dout;
				preload_ack <= preload_req;
				state <= IDLE;
			end

			default: state <= IDLE;
		endcase
        if(ram_read_admit) state <= WAIT_RAM_READ;
	end
end

assign transaction_idle=(state==IDLE)&&!ddr_rd&&!ddr_we;
endmodule
