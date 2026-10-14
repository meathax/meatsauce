// Sega 315-5293/315-5295 linked-list sprite system. This is a streaming
// translation of MAME segaic24.cpp: entries are collected in list order and
// rendered backwards into an inactive scanline buffer. Sprite descriptors,
// indirect palette tables, and 4-bpp tile data all share the 256 KiB sprite
// RAM and are fetched through aligned 128-bit bursts.

// One radix-4 restoring-divider step.  The sprite Y mapper divides an 18-bit
// numerator by a 9-bit zoom step.  At every step remainder<divisor, so after
// shifting in two dividend bits the trial remainder is below 4*divisor and a
// two-bit quotient digit (0..3) is exact.
module s24_sprite_ydiv_radix4_step (
	input  logic [17:0] dividend,
	input  logic [17:0] quotient,
	input  logic [18:0] remainder,
	input  logic [8:0]  divisor,
	output logic [17:0] next_quotient,
	output logic [18:0] next_remainder
);
	logic [18:0] shifted_remainder;
	logic [18:0] divisor_x2,divisor_x3;

	always_comb begin
		shifted_remainder={remainder[16:0],dividend[17:16]};
		divisor_x2={9'd0,divisor,1'b0};
		divisor_x3={10'd0,divisor}+divisor_x2;
		next_quotient={quotient[15:0],2'b00};
		next_remainder=shifted_remainder;
		if(shifted_remainder>=divisor_x3) begin
			next_remainder=shifted_remainder-divisor_x3;
			next_quotient[1:0]=2'd3;
		end else if(shifted_remainder>=divisor_x2) begin
			next_remainder=shifted_remainder-divisor_x2;
			next_quotient[1:0]=2'd2;
		end else if(shifted_remainder>={10'd0,divisor}) begin
			next_remainder=shifted_remainder-{10'd0,divisor};
			next_quotient[1:0]=2'd1;
		end
	end
endmodule

// Quartus 17 does not reliably infer the sprite line buffers from a
// three-port array (display read/clear plus renderer read/write).  Keep the
// behavioural model for Verilator, but map the FPGA implementation directly
// to the Cyclone V dual-port primitive so these buffers remain M10K-backed.
module s24_sprite_line_ram #(
    parameter int WIDTH = 34,
    parameter int ADDR_WIDTH = 12
) (
    input  logic clk,
    input  logic [ADDR_WIDTH-1:0] address_a,
    input  logic [WIDTH-1:0] data_a,
    input  logic wren_a,
    output logic [WIDTH-1:0] q_a,
    input  logic [ADDR_WIDTH-1:0] address_b,
    input  logic [WIDTH-1:0] data_b,
    input  logic wren_b,
    output logic [WIDTH-1:0] q_b
);
`ifdef VERILATOR
    logic [WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];
    always_ff @(posedge clk) begin
        q_a <= mem[address_a];
        q_b <= mem[address_b];
        if(wren_a) mem[address_a] <= data_a;
        if(wren_b) mem[address_b] <= data_b;
    end
`else
    altsyncram ram (
        .clock0(clk), .address_a(address_a), .data_a(data_a),
        .wren_a(wren_a), .q_a(q_a),
        .clock1(clk), .address_b(address_b), .data_b(data_b),
        .wren_b(wren_b), .q_b(q_b),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b1)
    );
    defparam
        ram.operation_mode = "BIDIR_DUAL_PORT",
        ram.width_a = WIDTH,
        ram.width_b = WIDTH,
        ram.widthad_a = ADDR_WIDTH,
        ram.widthad_b = ADDR_WIDTH,
        ram.numwords_a = (1 << ADDR_WIDTH),
        ram.numwords_b = (1 << ADDR_WIDTH),
        ram.ram_block_type = "M10K",
        ram.intended_device_family = "Cyclone V",
        ram.lpm_type = "altsyncram",
        // UNREGISTERED keeps the synthesized read at the 1-clock latency the
        // `ifdef VERILATOR model above implements; CLOCK0/CLOCK1 added a
        // second output register and displaced sprite line data by a clock on
        // hardware only (see the port-A note below -- this is the same failure
        // that "previously made FPGA sprites disappear").
        ram.outdata_reg_a = "UNREGISTERED",
        ram.outdata_reg_b = "UNREGISTERED",
        // Quartus 17 only accepts OLD_DATA for mixed-port collisions in a
        // BIDIR_DUAL_PORT M10K.  Port A is read-only; its clear write is
        // intentionally disabled below and the inactive bank is cleared by
        // port B in S_CLEAR. This avoids relying on unsupported same-port
        // OLD_DATA semantics, which previously made FPGA sprites disappear.
        ram.read_during_write_mode_mixed_ports = "OLD_DATA",
        ram.read_during_write_mode_port_a = "NEW_DATA_NO_NBE_READ",
        ram.read_during_write_mode_port_b = "NEW_DATA_NO_NBE_READ",
        ram.width_byteena_a = 1,
        ram.width_byteena_b = 1,
        ram.power_up_uninitialized = "FALSE";
`endif
endmodule

// The original sprite generator reads a dedicated one-cycle RAM.  System 24's
// complete sprite RAM lives in SDRAM in this core, where a dependent linked-
// list read costs many clocks.  Keep a small coherent working set on chip.
// Port A is the renderer lookup; port B fills a complete aligned burst after
// an SDRAM miss. Tags and validity live beside this RAM in s24_sprite so a CPU
// write can invalidate one burst without clearing or rewriting the data RAM.
module s24_sprite_burst_cache_ram (
	input  logic         clk,
	input  logic [7:0]   read_addr,
	output logic [127:0] read_data,
	input  logic [7:0]   write_addr,
	input  logic [127:0] write_data,
	input  logic         write_enable
);
`ifdef VERILATOR
	logic [127:0] mem [0:255];
	always_ff @(posedge clk) begin
		read_data<=mem[read_addr];
		if(write_enable) mem[write_addr]<=write_data;
	end
`else
	logic [127:0] q_a;
	altsyncram ram (
		.clock0(clk),.address_a(read_addr),.data_a(128'd0),
		.wren_a(1'b0),.q_a(q_a),
		.clock1(clk),.address_b(write_addr),.data_b(write_data),
		.wren_b(write_enable),.q_b(),
		.aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),
		.addressstall_b(1'b0),.byteena_a(1'b1),.byteena_b(1'b1),
		.clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),
		.clocken3(1'b1),.eccstatus(),.rden_a(1'b1),.rden_b(1'b0)
	);
	assign read_data=q_a;
	defparam
		ram.operation_mode="BIDIR_DUAL_PORT",
		ram.width_a=128,
		ram.width_b=128,
		ram.widthad_a=8,
		ram.widthad_b=8,
		ram.numwords_a=256,
		ram.numwords_b=256,
		ram.ram_block_type="M10K",
		ram.intended_device_family="Cyclone V",
		ram.lpm_type="altsyncram",
		ram.outdata_reg_a="UNREGISTERED",
		ram.read_during_write_mode_mixed_ports="OLD_DATA",
		ram.width_byteena_a=1,
		ram.width_byteena_b=1,
		ram.power_up_uninitialized="FALSE";
`endif
endmodule

// A descriptor/clip pair is read as a packed pair while only one half is
// written during list collection. Separate low/high arrays give Quartus one
// clean write port per inferred RAM instead of a variable part-select write.
module s24_sprite_pair_ram #(
    parameter int WIDTH = 128,
    parameter int ADDR_WIDTH = 9,
    parameter int PACKED_WIDTH = WIDTH
) (
    input logic clk,
    input logic [ADDR_WIDTH-1:0] read_addr,
    output logic [WIDTH*2-1:0] read_data,
    input logic [ADDR_WIDTH-1:0] write_addr,
    input logic [WIDTH-1:0] write_data,
    input logic write_enable,
    input logic write_high
);
    // The renderer consumes six descriptor fields (81 bits) and six clip
    // fields (38 bits). Packing those fields removes dead q_a bits from the
    // generated M10K without changing the externally visible record.
    //
    // Descriptor words 2 and 3 carry the sprite's tile-data base and its
    // indirect-palette base. Both are read at render time via
    // d2/d3 = burst_word(descriptor,2|3). They were absent from the original
    // 49-bit packing, so unpack_word's '0 fill silently forced tile_base and
    // palette_base to zero for every sprite: geometry (w1/w4/w5) stayed
    // correct while every sprite fetched its pixels and its colour table from
    // word 0 of sprite RAM -- the descriptor list itself. Because nothing is
    // transparent unless the INDIRECT colour is zero, that rendered each
    // sprite as a solid filled box at the right position and size.
    function automatic logic [PACKED_WIDTH-1:0] pack_word(
        input logic [WIDTH-1:0] value
    );
        begin
            pack_word='0;
            if(PACKED_WIDTH==81) begin
                pack_word[0]=value[13];
                pack_word[16:1]=value[31:16];
                pack_word[32:17]=value[79:64];
                pack_word[48:33]=value[95:80];
                pack_word[64:49]=value[47:32];   // w2: tile-data base
                pack_word[80:65]=value[63:48];   // w3: indirect palette base
            end else if(PACKED_WIDTH==38) begin
                pack_word[0]=value[80];
                pack_word[1]=value[77];
                pack_word[10:2]=value[56:48];
                pack_word[19:11]=value[40:32];
                pack_word[28:20]=value[24:16];
                pack_word[37:29]=value[8:0];
            end else begin
                pack_word=value[PACKED_WIDTH-1:0];
            end
        end
    endfunction

    function automatic logic [WIDTH-1:0] unpack_word(
        input logic [PACKED_WIDTH-1:0] value
    );
        begin
            unpack_word='0;
            if(PACKED_WIDTH==81) begin
                unpack_word[13]=value[0];
                unpack_word[31:16]=value[16:1];
                unpack_word[79:64]=value[32:17];
                unpack_word[95:80]=value[48:33];
                unpack_word[47:32]=value[64:49];   // w2: tile-data base
                unpack_word[63:48]=value[80:65];   // w3: indirect palette base
            end else if(PACKED_WIDTH==38) begin
                unpack_word[80]=value[0];
                unpack_word[77]=value[1];
                unpack_word[56:48]=value[10:2];
                unpack_word[40:32]=value[19:11];
                unpack_word[24:16]=value[28:20];
                unpack_word[8:0]=value[37:29];
            end else begin
                unpack_word[PACKED_WIDTH-1:0]=value;
            end
        end
    endfunction
`ifdef VERILATOR
    logic [PACKED_WIDTH-1:0] mem_lo [0:(1<<ADDR_WIDTH)-1];
    logic [PACKED_WIDTH-1:0] mem_hi [0:(1<<ADDR_WIDTH)-1];
    always_ff @(posedge clk) begin
        read_data <= {unpack_word(mem_hi[read_addr]),
                      unpack_word(mem_lo[read_addr])};
        if(write_enable) begin
            if(write_high) mem_hi[write_addr] <= pack_word(write_data);
            else mem_lo[write_addr] <= pack_word(write_data);
        end
    end
`else
    logic [PACKED_WIDTH-1:0] q_lo,q_hi;
    altsyncram ram_lo (
        .clock0(clk), .address_a(read_addr), .data_a({PACKED_WIDTH{1'b0}}),
        .wren_a(1'b0), .q_a(q_lo),
        .clock1(clk), .address_b(write_addr), .data_b(pack_word(write_data)),
        .wren_b(write_enable && !write_high), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b0)
    );
    altsyncram ram_hi (
        .clock0(clk), .address_a(read_addr), .data_a({PACKED_WIDTH{1'b0}}),
        .wren_a(1'b0), .q_a(q_hi),
        .clock1(clk), .address_b(write_addr), .data_b(pack_word(write_data)),
        .wren_b(write_enable && write_high), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b0)
    );
    // q_lo/q_hi are already registered by the M10K output registers.  A
    // second fabric register here made hardware reads one cycle later than
    // the behavioural Verilator model and displaced descriptor/clip pairs.
    assign read_data = {unpack_word(q_hi),unpack_word(q_lo)};
    defparam
        ram_lo.operation_mode = "BIDIR_DUAL_PORT",
        ram_hi.operation_mode = "BIDIR_DUAL_PORT",
        ram_lo.width_a = PACKED_WIDTH, ram_hi.width_a = PACKED_WIDTH,
        ram_lo.width_b = PACKED_WIDTH, ram_hi.width_b = PACKED_WIDTH,
        ram_lo.widthad_a = ADDR_WIDTH, ram_hi.widthad_a = ADDR_WIDTH,
        ram_lo.widthad_b = ADDR_WIDTH, ram_hi.widthad_b = ADDR_WIDTH,
        ram_lo.numwords_a = (1 << ADDR_WIDTH),
        ram_hi.numwords_a = (1 << ADDR_WIDTH),
        ram_lo.numwords_b = (1 << ADDR_WIDTH),
        ram_hi.numwords_b = (1 << ADDR_WIDTH),
        ram_lo.ram_block_type = "M10K", ram_hi.ram_block_type = "M10K",
        ram_lo.intended_device_family = "Cyclone V",
        ram_hi.intended_device_family = "Cyclone V",
        ram_lo.lpm_type = "altsyncram", ram_hi.lpm_type = "altsyncram",
        // 1-clock read, matching the `ifdef VERILATOR model above. CLOCK0
        // added a second output register, so S_SCAN_PREFETCH/S_SCAN read the
        // PREVIOUS address's descriptor/clip pair on hardware only.
        ram_lo.outdata_reg_a = "UNREGISTERED",
        ram_hi.outdata_reg_a = "UNREGISTERED",
        // Without this, Quartus defaults mixed-port read-during-write to
        // DONT_CARE and returns UNPREDICTABLE data on a read/write address
        // collision, while Verilator deterministically returns OLD data --
        // another silicon-only divergence. Match the other RAMs explicitly.
        ram_lo.read_during_write_mode_mixed_ports = "OLD_DATA",
        ram_hi.read_during_write_mode_mixed_ports = "OLD_DATA",
        ram_lo.width_byteena_a = 1, ram_hi.width_byteena_a = 1,
        ram_lo.width_byteena_b = 1, ram_hi.width_byteena_b = 1,
        ram_lo.power_up_uninitialized = "FALSE",
        ram_hi.power_up_uninitialized = "FALSE";
`endif
endmodule

// Active scanline entries are copied from the MAME-ordered descriptor cache
// during the vertical filter. Rendering then reads the selected descriptor and
// clip pair directly instead of performing an index-RAM read followed by a
// second descriptor-RAM read for every visible sprite.
module s24_sprite_active_ram #(
    parameter int WIDTH = 209,
    parameter int ADDR_WIDTH = 10,
    parameter int PACKED_WIDTH = WIDTH
) (
    input logic clk,
    input logic [ADDR_WIDTH-1:0] read_addr,
    output logic [WIDTH-1:0] read_data,
    input logic [ADDR_WIDTH-1:0] write_addr,
    input logic [WIDTH-1:0] write_data,
    input logic write_enable
);
    // Active entries use the same 81-bit descriptor and 38-bit clip payloads
    // as the pair RAM, packed into one 119-bit M10K word.  The descriptor
    // occupies value[208:81], so word 2 is value[128:113] and word 3 is
    // value[144:129]; both must be carried or the render-time tile_base and
    // palette_base collapse to zero (see s24_sprite_pair_ram above).
    function automatic logic [PACKED_WIDTH-1:0] pack_word(
        input logic [WIDTH-1:0] value
    );
        begin
            pack_word='0;
            if(PACKED_WIDTH==119) begin
                pack_word[0]=value[94];
                pack_word[16:1]=value[112:97];
                pack_word[32:17]=value[160:145];
                pack_word[48:33]=value[176:161];
                pack_word[102:87]=value[128:113];  // w2: tile-data base
                pack_word[118:103]=value[144:129]; // w3: indirect palette base
                pack_word[49]=value[80];
                pack_word[50]=value[77];
                pack_word[59:51]=value[56:48];
                pack_word[68:60]=value[40:32];
                pack_word[77:69]=value[24:16];
                pack_word[86:78]=value[8:0];
            end else begin
                pack_word=value[PACKED_WIDTH-1:0];
            end
        end
    endfunction

    function automatic logic [WIDTH-1:0] unpack_word(
        input logic [PACKED_WIDTH-1:0] value
    );
        begin
            unpack_word='0;
            if(PACKED_WIDTH==119) begin
                unpack_word[94]=value[0];
                unpack_word[112:97]=value[16:1];
                unpack_word[160:145]=value[32:17];
                unpack_word[176:161]=value[48:33];
                unpack_word[128:113]=value[102:87];  // w2: tile-data base
                unpack_word[144:129]=value[118:103]; // w3: indirect palette base
                unpack_word[80]=value[49];
                unpack_word[77]=value[50];
                unpack_word[56:48]=value[59:51];
                unpack_word[40:32]=value[68:60];
                unpack_word[24:16]=value[77:69];
                unpack_word[8:0]=value[86:78];
            end else begin
                unpack_word[PACKED_WIDTH-1:0]=value;
            end
        end
    endfunction
`ifdef VERILATOR
    logic [PACKED_WIDTH-1:0] mem [0:(1<<ADDR_WIDTH)-1];
    always_ff @(posedge clk) begin
        read_data <= unpack_word(mem[read_addr]);
        if(write_enable) mem[write_addr] <= pack_word(write_data);
    end
`else
    logic [PACKED_WIDTH-1:0] q_a;
    altsyncram ram (
        .clock0(clk), .address_a(read_addr), .data_a({PACKED_WIDTH{1'b0}}),
        .wren_a(1'b0), .q_a(q_a),
        .clock1(clk), .address_b(write_addr), .data_b(pack_word(write_data)),
        .wren_b(write_enable), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b0)
    );
    assign read_data = unpack_word(q_a);
    defparam
        ram.operation_mode = "BIDIR_DUAL_PORT",
        ram.width_a = PACKED_WIDTH,
        ram.width_b = PACKED_WIDTH,
        ram.widthad_a = ADDR_WIDTH,
        ram.widthad_b = ADDR_WIDTH,
        ram.numwords_a = (1 << ADDR_WIDTH),
        ram.numwords_b = (1 << ADDR_WIDTH),
        ram.ram_block_type = "M10K",
        ram.intended_device_family = "Cyclone V",
        ram.lpm_type = "altsyncram",
        // 1-clock read, matching the `ifdef VERILATOR model above. CLOCK0
        // made S_RENDER_PREFETCH/S_RENDER_WAIT consume the previous entry's
        // active-cache descriptor on hardware only.
        ram.outdata_reg_a = "UNREGISTERED",
        // Explicit OLD_DATA rather than Quartus's DONT_CARE default, which
        // returns unpredictable data on a read/write address collision while
        // Verilator deterministically returns OLD.
        ram.read_during_write_mode_mixed_ports = "OLD_DATA",
        ram.width_byteena_a = 1,
        ram.width_byteena_b = 1,
        ram.power_up_uninitialized = "FALSE";
`endif
endmodule

module s24_sprite (
    input  logic         clk,
    input  logic         reset,
    input  logic         ce_pixel,
    input  logic [9:0]   hcount,
    input  logic [9:0]   vcount,
    // The frontmost nontransparent candidate for each of the four sprite
    // priority groups. A later-list sprite that is blocked by tile priority
    // must not hide an earlier sprite from another group, so final selection
    // belongs in the mixer. Rank is the reverse-list position (larger is
    // nearer the front).
    output logic [13:0]  pixel0,
    output logic [13:0]  pixel1,
    output logic [13:0]  pixel2,
    output logic [13:0]  pixel3,
    output logic [10:0]  rank0,
    output logic [10:0]  rank1,
    output logic [10:0]  rank2,
    output logic [10:0]  rank3,
    output logic         mem_req,
    output logic [26:4]  mem_addr,
    input  logic [127:0] mem_data,
    input  logic         mem_ack,
    // Pulse when a CPU write to sprite RAM has completed. The tag is the
    // aligned 128-bit offset within the 256 KiB sprite window.
    input  logic         cache_invalidate,
    input  logic [13:0]  cache_invalidate_tag
);
    import s24_pkg::*;

    // MAME walks a 0x2000-entry linked-list budget.  The retained parent
    // profiles stay below 4096 normal descriptors; SSpirits reaches 3547 in
    // live play, so the former 1024-entry cache dropped the display-list
    // front. Keep the active-line cache at its proven 1024-entry size.
    localparam int STACK_DEPTH = 4096;
    localparam int STACK_BITS = 12;
    localparam int ACTIVE_BITS = 10;
    localparam logic [STACK_BITS:0] ACTIVE_COUNT_LIMIT = (1 << ACTIVE_BITS);
    localparam logic [STACK_BITS:0] STACK_COUNT_LIMIT = 13'd4096;
    localparam logic [STACK_BITS:0] STACK_LAST = 13'd4095;

	localparam int BURST_CACHE_ENTRIES=256;
	// Keep the asynchronous high-tag probe in fabric; only the wide data
	// payload consumes the four spare M10Ks budgeted for this cache.
	(* ramstyle="logic" *) logic [5:0] burst_cache_tag [0:BURST_CACHE_ENTRIES-1];
	(* ramstyle="logic" *) logic burst_cache_valid [0:BURST_CACHE_ENTRIES-1];
	logic [13:0] burst_request_tag,burst_lookup_tag;
	logic [7:0] burst_request_index,burst_lookup_index;
	logic [127:0] burst_cache_q,read_data;
	logic burst_cache_hit,cache_ack_pending,read_ack;
	logic burst_cache_fill;
	integer burst_cache_init;
	function automatic logic [7:0] burst_cache_index(input logic [13:0] tag);
		begin
			burst_cache_index=tag[7:0]^{2'b00,tag[13:8]};
		end
	endfunction

	// Sprite tiles are commonly allocated 0x100 bursts apart. Indexing only
	// with the low byte aliases those adjacent banks onto one cache entry and
	// can turn a heavily reused gameplay row into all misses. Fold the upper
	// tag bits into the existing eight-bit index; this preserves capacity and
	// M10K usage. Since index=L XOR {00,H}, the stored H and selected index
	// uniquely identify L, so comparing H is still an exact full-tag match.
	assign burst_request_index=burst_cache_index(burst_request_tag);
	assign burst_lookup_index=burst_cache_index(burst_lookup_tag);
	assign burst_cache_hit=burst_cache_valid[burst_request_index] &&
		burst_cache_tag[burst_request_index]==burst_request_tag[13:8];
	assign read_ack=mem_ack || cache_ack_pending;
	assign read_data=cache_ack_pending ? burst_cache_q : mem_data;
	assign burst_cache_fill=mem_req && mem_ack;

	s24_sprite_burst_cache_ram burst_cache_ram (
		.clk(clk),.read_addr(burst_request_index),
		.read_data(burst_cache_q),.write_addr(burst_lookup_index),
		.write_data(mem_data),.write_enable(burst_cache_fill));

	// Valid/high-tag storage is deliberately separate from the M10K data array.
	// Invalidation wins a same-burst fill, so a read racing a completed CPU
	// store can never resurrect the older SDRAM contents.
	always_ff @(posedge clk) begin
		if(reset) begin
			for(burst_cache_init=0;burst_cache_init<BURST_CACHE_ENTRIES;
				burst_cache_init=burst_cache_init+1)
				burst_cache_valid[burst_cache_init]<=1'b0;
		end else begin
			if(burst_cache_fill) begin
				burst_cache_tag[burst_lookup_index]<=burst_lookup_tag[13:8];
				burst_cache_valid[burst_lookup_index]<=1'b1;
			end
			if(cache_invalidate)
				burst_cache_valid[burst_cache_index(cache_invalidate_tag)]<=1'b0;
		end
	end

    // {valid, reverse-list rank, 14-bit palette/shadow pixel}. Keeping one
    // candidate per priority group reproduces MAME's rule that a tile-blocked
    // front sprite leaves the priority bitmap unlocked for earlier sprites.
    // Port A feeds the visible scanline while port B performs the renderer's
    // read-before-write validity check and pixel update.
    // Complete normal descriptors are buffered once per frame. The small
    // index stack is then reused as the active-scanline list.
    // Two adjacent descriptors share each wide RAM word.  The per-line
    // active filter consumes the pair together, halving the scan cost for
    // long lists such as SSpirits' 3547 normal descriptors without storing
    // any additional descriptor bits.
    // {valid, flags, top, left, bottom, right}; raw clip coordinates are kept
    // because the -8 X origin and reverse-Y rule are applied while rendering.
    logic [3:0] line_b_wren;
    logic [1:0] line_b_category [0:3];
    localparam int LINE_BANKS = 8;
    localparam int LINE_BANK_BITS = 3;
    // Each bank advances its own generation and scrubs one of its 128 packed
    // X words on every fill. An 8-bit generation therefore cannot wrap until
    // every word has been cleared twice. Keeping the tag at 8 bits also makes
    // the complete line word 34 bits, fitting each 1024-deep RAM in four M10Ks
    // instead of five without changing ports, latency, or address mapping.
    localparam int LINE_GEN_WIDTH = 8;
    localparam int LINE_WIDTH = LINE_GEN_WIDTH + 1 + 11 + 14;
    logic [9:0] line_b_addr [0:3];
    logic [LINE_WIDTH-1:0] line_b_data [0:3];
    logic descriptor_write_enable,descriptor_write_high;
    logic [STACK_BITS-2:0] descriptor_write_addr;
    logic [127:0] descriptor_write_data;
    logic [80:0] clip_write_data;

    s24_sprite_pair_ram #(.WIDTH(128),.ADDR_WIDTH(STACK_BITS-1),.PACKED_WIDTH(81)) descriptor_stack_ram (
        .clk(clk),.read_addr(descriptor_read_pair),
        .read_data(descriptor_stack_pair_q),.write_addr(descriptor_write_addr),
        .write_data(descriptor_write_data),.write_enable(descriptor_write_enable),
        .write_high(descriptor_write_high));
    s24_sprite_pair_ram #(.WIDTH(81),.ADDR_WIDTH(STACK_BITS-1),.PACKED_WIDTH(38)) clip_stack_ram (
        .clk(clk),.read_addr(descriptor_read_pair),
        .read_data(clip_stack_pair_q),.write_addr(descriptor_write_addr),
        .write_data(clip_write_data),.write_enable(descriptor_write_enable),
        .write_high(descriptor_write_high));
    logic [255:0] descriptor_stack_pair2_q;
    logic [161:0] clip_stack_pair2_q;
    logic [STACK_BITS-2:0] descriptor_read_pair2;
    s24_sprite_pair_ram #(.WIDTH(128),.ADDR_WIDTH(STACK_BITS-1),.PACKED_WIDTH(81)) descriptor_stack_ram2 (
        .clk(clk),.read_addr(descriptor_read_pair2),
        .read_data(descriptor_stack_pair2_q),.write_addr(descriptor_write_addr),
        .write_data(descriptor_write_data),.write_enable(descriptor_write_enable),
        .write_high(descriptor_write_high));
    s24_sprite_pair_ram #(.WIDTH(81),.ADDR_WIDTH(STACK_BITS-1),.PACKED_WIDTH(38)) clip_stack_ram2 (
        .clk(clk),.read_addr(descriptor_read_pair2),
        .read_data(clip_stack_pair2_q),.write_addr(descriptor_write_addr),
        .write_data(clip_write_data),.write_enable(descriptor_write_enable),
        .write_high(descriptor_write_high));

    logic [ACTIVE_BITS-1:0] active_cache_read_addr,active_cache_write_addr;
    logic [208:0] active_cache_q,active_cache_write_data;
    logic active_cache_write_enable;
    logic [127:0] active_render_descriptor;
    logic [80:0] active_render_clip;
    s24_sprite_active_ram #(.ADDR_WIDTH(ACTIVE_BITS),.PACKED_WIDTH(119)) active_cache_ram (
        .clk(clk),.read_addr(active_cache_read_addr),
        .read_data(active_cache_q),.write_addr(active_cache_write_addr),
        .write_data(active_cache_write_data),
        .write_enable(active_cache_write_enable));

    function automatic logic [15:0] burst_word(
        input logic [127:0] data,input logic [2:0] index
    );
        burst_word = data[index*16 +: 16];
    endfunction

    function automatic logic [26:4] sprite_burst(input logic [16:0] word_offset);
        begin
            sprite_burst = SDR_SPRITE_BASE[26:4] + {9'd0,word_offset[16:3]};
        end
    endfunction

    function automatic logic [7:0] palette_entry(
        input logic [127:0] palette_data,input logic [3:0] pen
    );
        logic [15:0] pair;
        begin
            pair = burst_word(palette_data,pen[3:1]);
            palette_entry = pen[0] ? pair[7:0] : pair[15:8];
        end
    endfunction

    function automatic logic [11:0] offset12(input logic signed [12:0] value);
        offset12 = value[11:0];
    endfunction

    function automatic logic [10:0] source_row_delta(
        input logic signed [12:0] value
    );
        source_row_delta = value[10:0];
    endfunction

    typedef enum logic [4:0] {
        S_IDLE,S_CLEAR,S_LIST_REQ,S_LIST_WAIT,S_SCAN_PREFETCH,S_SCAN,S_SCAN_SECOND,S_SCAN_QUAD_DRAIN,
        S_RENDER_PREFETCH,S_RENDER_REQ,
        S_RENDER_WAIT,S_RENDER_SETUP,S_YDIV,S_YMAP,S_PALETTE_WAIT,S_X_SOURCE,S_DATA_WAIT,S_X_EMIT,S_X_EMIT4,
        S_NEXT_SPRITE
    } state_t;
    state_t state;

    logic [LINE_BANK_BITS-1:0] display_bank,fill_bank;
    logic [LINE_BANKS-1:0] line_valid;
    // Explicit ownership state for the producer. line_valid is deliberately
    // cleared while a bank is being rendered, but keeping ownership separate
    // prevents a boundary/reclaim decision from treating an in-flight bank as
    // free on FPGA RAM implementations with different read timing.
    logic [LINE_BANKS-1:0] bank_filling;
    // Epoch captured when the producer claims a bank. A long line may finish
    // after the visible-frame boundary has retired every queued line; never
    // resurrect that previous-frame result as valid in the new frame.
    logic fill_epoch;
    logic [9:0] display_read_addr;
    logic [LINE_WIDTH-1:0] line0_display_q [0:3];
    logic [LINE_WIDTH-1:0] line1_display_q [0:3];
    logic [LINE_WIDTH-1:0] line2_display_q [0:3];
    logic [LINE_WIDTH-1:0] line3_display_q [0:3];
    logic [LINE_WIDTH-1:0] line0_render_q [0:3];
    logic [LINE_WIDTH-1:0] line1_render_q [0:3];
    logic [LINE_WIDTH-1:0] line2_render_q [0:3];
    logic [LINE_WIDTH-1:0] line3_render_q [0:3];
    logic [LINE_WIDTH-1:0] line0_display_sel,line1_display_sel;
    logic [LINE_WIDTH-1:0] line2_display_sel,line3_display_sel;
    logic [1:0] display_lane;
    // A full 496-word clear consumed most of the line-render budget.  Tag
    // each pixel with the generation of the bank currently being filled so
    // stale transparent pixels are rejected without a destructive clear.
    logic [LINE_GEN_WIDTH-1:0] fill_generation;
    logic [LINE_GEN_WIDTH-1:0] bank_generation [0:LINE_BANKS-1];
    logic [8:0] bank_line_y [0:LINE_BANKS-1];
    logic [8:0] target_y;
    logic [8:0] render_next_target;
    logic [LINE_BANK_BITS-1:0] next_display_bank;
    logic next_display_ready;
    logic [LINE_BANK_BITS-1:0] fill_candidate;
    logic fill_candidate_valid;
    logic [9:0] next_display_line;
    integer bank_scan;
    integer reclaim_scan;
    logic [12:0] list_index;
    logic [13:0] list_seen;
    logic list_cache_valid;
    logic cache_refresh_pending;
    logic frame_epoch;
    logic frame_boundary;
    logic [15:0] current_clip_flags,current_clip_top,current_clip_left;
    logic [15:0] current_clip_bottom,current_clip_right;
    logic current_clip_valid;
    logic [STACK_BITS:0] stack_count,render_pos;
    logic [STACK_BITS-1:0] stack_head;
    logic [STACK_BITS-1:0] stack_write_slot;
    logic [255:0] descriptor_stack_pair_q;
    logic [161:0] clip_stack_pair_q;
    logic [127:0] descriptor_stack_q,scan_descriptor1;
    logic [80:0] clip_stack_q,scan_clip1;
    logic [127:0] scan_second_descriptor;
    logic [80:0] scan_second_clip;
    logic [80:0] render_clip;
    logic [127:0] descriptor,palette_table,data_cache;
    (* ramstyle="MLAB, no_rw_check" *) logic [127:0] palette_cache_data [0:7];
    // Eight-entry tags are intentionally implemented as fabric registers.
    // They are tiny and share the renderer clock; allowing Quartus to infer a
    // RAM here only adds pass-through logic and a 276020 diagnostic.
    (* ramstyle="logic" *) logic [13:0] palette_cache_tags [0:7];
    logic [7:0] palette_cache_valid;
    logic [2:0] palette_cache_index;
    logic palette_cache_hit;
    logic [13:0] data_cache_tag;
    logic data_cache_valid;
    logic [16:0] lane_line_value [0:3];
    logic signed [13:0] lane_dest_x [0:3];
    logic [10:0] lane_col [0:3];
    logic [2:0] lane_within_x [0:3];
    logic [15:0] lane_data_word [0:3];
    logic [16:0] lane_word [0:3];
    logic [13:0] lane_tag [0:3];
    logic [3:0] lane_pen [0:3];
    logic [7:0] lane_color [0:3];
    integer lane_calc,lane_write;
    integer line_phys;

    logic [8:0] zoomx_step,zoomy_step;
    logic [5:0] x_accum,y_accum;
    logic [2:0] emit_count;
    logic [10:0] source_row,source_column,total_rows,total_columns;
    logic signed [12:0] dest_y,dest_x;
    logic flipx,flipy;
    logic [7:0] size_x_tiles;
    // Sprite dimensions are powers of two. Keep the encoded width exponent
    // and the vertical reverse mask beside the dimensions so the address
    // path does not rebuild a subtractor from the live render state.
    logic [2:0] size_x_shift,size_y_shift;
    logic [7:0] size_y_mask;
    logic [16:0] wanted_word;
    logic [3:0] wanted_nibble;
    logic [3:0] current_pen;
    logic [7:0] mapped_color;
    logic [16:0] line_value;
    logic vertical_allowed;
    logic signed [12:0] clip_min_x,clip_max_x,clip_first,clip_last;
    logic signed [12:0] descriptor_origin_x;
    logic [12:0] descriptor_output_width;
    logic signed [13:0] descriptor_right_x;

    logic [15:0] d2,d3,d5;
    // Quartus 17 cannot apply a part-select directly to a function call.
    // Decode the active burst once so the sequential state machine can use
    // ordinary signals for descriptor fields.
    logic [15:0] mem_w0,mem_w1,mem_w2,mem_w3,mem_w4,mem_w5;
    logic [13:0] palette_base;
    logic [16:0] tile_base;
    logic [7:0] tile_x,tile_y;
    logic [2:0] within_x,within_y;
    logic [17:0] word_calc;
    logic [13:0] tile_row_offset;
    logic [13:0] tile_ordinal;
    logic [13:0] wanted_tag;
    logic [15:0] wanted_data_word;
    logic [8:0] x_sum,y_sum;
    logic [8:0] descriptor_zoomy_step;
    logic [10:0] descriptor_total_rows;
    logic signed [12:0] descriptor_origin_y;
    logic signed [13:0] descriptor_bottom_y;
    logic [17:0] ydiv_dividend,ydiv_quotient;
    logic [18:0] ydiv_remainder,ydiv_next_remainder;
    logic [8:0] ydiv_divisor;
    logic [10:0] ydiv_total_rows;
    logic [4:0] ydiv_count;
    logic [17:0] ydiv_next_quotient;
    logic signed [9:0] ydiv_adjust_value;
    logic [11:0] descriptor_target_offset;
    logic [STACK_BITS:0] scan_pos,active_count;
    logic [STACK_BITS:0] active_append_pos;
    logic [STACK_BITS-1:0] stack_scan_slot;
    logic [STACK_BITS-2:0] descriptor_read_pair;
    logic [15:0] scan_w1,scan_w4,scan1_w1,scan1_w4;
    logic [15:0] render_w0,render_w1,render_w4,render_w5;
    logic [8:0] render_zoomx_step;
    logic [19:0] descriptor_width_sum;
    logic [8:0] list_zoomy_step;
    logic [12:0] list_height;
    logic [19:0] list_height_sum;
    logic signed [12:0] list_origin_y;
    logic signed [13:0] list_bottom_y;
    logic [8:0] scan_zoomy_step;
    logic [19:0] scan_height_sum;
    logic [12:0] scan_height;
    logic signed [12:0] scan_origin_y;
    logic signed [13:0] scan_bottom_y;
    logic scan_vertical_allowed,scan_active;
    logic [8:0] scan1_zoomy_step;
    logic [19:0] scan1_height_sum;
    logic [12:0] scan1_height;
    logic signed [12:0] scan1_origin_y;
    logic signed [13:0] scan1_bottom_y;
    logic scan1_vertical_allowed,scan1_active;
    logic [127:0] scan_descriptor2,scan_descriptor3;
    logic [80:0] scan_clip2,scan_clip3;
    logic [15:0] scan2_w1,scan2_w4,scan3_w1,scan3_w4;
    logic [8:0] scan2_zoomy_step,scan3_zoomy_step;
    logic [19:0] scan2_height_sum,scan3_height_sum;
    logic [12:0] scan2_height,scan3_height;
    logic signed [12:0] scan2_origin_y,scan3_origin_y;
    logic signed [13:0] scan2_bottom_y,scan3_bottom_y;
    logic scan2_vertical_allowed,scan3_vertical_allowed;
    logic scan2_active,scan3_active;
    logic scan_pair_valid;
    logic scan_quad_valid;
    logic [2:0] scan_advance;
    logic [STACK_BITS:0] scan_next_pos;
    logic [STACK_BITS-1:0] scan_next_slot;
    logic scan_second_last;
    logic [2:0] scan_quad_active_count,scan_quad_pending_count;
    logic scan_quad_last;
    logic [127:0] scan_quad_first_descriptor;
    logic [80:0] scan_quad_first_clip;
    logic [127:0] scan_quad_pending_descriptor [0:2];
    logic [80:0] scan_quad_pending_clip [0:2];
    logic [127:0] scan_quad_batch_pending_descriptor [0:2];
    logic [80:0] scan_quad_batch_pending_clip [0:2];
    logic [127:0] scan_quad_descriptor [0:3];
    logic [80:0] scan_quad_clip [0:3];
    logic scan_quad_active [0:3];
    integer scan_quad_i,scan_quad_seen;
    logic signed [12:0] active_setup_origin_x;
    logic signed [13:0] active_setup_right_x;
    logic signed [12:0] active_setup_origin_y;
    logic signed [13:0] active_setup_bottom_y;
    logic [12:0] active_setup_width;
    logic [8:0] active_setup_zoomy_step;
    logic [10:0] active_setup_total_rows;
    logic signed [12:0] active_setup_clip_min_x,active_setup_clip_max_x;
    logic signed [12:0] active_setup_clip_first,active_setup_clip_last;
    logic active_setup_vertical_allowed;
    logic [11:0] active_setup_target_offset;
    // The active descriptor set is unchanged between vertical entry/exit
    // events.  Build a conservative event bitmap while the linked list is
    // cached, then reuse the previous line's filtered list on ordinary lines.
    // This removes the 1004-entry scan from every raster line without
    // changing MAME's descriptor order or clip semantics.
    logic [383:0] line_boundary;
    logic active_list_valid;

    // STACK_DEPTH is a power of two; assignment truncation performs wrap.
    // Once full, overwrite the oldest cached descriptor so the bounded ring
    // retains MAME's newest/frontmost list entries.
    assign stack_write_slot=(stack_count<STACK_COUNT_LIMIT)
                            ? stack_count[STACK_BITS-1:0] : stack_head;
    assign frame_boundary=ce_pixel && hcount==10'd655 && vcount==10'd383;
    assign stack_scan_slot=stack_head+scan_pos[STACK_BITS-1:0];
    assign active_append_pos=(active_count<ACTIVE_COUNT_LIMIT)
                           ? active_count : ACTIVE_COUNT_LIMIT-1'b1;
	s24_sprite_ydiv_radix4_step ydiv_step (
		.dividend(ydiv_dividend),.quotient(ydiv_quotient),
		.remainder(ydiv_remainder),.divisor(ydiv_divisor),
		.next_quotient(ydiv_next_quotient),
		.next_remainder(ydiv_next_remainder)
	);
    // Packed descriptor RAM supplies two logical entries per clock whenever
    // the ring cursor is physically even.  An odd head peels one upper-half
    // entry, then resumes paired scanning at the next even physical slot.
    assign scan_quad_valid=(stack_scan_slot[1:0]==2'b00) &&
                           (scan_pos+11'd3<stack_count);
    assign scan_pair_valid=!stack_scan_slot[0] &&
                           (scan_pos+1'b1<stack_count);
    assign scan_advance=scan_quad_valid ? 3'd4 :
                        (scan_pair_valid ? 3'd2 : 3'd1);
    assign scan_next_pos=scan_pos+{{(STACK_BITS-2){1'b0}},scan_advance};
    assign scan_next_slot=stack_scan_slot+
                          {{(STACK_BITS-3){1'b0}},scan_advance};

    always_comb begin
        if(state==S_SCAN_PREFETCH) begin
            descriptor_read_pair=stack_scan_slot[STACK_BITS-1:1];
            descriptor_read_pair2=stack_scan_slot[STACK_BITS-1:1]+1'b1;
        end else if(state==S_SCAN || state==S_SCAN_SECOND ||
                    state==S_SCAN_QUAD_DRAIN) begin
            descriptor_read_pair=scan_next_slot[STACK_BITS-1:1];
            descriptor_read_pair2=scan_next_slot[STACK_BITS-1:1]+1'b1;
        end else begin
            descriptor_read_pair='0;
            descriptor_read_pair2='0;
        end

        if(state==S_SCAN_PREFETCH || state==S_SCAN || state==S_SCAN_SECOND) begin
            if(stack_scan_slot[0]) begin
                descriptor_stack_q=descriptor_stack_pair_q[255:128];
                clip_stack_q=clip_stack_pair_q[161:81];
            end else begin
                descriptor_stack_q=descriptor_stack_pair_q[127:0];
                clip_stack_q=clip_stack_pair_q[80:0];
            end
        end else begin
            descriptor_stack_q=descriptor_stack_pair_q[127:0];
            clip_stack_q=clip_stack_pair_q[80:0];
        end
        scan_descriptor1=descriptor_stack_pair_q[255:128];
        scan_clip1=clip_stack_pair_q[161:81];
        scan_descriptor2=descriptor_stack_pair2_q[127:0];
        scan_clip2=clip_stack_pair2_q[80:0];
        scan_descriptor3=descriptor_stack_pair2_q[255:128];
        scan_clip3=clip_stack_pair2_q[161:81];
    end

    always_comb begin
        // The registered line RAM is one line ahead of the visible raster.
        // Each bank carries the destination Y it actually contains; the
        // modulo bank index is only a storage hint and must not be used as a
        // substitute when a long sprite list makes the producer fall behind.
        next_display_line = 10'd1;
        if(vcount==10'd422)
            next_display_line = 10'd0;
        else if(vcount==10'd423)
            next_display_line = 10'd1;
        else if(vcount<10'd383)
            next_display_line = vcount + 10'd2;
        next_display_bank = display_bank;
        next_display_ready = 1'b0;
        for(bank_scan=0;bank_scan<LINE_BANKS;bank_scan=bank_scan+1) begin
            if(line_valid[bank_scan] && !bank_filling[bank_scan] &&
               bank_line_y[bank_scan]==next_display_line[8:0]) begin
                next_display_bank = bank_scan[LINE_BANK_BITS-1:0];
                next_display_ready = 1'b1;
            end
        end
        // Choose an actually free bank for the producer. Never overwrite the
        // bank currently feeding the raster.
        //
        // The old second term ("...!=display_bank || !line_valid[display_
        // bank]") was tautological: inside a branch that already requires
        // !line_valid[bank_scan], the bank_scan==display_bank case reduces to
        // !line_valid[display_bank], which is exactly what the first term just
        // asserted.  It therefore excluded nothing, and any moment where
        // display_bank was momentarily invalid - the whole of vertical blank
        // after the frame-boundary line_valid<='0, and every scanline whose
        // swap failed - let the producer claim the bank the raster is pointing
        // at and refill it with a FUTURE line mid-scanline.  The rest-of-line
        // gate below only re-checks line_valid[display_bank], so the remainder
        // of that scanline displayed a different raster line.  Exclude
        // display_bank unconditionally instead: LINE_BANKS-1 banks of
        // lookahead is far more than the one line the producer must stay ahead
        // by, and display_bank is released for filling as soon as the raster
        // moves on.
        fill_candidate = '0;
        fill_candidate_valid = 1'b0;
        for(bank_scan=0;bank_scan<LINE_BANKS;bank_scan=bank_scan+1) begin
            if(!line_valid[bank_scan] && !bank_filling[bank_scan] &&
               bank_scan[LINE_BANK_BITS-1:0]!=display_bank &&
               !fill_candidate_valid) begin
                fill_candidate = bank_scan[LINE_BANK_BITS-1:0];
                fill_candidate_valid = 1'b1;
            end
        end
        display_lane = (hcount==10'd655) ? 2'd0 : hcount[1:0]+2'd1;
        case(display_lane)
            2'd0: begin
                line0_display_sel=line0_display_q[0];
                line1_display_sel=line1_display_q[0];
                line2_display_sel=line2_display_q[0];
                line3_display_sel=line3_display_q[0];
            end
            2'd1: begin
                line0_display_sel=line0_display_q[1];
                line1_display_sel=line1_display_q[1];
                line2_display_sel=line2_display_q[1];
                line3_display_sel=line3_display_q[1];
            end
            2'd2: begin
                line0_display_sel=line0_display_q[2];
                line1_display_sel=line1_display_q[2];
                line2_display_sel=line2_display_q[2];
                line3_display_sel=line3_display_q[2];
            end
            default: begin
                line0_display_sel=line0_display_q[3];
                line1_display_sel=line1_display_q[3];
                line2_display_sel=line2_display_q[3];
                line3_display_sel=line3_display_q[3];
            end
        endcase
        display_read_addr = (hcount==10'd655)
                            ? {next_display_bank,7'd0}
                            : {display_bank,hcount[8:2] +
                               ((hcount[1:0]==2'd3) ? 7'd1 : 7'd0)};

        if(state==S_SCAN || state==S_SCAN_SECOND)
            active_cache_read_addr=active_count[ACTIVE_BITS-1:0];
        else if(state==S_RENDER_PREFETCH)
            // The scan phase leaves render_pos on the newest active entry.
            // Read that entry during the prefetch cycle; render-time reads
            // below intentionally stay one entry ahead for S_NEXT_SPRITE.
            active_cache_read_addr=render_pos[ACTIVE_BITS-1:0];
        else if(state==S_NEXT_SPRITE)
            // S_NEXT_SPRITE consumes entry render_pos-1 and decrements
            // render_pos in the SAME cycle, so the entry it must read next is
            // render_pos-2, not render_pos-1.  With the -1 form a rejected
            // sprite (MAME simply draws nothing for an off-screen one and
            // moves on to sprd[countspr-1]) left S_NEXT_SPRITE asserted for a
            // second cycle, which re-read the entry just consumed: that
            // duplicate advanced render_pos without visiting a new descriptor,
            // permanently biasing the read pointer by one, and the next
            // accepted sprite then skipped its neighbour entirely. The dropped
            // entry is always the one BEHIND the rejected sprite in list
            // order, so a single off-screen descriptor silently deleted a
            // visible sprite from that scanline -- visible as horizontal
            // slices missing from sprites whose neighbours cross a screen or
            // clip-window edge.
            active_cache_read_addr=(render_pos>13'd1)
                ? render_pos[ACTIVE_BITS-1:0]-{{(ACTIVE_BITS-2){1'b0}},2'd2}
                : '0;
        else if(render_pos!=0)
            // Every other render state (including S_RENDER_WAIT, whose own
            // entry was already fetched by S_RENDER_PREFETCH) prefetches the
            // entry S_NEXT_SPRITE will consume.
            active_cache_read_addr=render_pos[ACTIVE_BITS-1:0]-1'b1;
        else
            active_cache_read_addr='0;
        active_render_descriptor=active_cache_q[208:81];
        active_render_clip=active_cache_q[80:0];
        mem_w0=burst_word(read_data,0);mem_w1=burst_word(read_data,1);
        mem_w2=burst_word(read_data,2);mem_w3=burst_word(read_data,3);
        mem_w4=burst_word(read_data,4);mem_w5=burst_word(read_data,5);
        list_zoomy_step=(mem_w1[7:0]==0)
                        ? 9'h040 : {1'b0,mem_w1[7:0]}+1'b1;
        list_height_sum=20'd32
                       + ({11'd0,list_zoomy_step} << (mem_w4[14:12]+3));
        list_height=list_height_sum[18:6];
        list_origin_y=$signed({mem_w4[11],mem_w4[11:0]});
        list_bottom_y=$signed(list_origin_y)+$signed({1'b0,list_height});
        d2=burst_word(descriptor,2);d3=burst_word(descriptor,3);
        d5=burst_word(descriptor,5);
        palette_base=d3[13:0];
        palette_cache_index=palette_base[2:0];
        palette_cache_hit=palette_cache_valid[palette_cache_index] &&
                          palette_cache_tags[palette_cache_index]==palette_base;
        tile_base={d2[12:0],4'b0};
        // The height is a power of two. Retain its exponent instead of
        // carrying an equivalent one-hot byte through the render path.
        total_rows=11'd8 << size_y_shift;
        total_columns={size_x_tiles,3'b0};

        tile_y=source_row[10:3];
        within_y=source_row[2:0];
        tile_x=source_column[10:3];
        within_x=source_column[2:0];
        if(flipy) begin
            // For a power-of-two height, N-1-y is exactly y xor (N-1).
            // size_y_mask is registered when the descriptor is accepted.
            tile_y=tile_y^size_y_mask;
            within_y=3'd7-within_y;
        end
        if(flipx) begin
            tile_x=size_x_tiles-1'b1-tile_x;
            within_x=3'd7-within_x;
        end
        // MAME masks every sprite-data word address to the 0x20000-word RAM.
        // The descriptor width is always a power of two, so select the exact
        // shift wiring instead of inferring a general 14x14 multiplier. The
        // result remains 14 bits, which is sufficient for 128*128 tiles.
        tile_row_offset=14'd0;
        case(size_x_shift)
            3'd0: tile_row_offset={6'd0,tile_y};
            3'd1: tile_row_offset={5'd0,tile_y,1'b0};
            3'd2: tile_row_offset={4'd0,tile_y,2'b0};
            3'd3: tile_row_offset={3'd0,tile_y,3'b0};
            3'd4: tile_row_offset={2'd0,tile_y,4'b0};
            3'd5: tile_row_offset={1'b0,tile_y,5'b0};
            3'd6: tile_row_offset={tile_y,6'b0};
            default: tile_row_offset={tile_y[6:0],7'b0};
        endcase
        tile_ordinal=tile_row_offset+{6'd0,tile_x};
        word_calc={1'b0,tile_base} + {tile_ordinal,4'b0}
                  + {14'd0,within_y,1'b0} + {17'd0,within_x[2]};
        wanted_word=word_calc[16:0];
        wanted_nibble={~within_x[1:0],2'b00};
        wanted_tag=wanted_word[16:3];
		// Present the prospective request one clock before a cached burst is
		// consumed. The M10K read therefore overlaps the existing REQ state;
		// an SDRAM miss retains the old request timing.
		burst_request_tag=burst_lookup_tag;
		case(state)
			S_LIST_REQ: burst_request_tag={1'b0,list_index};
			S_YMAP: burst_request_tag=palette_base;
			S_X_SOURCE,S_X_EMIT: burst_request_tag=wanted_tag;
			S_X_EMIT4: burst_request_tag=wanted_tag;
			default: ;
		endcase
        wanted_data_word=burst_word(data_cache,wanted_word[2:0]);
        current_pen=wanted_data_word[wanted_nibble +: 4];
        mapped_color=palette_entry(palette_table,current_pen);
        // The 315-5293/5295 does not reserve source pen zero for
        // transparency. MAME first indexes the 16-byte indirect table and
        // only color zero from that table is transparent. Palette entry zero
        // may therefore produce an ordinary visible pixel or the shadow pen.
        if(mapped_color==0) line_value=17'd0;
        else if(mapped_color==1) line_value={1'b1,2'b00,14'h2000};
        else line_value={1'b1,mapped_color[7:6],1'b0,1'b1,
                         4'b0000,mapped_color};

        // The common 1x1, 1:1 case emits four adjacent source pixels in one
        // clock. Each pixel owns an interleaved X lane in every priority
        // group, so the four writes remain independent even when two pixels
        // use the same group. Generic zoom and multi-tile sprites continue
        // to use the single-pixel path below.
        for(lane_calc=0;lane_calc<4;lane_calc=lane_calc+1) begin
            lane_dest_x[lane_calc]=$signed({dest_x[12],dest_x})+
                $signed({12'd0,lane_calc[1:0]});
            lane_col[lane_calc]=source_column+lane_calc[10:0];
            lane_within_x[lane_calc]=flipx
                ? 3'd7-lane_col[lane_calc][2:0]
                : lane_col[lane_calc][2:0];
            lane_word[lane_calc]=tile_base
                + ({3'd0,tile_ordinal} << 4)
                + {13'd0,within_y,1'b0}
                + {16'd0,lane_within_x[lane_calc][2]};
            lane_tag[lane_calc]=lane_word[lane_calc][16:3];
            lane_data_word[lane_calc]=
                burst_word(data_cache,lane_word[lane_calc][2:0]);
            lane_pen[lane_calc]=lane_data_word[lane_calc]
                [{~lane_within_x[lane_calc][1:0],2'b00} +: 4];
            lane_color[lane_calc]=palette_entry(palette_table,
                                                lane_pen[lane_calc]);
            if(lane_color[lane_calc]==0)
                lane_line_value[lane_calc]=17'd0;
            else if(lane_color[lane_calc]==1)
                lane_line_value[lane_calc]={1'b1,2'b00,14'h2000};
            else
                lane_line_value[lane_calc]={1'b1,lane_color[lane_calc][7:6],
                    1'b0,1'b1,4'b0000,lane_color[lane_calc]};
        end

        x_sum={3'd0,x_accum}+zoomx_step;
        y_sum={3'd0,y_accum}+zoomy_step;
        render_w0=burst_word(active_render_descriptor,0);
        render_w1=burst_word(active_render_descriptor,1);
        render_w4=burst_word(active_render_descriptor,4);
        render_w5=burst_word(active_render_descriptor,5);
        render_zoomx_step=(!render_w0[13] ? render_w1[7:0]
                                               : render_w1[15:8])==0
                          ? 9'h040
                          : {1'b0,(!render_w0[13] ? render_w1[7:0]
                                                   : render_w1[15:8])}+1'b1;
        descriptor_width_sum=20'd32
                             + ({11'd0,render_zoomx_step}
                                << (render_w5[14:12]+3));
        active_setup_origin_x=$signed({render_w5[11],render_w5[11:0]})
                              -13'sd8;
        active_setup_width=descriptor_width_sum[18:6];
        active_setup_right_x=$signed({active_setup_origin_x[12],
                                      active_setup_origin_x})
                            + $signed({1'b0,active_setup_width})-14'sd1;
        active_setup_zoomy_step=(render_w1[7:0]==0)
                                ? 9'h040
                                : {1'b0,render_w1[7:0]}+1'b1;
        active_setup_total_rows=11'd8 << render_w4[14:12];
        active_setup_origin_y=$signed({render_w4[11],render_w4[11:0]});
        active_setup_bottom_y=$signed(active_setup_origin_y)
                              +$signed({3'd0,active_setup_total_rows});
        active_setup_target_offset=offset12($signed({4'd0,target_y})
                                           -active_setup_origin_y);
        active_setup_clip_min_x=13'sd0;
        active_setup_clip_max_x=13'sd495;
        active_setup_clip_first=13'sd383;
        active_setup_clip_last=13'sd0;
        active_setup_vertical_allowed=(target_y<9'd384);
        if(active_render_clip[80]) begin
            active_setup_clip_min_x=$signed({4'd0,active_render_clip[40:32]})
                                    -13'sd8;
            active_setup_clip_max_x=$signed({4'd0,active_render_clip[8:0]})
                                    -13'sd8;
            if(active_render_clip[77]) begin
                active_setup_clip_first=$signed({4'd0,active_render_clip[56:48]})
                                        -13'sd1;
                active_setup_clip_last=$signed({4'd0,active_render_clip[24:16]})
                                       +13'sd1;
                active_setup_vertical_allowed=active_setup_vertical_allowed &&
                    (($signed({4'd0,target_y})<=active_setup_clip_first) ||
                     ($signed({4'd0,target_y})>=active_setup_clip_last));
            end else begin
                active_setup_vertical_allowed=active_setup_vertical_allowed &&
                    target_y>=active_render_clip[56:48] &&
                    target_y<=active_render_clip[24:16];
            end
        end
        descriptor_right_x=$signed({descriptor_origin_x[12],
                                     descriptor_origin_x})
                           + $signed({1'b0,descriptor_output_width})-14'sd1;
        descriptor_zoomy_step=(render_w1[7:0]==0)
                              ? 9'h040
                              : {1'b0,render_w1[7:0]}+1'b1;
        descriptor_total_rows=11'd8 << render_w4[14:12];
        descriptor_origin_y=$signed({render_w4[11],render_w4[11:0]});
        descriptor_bottom_y=$signed(descriptor_origin_y)
                            + $signed({3'd0,descriptor_total_rows});
        descriptor_target_offset=offset12($signed({4'd0,target_y})
                                          - descriptor_origin_y);

        // N = 64*d+31 = q*s+r. Therefore the selected source row starts at
        // d + floor((63-r)/64), with accumulator (63-r) modulo 64.
        ydiv_adjust_value=10'sd63
                          - $signed({1'b0,ydiv_next_remainder[8:0]});

        scan_w1=burst_word(descriptor_stack_q,1);
        scan_w4=burst_word(descriptor_stack_q,4);
        scan_zoomy_step=(scan_w1[7:0]==0)
                        ? 9'h040 : {1'b0,scan_w1[7:0]}+1'b1;
        scan_height_sum=20'd32
                        + ({11'd0,scan_zoomy_step} << (scan_w4[14:12]+3));
        scan_height=scan_height_sum[18:6];
        scan_origin_y=$signed({scan_w4[11],scan_w4[11:0]});
        scan_bottom_y=$signed(scan_origin_y)+$signed({1'b0,scan_height});
        scan_vertical_allowed=(target_y<9'd384);
        if(clip_stack_q[80]) begin
            if(clip_stack_q[77])
                scan_vertical_allowed=scan_vertical_allowed &&
                    (($signed({4'd0,target_y})<=
                      $signed({4'd0,clip_stack_q[56:48]})-13'sd1) ||
                     ($signed({4'd0,target_y})>=
                      $signed({4'd0,clip_stack_q[24:16]})+13'sd1));
            else
                scan_vertical_allowed=scan_vertical_allowed &&
                    target_y>=clip_stack_q[56:48] &&
                    target_y<=clip_stack_q[24:16];
        end
        scan_active=scan_vertical_allowed &&
                    $signed({4'd0,target_y})>=scan_origin_y &&
                    $signed({4'd0,target_y})<scan_bottom_y;

        scan1_w1=burst_word(scan_descriptor1,1);
        scan1_w4=burst_word(scan_descriptor1,4);
        scan1_zoomy_step=(scan1_w1[7:0]==0)
                         ? 9'h040 : {1'b0,scan1_w1[7:0]}+1'b1;
        scan1_height_sum=20'd32
                         + ({11'd0,scan1_zoomy_step} << (scan1_w4[14:12]+3));
        scan1_height=scan1_height_sum[18:6];
        scan1_origin_y=$signed({scan1_w4[11],scan1_w4[11:0]});
        scan1_bottom_y=$signed(scan1_origin_y)+$signed({1'b0,scan1_height});
        scan1_vertical_allowed=(target_y<9'd384);
        if(scan_clip1[80]) begin
            if(scan_clip1[77])
                scan1_vertical_allowed=scan1_vertical_allowed &&
                    (($signed({4'd0,target_y})<=
                      $signed({4'd0,scan_clip1[56:48]})-13'sd1) ||
                     ($signed({4'd0,target_y})>=
                      $signed({4'd0,scan_clip1[24:16]})+13'sd1));
            else
                scan1_vertical_allowed=scan1_vertical_allowed &&
                    target_y>=scan_clip1[56:48] &&
                    target_y<=scan_clip1[24:16];
        end
        scan1_active=scan1_vertical_allowed &&
                     scan_pair_valid &&
                     (scan_pos+1'b1<stack_count) &&
                     $signed({4'd0,target_y})>=scan1_origin_y &&
                     $signed({4'd0,target_y})<scan1_bottom_y;

        scan2_w1=burst_word(scan_descriptor2,1);
        scan2_w4=burst_word(scan_descriptor2,4);
        scan2_zoomy_step=(scan2_w1[7:0]==0)
                         ? 9'h040 : {1'b0,scan2_w1[7:0]}+1'b1;
        scan2_height_sum=20'd32
                        + ({11'd0,scan2_zoomy_step} << (scan2_w4[14:12]+3));
        scan2_height=scan2_height_sum[18:6];
        scan2_origin_y=$signed({scan2_w4[11],scan2_w4[11:0]});
        scan2_bottom_y=$signed(scan2_origin_y)+$signed({1'b0,scan2_height});
        scan2_vertical_allowed=(target_y<9'd384);
        if(scan_clip2[80]) begin
            if(scan_clip2[77])
                scan2_vertical_allowed=scan2_vertical_allowed &&
                    (($signed({4'd0,target_y})<=
                      $signed({4'd0,scan_clip2[56:48]})-13'sd1) ||
                     ($signed({4'd0,target_y})>=
                      $signed({4'd0,scan_clip2[24:16]})+13'sd1));
            else
                scan2_vertical_allowed=scan2_vertical_allowed &&
                    target_y>=scan_clip2[56:48] &&
                    target_y<=scan_clip2[24:16];
        end
        scan2_active=scan2_vertical_allowed && scan_quad_valid &&
                     (scan_pos+11'd2<stack_count) &&
                     $signed({4'd0,target_y})>=scan2_origin_y &&
                     $signed({4'd0,target_y})<scan2_bottom_y;

        scan3_w1=burst_word(scan_descriptor3,1);
        scan3_w4=burst_word(scan_descriptor3,4);
        scan3_zoomy_step=(scan3_w1[7:0]==0)
                         ? 9'h040 : {1'b0,scan3_w1[7:0]}+1'b1;
        scan3_height_sum=20'd32
                        + ({11'd0,scan3_zoomy_step} << (scan3_w4[14:12]+3));
        scan3_height=scan3_height_sum[18:6];
        scan3_origin_y=$signed({scan3_w4[11],scan3_w4[11:0]});
        scan3_bottom_y=$signed(scan3_origin_y)+$signed({1'b0,scan3_height});
        scan3_vertical_allowed=(target_y<9'd384);
        if(scan_clip3[80]) begin
            if(scan_clip3[77])
                scan3_vertical_allowed=scan3_vertical_allowed &&
                    (($signed({4'd0,target_y})<=
                      $signed({4'd0,scan_clip3[56:48]})-13'sd1) ||
                     ($signed({4'd0,target_y})>=
                      $signed({4'd0,scan_clip3[24:16]})+13'sd1));
            else
                scan3_vertical_allowed=scan3_vertical_allowed &&
                    target_y>=scan_clip3[56:48] &&
                    target_y<=scan_clip3[24:16];
        end
        scan3_active=scan3_vertical_allowed && scan_quad_valid &&
                     (scan_pos+11'd3<stack_count) &&
                     $signed({4'd0,target_y})>=scan3_origin_y &&
                     $signed({4'd0,target_y})<scan3_bottom_y;

        scan_quad_descriptor[0]=descriptor_stack_q;
        scan_quad_descriptor[1]=scan_descriptor1;
        scan_quad_descriptor[2]=scan_descriptor2;
        scan_quad_descriptor[3]=scan_descriptor3;
        scan_quad_clip[0]=clip_stack_q;
        scan_quad_clip[1]=scan_clip1;
        scan_quad_clip[2]=scan_clip2;
        scan_quad_clip[3]=scan_clip3;
        scan_quad_active[0]=scan_active;
        scan_quad_active[1]=scan1_active;
        scan_quad_active[2]=scan2_active;
        scan_quad_active[3]=scan3_active;
        scan_quad_first_descriptor='0;
        scan_quad_first_clip='0;
        scan_quad_batch_pending_descriptor[0]='0;
        scan_quad_batch_pending_descriptor[1]='0;
        scan_quad_batch_pending_descriptor[2]='0;
        scan_quad_batch_pending_clip[0]='0;
        scan_quad_batch_pending_clip[1]='0;
        scan_quad_batch_pending_clip[2]='0;
        scan_quad_seen=0;
        for(scan_quad_i=0;scan_quad_i<4;scan_quad_i=scan_quad_i+1) begin
            if(scan_quad_active[scan_quad_i]) begin
                if(scan_quad_seen==0) begin
                    scan_quad_first_descriptor=scan_quad_descriptor[scan_quad_i];
                    scan_quad_first_clip=scan_quad_clip[scan_quad_i];
                end else if(scan_quad_seen<4) begin
                    scan_quad_batch_pending_descriptor[scan_quad_seen-1]=
                        scan_quad_descriptor[scan_quad_i];
                    scan_quad_batch_pending_clip[scan_quad_seen-1]=
                        scan_quad_clip[scan_quad_i];
                end
                scan_quad_seen=scan_quad_seen+1;
            end
        end
        scan_quad_active_count=scan_quad_seen[2:0];

        // With no clip descriptor MAME clips the already origin-adjusted
        // destination coordinate to the complete 496-pixel visible area.
        // The -8 offset belongs to the sprite X origin, not to this default
        // screen rectangle; explicit clip descriptors apply it below.
        clip_min_x=13'sd0;
        clip_max_x=13'sd495;
        clip_first=13'sd383;
        clip_last=13'sd0;
        vertical_allowed=(target_y<9'd384);
        if(render_clip[80]) begin
            clip_min_x=$signed({4'd0,render_clip[40:32]})-13'sd8;
            clip_max_x=$signed({4'd0,render_clip[8:0]})-13'sd8;
            if(render_clip[77]) begin
                clip_first=$signed({4'd0,render_clip[56:48]})-13'sd1;
                clip_last=$signed({4'd0,render_clip[24:16]})+13'sd1;
                vertical_allowed=vertical_allowed &&
                    (($signed({4'd0,target_y})<=clip_first) ||
                     ($signed({4'd0,target_y})>=clip_last));
            end else begin
                vertical_allowed=vertical_allowed &&
                    (target_y>=render_clip[56:48]) &&
                    (target_y<=render_clip[24:16]);
            end
        end
    end

    // Port B performs the renderer write or the inactive-bank clear. Port A
    // always consumes/clears the currently displayed bank on a pixel edge.
    logic line_b_clear;
    // Generation tags reject stale pixels only until bank_generation wraps.
    // With the 8-bit tag that is 256 fills of the same bank. A
    // word never rewritten in that whole window then matches its old tag
    // again, and as the counter keeps advancing the match sweeps through the
    // stored history: the line buffers replay ~23-second-old sprite pixels in
    // every scene, animated purely by the free-running fill counters -- even
    // with the CPU paused. Scrubbing one rotating word of the fill bank per
    // fill bounds any word's unwritten lifetime to 128 fills (~3 frames),
    // half the wrap horizon, so no stale tag can survive to a wrap.
    logic scrub_req;
    logic [9:0] scrub_addr;
    logic [6:0] bank_scrub [0:LINE_BANKS-1];
    always_comb begin
        // Generation tags invalidate the previous bank contents; no bulk
        // clear write is needed (and would steal the scanline render slot).
        line_b_clear=1'b0;
        line_b_wren='0;
        // Port B's occlusion read is one clock ahead of the write it gates
        // (this state -> S_X_EMIT/S_X_EMIT4 next cycle), exactly like port
        // A's display_read_addr lookahead just above. Physical lane
        // line_phys receives destination pixel dest_x+((line_phys-dest_x[1:0])
        // mod 4) this group; whenever that lane's pixel falls past the
        // 4-pixel group boundary (line_phys<dest_x[1:0]), its true word is
        // dest_x[8:2]+1, not the group's base word. Without this carry the
        // occlusion test for those lanes reads the word 4 columns to the
        // left -- a stale decision that either wrongly drops an opaque
        // pixel (word falsely reads occupied) or wrongly lets a pixel
        // through onto an already-claimed higher-priority word (word
        // falsely reads free). dest_x[1:0] is fixed for a sprite's whole
        // render (== its descriptor X origin mod 4), so at dest_x[1:0]==0
        // this was always correct by coincidence, which is why sprites
        // placed/moving only in Y (X constant) could look clean while
        // horizontal motion swept dest_x[1:0] through all four phases and
        // made the drop/cross-talk pattern change every frame.
        for(line_phys=0;line_phys<4;line_phys=line_phys+1) begin
            line_b_addr[line_phys]={fill_bank,dest_x[8:2] +
                                    ((line_phys<dest_x[1:0]) ? 7'd1 : 7'd0)};
            line_b_data[line_phys]='0;
            line_b_category[line_phys]=2'd0;
        end
        for(lane_write=0;lane_write<4;lane_write=lane_write+1) begin
            if(state==S_X_EMIT4 && data_cache_valid &&
               data_cache_tag==lane_tag[lane_write] &&
               lane_dest_x[lane_write]>=$signed({clip_min_x[12],clip_min_x}) &&
               lane_dest_x[lane_write]<=$signed({clip_max_x[12],clip_max_x}) &&
               lane_dest_x[lane_write]>=0 &&
               lane_dest_x[lane_write]<496 &&
               lane_line_value[lane_write][16]) begin
                line_phys={30'd0,lane_dest_x[lane_write][1:0]};
                line_b_addr[line_phys]={fill_bank,lane_dest_x[lane_write][8:2]};
                line_b_category[line_phys]=lane_line_value[lane_write][15:14];
                line_b_data[line_phys]={fill_generation,1'b1,render_pos[10:0],
                                        lane_line_value[lane_write][13:0]};
                case(lane_line_value[lane_write][15:14])
                    2'd0: line_b_wren[line_phys]=
                        !line0_render_q[line_phys][25] ||
                        line0_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                    2'd1: line_b_wren[line_phys]=
                        !line1_render_q[line_phys][25] ||
                        line1_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                    2'd2: line_b_wren[line_phys]=
                        !line2_render_q[line_phys][25] ||
                        line2_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                    default: line_b_wren[line_phys]=
                        !line3_render_q[line_phys][25] ||
                        line3_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                endcase
            end else if(state==S_X_EMIT &&
                        lane_write=={30'd0,dest_x[1:0]} &&
                        data_cache_valid && data_cache_tag==wanted_tag &&
                        dest_x>=clip_min_x && dest_x<=clip_max_x && dest_x>=0 &&
                        dest_x<496 && line_value[16]) begin
                line_phys={30'd0,dest_x[1:0]};
                line_b_category[line_phys]=line_value[15:14];
                line_b_data[line_phys]={fill_generation,1'b1,render_pos[10:0],
                                        line_value[13:0]};
                case(line_value[15:14])
                    2'd0: line_b_wren[line_phys]=
                        !line0_render_q[line_phys][25] ||
                        line0_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                    2'd1: line_b_wren[line_phys]=
                        !line1_render_q[line_phys][25] ||
                        line1_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                    2'd2: line_b_wren[line_phys]=
                        !line2_render_q[line_phys][25] ||
                        line2_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                    default: line_b_wren[line_phys]=
                        !line3_render_q[line_phys][25] ||
                        line3_render_q[line_phys][LINE_WIDTH-1 -: LINE_GEN_WIDTH]
                            !=fill_generation;
                endcase
            end
        end
        // The scrub cycle is the one immediately after a fill is claimed in
        // S_IDLE. That cycle is never an emit state and never the
        // occlusion-lookahead cycle before one, so overriding port B here
        // cannot disturb a render write or the read-ahead that gates it.
        // line_b_clear routes the zero write through all four category RAMs.
        if(scrub_req) begin
            line_b_clear=1'b1;
            line_b_wren=4'b1111;
            for(line_phys=0;line_phys<4;line_phys=line_phys+1) begin
                line_b_addr[line_phys]=scrub_addr;
                line_b_data[line_phys]='0;
            end
        end
    end

    genvar line_lane;
    generate for(line_lane=0;line_lane<4;line_lane=line_lane+1) begin : gen_line_lane
        s24_sprite_line_ram #(.WIDTH(LINE_WIDTH),.ADDR_WIDTH(10)) line0_ram (
            .clk(clk),.address_a(display_read_addr),.data_a({LINE_WIDTH{1'b0}}),
            .wren_a(1'b0),.q_a(line0_display_q[line_lane]),
            .address_b(line_b_addr[line_lane]),.data_b(line_b_data[line_lane]),
            .wren_b(line_b_wren[line_lane] &&
                    (line_b_clear || line_b_category[line_lane]==2'd0)),
            .q_b(line0_render_q[line_lane]));
        s24_sprite_line_ram #(.WIDTH(LINE_WIDTH),.ADDR_WIDTH(10)) line1_ram (
            .clk(clk),.address_a(display_read_addr),.data_a({LINE_WIDTH{1'b0}}),
            .wren_a(1'b0),.q_a(line1_display_q[line_lane]),
            .address_b(line_b_addr[line_lane]),.data_b(line_b_data[line_lane]),
            .wren_b(line_b_wren[line_lane] &&
                    (line_b_clear || line_b_category[line_lane]==2'd1)),
            .q_b(line1_render_q[line_lane]));
        s24_sprite_line_ram #(.WIDTH(LINE_WIDTH),.ADDR_WIDTH(10)) line2_ram (
            .clk(clk),.address_a(display_read_addr),.data_a({LINE_WIDTH{1'b0}}),
            .wren_a(1'b0),.q_a(line2_display_q[line_lane]),
            .address_b(line_b_addr[line_lane]),.data_b(line_b_data[line_lane]),
            .wren_b(line_b_wren[line_lane] &&
                    (line_b_clear || line_b_category[line_lane]==2'd2)),
            .q_b(line2_render_q[line_lane]));
        s24_sprite_line_ram #(.WIDTH(LINE_WIDTH),.ADDR_WIDTH(10)) line3_ram (
            .clk(clk),.address_a(display_read_addr),.data_a({LINE_WIDTH{1'b0}}),
            .wren_a(1'b0),.q_a(line3_display_q[line_lane]),
            .address_b(line_b_addr[line_lane]),.data_b(line_b_data[line_lane]),
            .wren_b(line_b_wren[line_lane] &&
                    (line_b_clear || line_b_category[line_lane]==2'd3)),
            .q_b(line3_render_q[line_lane]));
    end endgenerate

    always_comb begin
        descriptor_write_enable=state==S_LIST_WAIT && read_ack &&
            mem_w0[15:14]==2'b00 && !(list_index==0 && mem_w0==0);
        descriptor_write_high=stack_write_slot[0];
        descriptor_write_addr=stack_write_slot[STACK_BITS-1:1];
        descriptor_write_data=read_data;
        clip_write_data={current_clip_valid,current_clip_flags,current_clip_top,
                         current_clip_left,current_clip_bottom,current_clip_right};

        active_cache_write_enable=1'b0;
        active_cache_write_addr=active_count[ACTIVE_BITS-1:0];
        active_cache_write_data='0;
        if(state==S_SCAN) begin
            if(scan_quad_valid && scan_quad_active_count!=0) begin
                active_cache_write_enable=1'b1;
                active_cache_write_data={scan_quad_first_descriptor,
                                         scan_quad_first_clip};
            end else if(scan_active) begin
                active_cache_write_enable=1'b1;
                active_cache_write_data={descriptor_stack_q,clip_stack_q};
            end else if(scan1_active) begin
                active_cache_write_enable=1'b1;
                active_cache_write_data={scan_descriptor1,scan_clip1};
            end
        end else if(state==S_SCAN_SECOND) begin
            active_cache_write_enable=1'b1;
            active_cache_write_data={scan_second_descriptor,scan_second_clip};
        end else if(state==S_SCAN_QUAD_DRAIN) begin
            active_cache_write_enable=scan_quad_pending_count!=0;
            active_cache_write_data={scan_quad_pending_descriptor[0],
                                     scan_quad_pending_clip[0]};
        end
        // Continue scanning after the fixed-size active cache fills, but do
        // not alias its next logical entry back onto address zero.
        if(active_count>=ACTIVE_COUNT_LIMIT)
            active_cache_write_enable=1'b0;
    end

    always_ff @(posedge clk) begin
        if(reset) begin
            state<=S_IDLE;display_bank<=0;fill_bank<=0;line_valid<=0;
            bank_filling<=0;
            fill_epoch<=0;
            fill_generation<=0;
            bank_generation[0]<=0;bank_generation[1]<=0;
            bank_generation[2]<=0;bank_generation[3]<=0;
            bank_generation[4]<=0;bank_generation[5]<=0;
            bank_generation[6]<=0;bank_generation[7]<=0;
            bank_line_y[0]<=9'h1ff;bank_line_y[1]<=9'h1ff;
            bank_line_y[2]<=9'h1ff;bank_line_y[3]<=9'h1ff;
            bank_line_y[4]<=9'h1ff;bank_line_y[5]<=9'h1ff;
            bank_line_y[6]<=9'h1ff;bank_line_y[7]<=9'h1ff;
            scrub_req<=0;scrub_addr<=0;
            bank_scrub[0]<=0;bank_scrub[1]<=0;
            bank_scrub[2]<=0;bank_scrub[3]<=0;
            bank_scrub[4]<=0;bank_scrub[5]<=0;
            bank_scrub[6]<=0;bank_scrub[7]<=0;
            target_y<=0;render_next_target<=0;
            list_index<=0;list_seen<=0;list_cache_valid<=0;
            cache_refresh_pending<=0;
            frame_epoch<=0;
            line_boundary<=0;active_list_valid<=0;
            current_clip_valid<=0;
            current_clip_flags<=0;current_clip_top<=0;current_clip_left<=0;
            current_clip_bottom<=0;current_clip_right<=0;stack_count<=0;
            stack_head<=0;
            render_pos<=0;render_clip<=0;descriptor<=0;
            palette_table<=0;data_cache<=0;data_cache_tag<=0;
            data_cache_valid<=0;palette_cache_valid<=0;
			burst_lookup_tag<=0;cache_ack_pending<=0;
            descriptor_origin_x<=0;descriptor_output_width<=0;
            mem_req<=0;mem_addr<=0;
            pixel0<=0;pixel1<=0;pixel2<=0;pixel3<=0;
            rank0<=0;rank1<=0;rank2<=0;rank3<=0;
            zoomx_step<=0;zoomy_step<=0;x_accum<=0;
            y_accum<=0;emit_count<=0;source_row<=0;source_column<=0;
            ydiv_dividend<=0;ydiv_quotient<=0;ydiv_remainder<=0;
            ydiv_divisor<=0;ydiv_total_rows<=0;ydiv_count<=0;
            scan_pos<=0;active_count<=0;
            scan_second_last<=0;
            scan_second_descriptor<=0;scan_second_clip<=0;
            scan_quad_pending_count<=0;scan_quad_last<=0;
            scan_quad_pending_descriptor[0]<=0;
            scan_quad_pending_descriptor[1]<=0;
            scan_quad_pending_descriptor[2]<=0;
            scan_quad_pending_clip[0]<=0;
            scan_quad_pending_clip[1]<=0;
            scan_quad_pending_clip[2]<=0;
            dest_y<=0;dest_x<=0;flipx<=0;flipy<=0;size_x_tiles<=1;
            size_x_shift<=0;size_y_shift<=0;size_y_mask<=0;
        end else begin
            // Toggle the frame epoch at the last visible-line boundary even
            // if the renderer is still busy there. Defer list-cache refresh
            // until the current queued frame has drained; a long sprite
            // line may legally span this boundary.
            if(frame_boundary) begin
                frame_epoch<=~frame_epoch;
                cache_refresh_pending<=1;
                // A bank's line_valid means "pre-rendered content for a
                // specific line of THIS frame, not yet consumed by display."
                // The fill side can legitimately race ahead of the display
                // cursor by more than one bank during a light frame (that is
                // the entire point of having LINE_BANKS>1), but nothing ever
                // reclaimed a bank display never got around to consuming
                // before the frame it was rendered for ended. Once orphaned,
                // such a bank is permanently invisible to the free-bank
                // search (line_valid[display_bank]<=0 below only frees
                // whichever bank IS display_bank), so the free pool
                // monotonically shrinks to 1 and stays there: every future
                // fill is forced onto that sole bank, so display can never
                // again pick up a lookahead line, and if that single bank's
                // fill and the display's read of it ever contend, the
                // pipeline shows nothing. Reclaim every bank here: its
                // content necessarily belongs to the frame that just ended
                // (list_cache_valid is dropped a few lines below too, so the
                // upcoming frame's lines are rendered fresh regardless).
                line_valid<='0;
            end
            if(ce_pixel) begin
                // Display consumption is read-only on port A. A consumed
                // visible bank is released only when the raster advances to
                // another visible line (or line 0 at the next frame). During
                // vertical blank the display bank is held, preserving the
                // queued line-0 result.
                if(hcount==10'd655) begin
                    if(vcount==10'd423 || vcount<10'd383) begin
                        // Reclaim by CONTENT, not by pointer.
                        //
                        // The old "line_valid[display_bank]<=0" freed exactly
                        // one bank - whichever one display_bank happened to
                        // name - regardless of what that bank held, and it did
                        // so even when the swap below failed and
                        // next_display_bank fell back to display_bank.  Two
                        // failures followed from that:
                        //
                        //  * Banks the display never consumed were never
                        //    reclaimed.  next_display_line only evaluates to 0
                        //    at vcount==422, which this very gate excludes, so
                        //    line 0 is produced every frame and never
                        //    requested; its bank kept line_valid=1 for the
                        //    whole frame and the free pool ran at 7 instead of
                        //    8 - the exact period of the observed banding.
                        //  * The bank named by a stale display_bank could hold
                        //    a line the producer had rendered AHEAD of the
                        //    raster (all of vertical blank refills banks while
                        //    display_bank still points at the previous frame's
                        //    last bank).  Freeing it discarded a line that had
                        //    already been scheduled and would never be
                        //    re-rendered, so that raster line came out blank -
                        //    and the loss re-seeded itself one pool rotation
                        //    later, producing an unbounded periodic band.
                        //
                        // Lines are produced and consumed in strictly
                        // increasing order, and at every tick of this gate
                        // next_display_line advances monotonically
                        // (1 at vcount==423, then vcount+2 for vcount<383), so
                        // "bank_line_y behind next_display_line" is exactly
                        // "already displayed, skipped, or orphaned".  Compare
                        // at full 10-bit width: next_display_line reaches 384,
                        // which truncates to 0 in bank_line_y's 9 bits.
                        //
                        // This keeps the two behaviours the old line provided:
                        // the outgoing display bank (y == next_display_line-1)
                        // is still freed on a successful swap, and on a FAILED
                        // swap display_bank is still invalidated, so the
                        // rest-of-line gate below still blanks rather than
                        // repeating the previous line.  The incoming bank
                        // (y == next_display_line) is never freed, so it stays
                        // valid for the whole scanline it feeds.
                        for(reclaim_scan=0;reclaim_scan<LINE_BANKS;
                            reclaim_scan=reclaim_scan+1)
                            if(!bank_filling[reclaim_scan] &&
                               {1'b0,bank_line_y[reclaim_scan]}<next_display_line)
                                line_valid[reclaim_scan]<=0;
                        display_bank<=next_display_bank;
                    end
                    if((vcount==10'd423 || vcount<10'd383) &&
                       next_display_ready &&
                       line_valid[next_display_bank] &&
                       bank_line_y[next_display_bank]==next_display_line[8:0]) begin
                        if(line0_display_sel[25] &&
                           line0_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[next_display_bank]) begin
                            rank0<=line0_display_sel[24:14];
                            pixel0<=line0_display_sel[13:0];
                        end else begin rank0<=0;pixel0<=0;end
                        if(line1_display_sel[25] &&
                           line1_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[next_display_bank]) begin
                            rank1<=line1_display_sel[24:14];
                            pixel1<=line1_display_sel[13:0];
                        end else begin rank1<=0;pixel1<=0;end
                        if(line2_display_sel[25] &&
                           line2_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[next_display_bank]) begin
                            rank2<=line2_display_sel[24:14];
                            pixel2<=line2_display_sel[13:0];
                        end else begin rank2<=0;pixel2<=0;end
                        if(line3_display_sel[25] &&
                           line3_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[next_display_bank]) begin
                            rank3<=line3_display_sel[24:14];
                            pixel3<=line3_display_sel[13:0];
                        end else begin rank3<=0;pixel3<=0;end
                    end else begin
                        pixel0<=0;pixel1<=0;pixel2<=0;pixel3<=0;
                        rank0<=0;rank1<=0;rank2<=0;rank3<=0;
                    end
                // display_bank was already validated once, at the swap above,
                // against next_display_line evaluated for the PREVIOUS
                // vcount. next_display_line is recomputed every cycle from
                // the CURRENT vcount, so for the rest of this line it reads
                // one line further ahead than the value bank_line_y[display_
                // bank] was actually swapped in for (always off by exactly
                // 1: bank_line_y[display_bank] settles at vcount+1 the cycle
                // after a vcount<383 swap, while next_display_line recomputes
                // to vcount+2 for that same vcount). Re-gating on that
                // mismatched comparison here meant it could never match, so
                // pixel0-3 never updated past the swap instant and every
                // sprite pixel silently stayed zero. Trust the swap's
                // one-time validation; only line_valid (freshness) and the
                // per-lane generation check below need to hold for the rest
                // of the line.
                end else if(hcount<10'd495 && line_valid[display_bank]) begin
                    if(line0_display_sel[25] &&
                       line0_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[display_bank]) begin
                        rank0<=line0_display_sel[24:14];
                        pixel0<=line0_display_sel[13:0];
                    end else begin rank0<=0;pixel0<=0;end
                    if(line1_display_sel[25] &&
                       line1_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[display_bank]) begin
                        rank1<=line1_display_sel[24:14];
                        pixel1<=line1_display_sel[13:0];
                    end else begin rank1<=0;pixel1<=0;end
                    if(line2_display_sel[25] &&
                       line2_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[display_bank]) begin
                        rank2<=line2_display_sel[24:14];
                        pixel2<=line2_display_sel[13:0];
                    end else begin rank2<=0;pixel2<=0;end
                    if(line3_display_sel[25] &&
                       line3_display_sel[LINE_WIDTH-1 -: LINE_GEN_WIDTH]==bank_generation[display_bank]) begin
                        rank3<=line3_display_sel[24:14];
                        pixel3<=line3_display_sel[13:0];
                    end else begin rank3<=0;pixel3<=0;end
                end else begin
                    pixel0<=0;pixel1<=0;pixel2<=0;pixel3<=0;
                    rank0<=0;rank1<=0;rank2<=0;rank3<=0;
                end
            end

            scrub_req<=0;
            case(state)
                S_IDLE: begin
                    // Keep the current descriptor cache alive until every
                    // queued target has been scheduled. Refreshing it as
                    // soon as the frame epoch changes can interrupt a long
                    // line render and repeatedly reset render_next_target.
                    if(!list_cache_valid ||
                       (ce_pixel && hcount==10'd655 && vcount==10'd383)) begin
                        list_index<=0;list_seen<=0;stack_count<=0;
                        stack_head<=0;current_clip_valid<=0;
                        list_cache_valid<=0;render_next_target<=0;
                        line_boundary<=0;active_list_valid<=0;
                        state<=S_LIST_REQ;
                    // Resync unconditionally once the renderer next reaches
                    // S_IDLE after a frame boundary. The old
                    // render_next_target>=384 gate meant a producer that fell
                    // behind could satisfy NEITHER resync path: the branch
                    // above only fires if S_IDLE happens to coincide with the
                    // boundary tick, and this one demanded the full 384 lines
                    // it had just failed to render. Since producer and
                    // consumer both advance one line per scanline, that left
                    // render_next_target permanently phase-shifted against
                    // the display's vcount+2 target, so no bank ever matched
                    // and every sprite vanished for the rest of the run. The
                    // boundary above already retires all queued lines, so
                    // there is no partially-scheduled frame worth preserving.
                    end else if(cache_refresh_pending) begin
                        list_index<=0;list_seen<=0;stack_count<=0;
                        stack_head<=0;current_clip_valid<=0;
                        list_cache_valid<=0;render_next_target<=0;
                        line_boundary<=0;active_list_valid<=0;
                        state<=S_LIST_REQ;
                    end else if(render_next_target<9'd384 &&
                                fill_candidate_valid) begin
                        // Fill lines in raster order, recording the actual Y
                        // in each bank so a late line can never masquerade
                        // as another raster line at display time.
                        fill_bank<=fill_candidate;
                        fill_generation<=bank_generation[fill_candidate]+1'b1;
                        bank_generation[fill_candidate]<=
                            bank_generation[fill_candidate]+1'b1;
                        bank_line_y[fill_candidate]<=render_next_target;
                        bank_filling[fill_candidate]<=1;
                        fill_epoch<=frame_epoch;
                        line_valid[fill_candidate]<=0;
                        scrub_req<=1;
                        scrub_addr<={fill_candidate,bank_scrub[fill_candidate]};
                        bank_scrub[fill_candidate]<=
                            bank_scrub[fill_candidate]+1'b1;
                        target_y<=render_next_target;
                        render_next_target<=render_next_target+1'b1;
                        scan_pos<=0;
                        data_cache_valid<=0;palette_cache_valid<=0;
                        if(active_list_valid && !line_boundary[render_next_target]) begin
                            if(active_count==0) begin
                                bank_filling[fill_candidate]<=0;
                                // Claim and completion happen in this same
                                // clock, so fill_epoch still describes the
                                // previous claim here. The S_IDLE boundary/
                                // refresh branches above prove this cached
                                // active list belongs to the current frame.
                                line_valid[fill_candidate]<=!frame_boundary;
                                state<=S_IDLE;
                            end else begin
                                render_pos<=active_count-1'b1;
                                state<=S_RENDER_PREFETCH;
                            end
                        end else begin
                            active_count<=0;
                            state<=S_CLEAR;
                        end
                    end
                end
                S_CLEAR: begin
                    // Pixel generations make a full 496-word clear
                    // unnecessary.  The linked-list cache is still refreshed
                    // exactly as before, but the renderer can use the saved
                    // line budget for the long SSpirits sprite list.
                    if(!list_cache_valid) begin
                        list_index<=0;list_seen<=0;stack_count<=0;
                        stack_head<=0;current_clip_valid<=0;
                        state<=S_LIST_REQ;
                    end else if(stack_count==0) begin
                        active_list_valid<=1;
                        bank_filling[fill_bank]<=0;
                        line_valid[fill_bank]<=fill_epoch==frame_epoch &&
                                                   !frame_boundary;
                        state<=S_IDLE;
                    end else begin
                        // The frame cache contains every vertically eligible
                        // descriptor, not just the current scanline's
                        // entries. Filter it before rendering so long lists do
                        // not spend the line budget fetching off-line sprites.
                        state<=S_SCAN_PREFETCH;
                    end
                end
                S_LIST_REQ: begin
                    // MAME bounds linked-list traversal to all 0x2000 possible
                    // descriptors. A corrupt/cyclic list must not wedge the
                    // scanline renderer indefinitely.
                    if(list_seen==14'd8192) begin
                        list_cache_valid<=1;
                        cache_refresh_pending<=0;
                        state<=S_IDLE;
                    end else begin
						burst_lookup_tag<={1'b0,list_index};
						if(burst_cache_hit) begin
							cache_ack_pending<=1;
						end else begin
							cache_ack_pending<=0;
							mem_addr<=sprite_burst({1'b0,list_index,3'b0});
							mem_req<=1;
						end
                        state<=S_LIST_WAIT;
                    end
                end
                S_LIST_WAIT: if(read_ack) begin
					mem_req<=0;cache_ack_pending<=0;
					descriptor<=read_data;list_seen<=list_seen+1'b1;
                    if((list_index==0 && mem_w0==0) ||
                       mem_w0[15:14]==2'b11) begin
                        list_cache_valid<=1;
                        cache_refresh_pending<=0;
                        state<=S_IDLE;
                    end else begin
                        list_index<=mem_w0[12:0];
                        case(mem_w0[15:14])
                            2'b01: begin
                                current_clip_valid<=1;
                                current_clip_flags<=mem_w1;
                                current_clip_top<=mem_w2;
                                current_clip_left<=mem_w3;
                                current_clip_bottom<=mem_w4;
                                current_clip_right<=mem_w5;
                                state<=S_LIST_REQ;
                            end
                            2'b10: state<=S_LIST_REQ;
                            default: begin
                                // Mark every conservative Y event for this
                                // descriptor. Between these events the
                                // vertically eligible set is invariant, so
                                // the previous active-cache contents are
                                // exactly reusable on the next line.
                                if(list_origin_y>=0 && list_origin_y<14'sd384)
                                    line_boundary[list_origin_y[8:0]]<=1'b1;
                                if(list_bottom_y>=0 && list_bottom_y<14'sd384)
                                    line_boundary[list_bottom_y[8:0]]<=1'b1;
                                if(current_clip_valid) begin
                                    if(current_clip_top[8:0]<9'd384)
                                        line_boundary[current_clip_top[8:0]]<=1'b1;
                                    if(current_clip_bottom[8:0]<9'd384)
                                        line_boundary[current_clip_bottom[8:0]]<=1'b1;
                                    if(current_clip_top[8:0]<9'd383)
                                        line_boundary[current_clip_top[8:0]+1'b1]<=1'b1;
                                    if(current_clip_bottom[8:0]<9'd383)
                                        line_boundary[current_clip_bottom[8:0]+1'b1]<=1'b1;
                                end
                                if(stack_count<STACK_COUNT_LIMIT)
                                    stack_count<=stack_count+1'b1;
                                else
                                    stack_head<=stack_head+1'b1;
                                if(mem_w0[12:0]==0) begin
                                    list_cache_valid<=1;
                                    cache_refresh_pending<=0;
                                    state<=S_IDLE;
                                end else state<=S_LIST_REQ;
                            end
                        endcase
                    end
                end
                S_SCAN_PREFETCH: state<=S_SCAN;
                S_SCAN: begin
                    if(scan_quad_valid) begin
                        if(scan_quad_active_count!=0) begin
                            if(active_count<ACTIVE_COUNT_LIMIT)
                                active_count<=active_count+1'b1;
                            scan_quad_pending_count<=scan_quad_active_count-1'b1;
                            scan_quad_last<=(scan_next_pos>=stack_count);
                            scan_quad_pending_descriptor[0]<=scan_quad_batch_pending_descriptor[0];
                            scan_quad_pending_descriptor[1]<=scan_quad_batch_pending_descriptor[1];
                            scan_quad_pending_descriptor[2]<=scan_quad_batch_pending_descriptor[2];
                            scan_quad_pending_clip[0]<=scan_quad_batch_pending_clip[0];
                            scan_quad_pending_clip[1]<=scan_quad_batch_pending_clip[1];
                            scan_quad_pending_clip[2]<=scan_quad_batch_pending_clip[2];
                            if(scan_quad_active_count>1)
                                state<=S_SCAN_QUAD_DRAIN;
                            else if(scan_next_pos>=stack_count) begin
                                render_pos<=active_append_pos;
                                state<=S_RENDER_PREFETCH;
                            end else begin
                                scan_pos<=scan_next_pos;
                            end
                        end else if(scan_next_pos>=stack_count) begin
                            if(active_count!=0) begin
                                render_pos<=active_count-1'b1;
                                state<=S_RENDER_PREFETCH;
                            end else begin
                                bank_filling[fill_bank]<=0;
                                line_valid[fill_bank]<=fill_epoch==frame_epoch &&
                                                           !frame_boundary;
                                state<=S_IDLE;
                            end
                        end else begin
                            scan_pos<=scan_next_pos;
                        end
                    end else if(scan_active && scan1_active) begin
                        scan_second_descriptor<=scan_descriptor1;
                        scan_second_clip<=scan_clip1;
                        if(active_count<ACTIVE_COUNT_LIMIT)
                            active_count<=active_count+1'b1;
                        // The active descriptor cache has one write port. Only
                        // both descriptors are active need this second cycle;
                        // sparse long lists still approach two descriptors
                        // filtered per clock.
                        scan_second_last<=(scan_next_pos>=stack_count);
                        state<=S_SCAN_SECOND;
                    end else begin
                        if(scan_active || scan1_active) begin
                            if(active_count<ACTIVE_COUNT_LIMIT)
                                active_count<=active_count+1'b1;
                        end
                        if(scan_next_pos>=stack_count) begin
                            if(scan_active || scan1_active) begin
                                render_pos<=active_append_pos;
                                state<=S_RENDER_PREFETCH;
                            end else if(active_count!=0) begin
                                render_pos<=active_count-1'b1;
                                state<=S_RENDER_PREFETCH;
                            end else begin
                                bank_filling[fill_bank]<=0;
                                line_valid[fill_bank]<=fill_epoch==frame_epoch &&
                                                           !frame_boundary;
                                state<=S_IDLE;
                            end
                        end else begin
                            scan_pos<=scan_next_pos;
                        end
                    end
                end
                S_SCAN_SECOND: begin
                    if(active_count<ACTIVE_COUNT_LIMIT)
                        active_count<=active_count+1'b1;
                    if(scan_second_last) begin
                        render_pos<=active_append_pos;
                        state<=S_RENDER_PREFETCH;
                    end else begin
                        scan_pos<=scan_next_pos;
                        state<=S_SCAN;
                    end
                end
                S_SCAN_QUAD_DRAIN: begin
                    if(active_count<ACTIVE_COUNT_LIMIT)
                        active_count<=active_count+1'b1;
                    if(scan_quad_pending_count>1) begin
                        scan_quad_pending_count<=scan_quad_pending_count-1'b1;
                        scan_quad_pending_descriptor[0]<=scan_quad_pending_descriptor[1];
                        scan_quad_pending_descriptor[1]<=scan_quad_pending_descriptor[2];
                        scan_quad_pending_clip[0]<=scan_quad_pending_clip[1];
                        scan_quad_pending_clip[1]<=scan_quad_pending_clip[2];
                    end else begin
                        scan_quad_pending_count<=0;
                        if(scan_quad_last) begin
                            render_pos<=active_append_pos;
                            state<=S_RENDER_PREFETCH;
                        end else begin
                            scan_pos<=scan_next_pos;
                            state<=S_SCAN;
                        end
                    end
                end
                S_RENDER_PREFETCH: begin
                    active_list_valid<=1;
                    state<=S_RENDER_WAIT;
                end
                S_RENDER_REQ: state<=S_RENDER_WAIT;
                S_RENDER_WAIT: begin
                    descriptor<=active_render_descriptor;
                    render_clip<=active_render_clip;
                    flipx<=render_w5[15];
                    flipy<=render_w4[15];
                    size_x_tiles<=8'd1<<render_w5[14:12];
                    size_x_shift<=render_w5[14:12];
                    size_y_shift<=render_w4[14:12];
                    size_y_mask<=(8'd1<<render_w4[14:12])-8'd1;
                    if(!render_w0[13]) begin
                        zoomx_step<=(render_w1[7:0]==0)?9'h040:
                                   {1'b0,render_w1[7:0]}+1'b1;
                        zoomy_step<=(render_w1[7:0]==0)?9'h040:
                                   {1'b0,render_w1[7:0]}+1'b1;
                    end else begin
                        zoomx_step<=(render_w1[15:8]==0)?9'h040:
                                   {1'b0,render_w1[15:8]}+1'b1;
                        zoomy_step<=(render_w1[7:0]==0)?9'h040:
                                   {1'b0,render_w1[7:0]}+1'b1;
                    end
                    descriptor_origin_x<=$signed({render_w5[11],
                                                   render_w5[11:0]})-13'sd8;
                    descriptor_output_width<=descriptor_width_sum[18:6];
                    if(active_setup_origin_x>active_setup_clip_max_x ||
                       active_setup_right_x<active_setup_clip_min_x) begin
                        state<=S_NEXT_SPRITE;
                    end else if(active_setup_zoomy_step==9'h040) begin
                        if(!active_setup_vertical_allowed ||
                           $signed({4'd0,target_y})<active_setup_origin_y ||
                           $signed({4'd0,target_y})>=active_setup_bottom_y) begin
                            dest_y<=active_setup_origin_y;
                            source_row<=0;y_accum<=6'h20;
                            state<=S_NEXT_SPRITE;
                        end else begin
                            dest_y<=$signed({4'd0,target_y});
                            source_row<=source_row_delta($signed({4'd0,target_y})
                                                         -active_setup_origin_y);
                            y_accum<=6'h20;state<=S_YMAP;
                        end
                    end else if(!active_setup_vertical_allowed ||
                                $signed({4'd0,target_y})<active_setup_origin_y) begin
                        dest_y<=active_setup_origin_y;
                        source_row<=0;y_accum<=6'h20;
                        state<=S_NEXT_SPRITE;
                    end else begin
                        ydiv_dividend<=({6'd0,active_setup_target_offset}
                                         << 6) + 18'd31;
                        ydiv_quotient<=0;ydiv_remainder<=0;
                        ydiv_divisor<=active_setup_zoomy_step;
                        ydiv_total_rows<=active_setup_total_rows;
                        ydiv_count<=5'd9;state<=S_YDIV;
                    end
                end
                S_RENDER_SETUP: begin
                    // MAME tests each emitted X against the clip rectangle.
                    // Rejecting a descriptor whose complete scaled span
                    // cannot intersect it is exactly equivalent and avoids
                    // needless palette/data traffic for long lists.
                    if(descriptor_origin_x>$signed(clip_max_x) ||
                       descriptor_right_x<$signed(clip_min_x)) begin
                        state<=S_NEXT_SPRITE;
                    // 1:1 is by far the common sprite case (Hot Rod's title
                    // has 27/27 descriptors at step 0x40). Map the scanline
                    // directly instead of walking from the sprite top for
                    // every output line. This removes the remaining line-
                    // buffer overruns without a divider, multiplier, RAM or
                    // DSP. Other zoom factors retain the exact accumulator.
                    end else if(descriptor_zoomy_step==9'h040) begin
                        if(!vertical_allowed ||
                           $signed({4'd0,target_y})<descriptor_origin_y ||
                           $signed({4'd0,target_y})>=descriptor_bottom_y) begin
                            dest_y<=descriptor_origin_y;
                            source_row<=0;y_accum<=6'h20;
                            state<=S_NEXT_SPRITE;
                        end else begin
                            dest_y<=$signed({4'd0,target_y});
                            source_row<=source_row_delta($signed({4'd0,target_y})
                                                         - descriptor_origin_y);
                            y_accum<=6'h20;state<=S_YMAP;
                        end
                    end else begin
                        if(!vertical_allowed ||
                           $signed({4'd0,target_y})<descriptor_origin_y) begin
                            dest_y<=descriptor_origin_y;
                            source_row<=0;y_accum<=6'h20;
                            state<=S_NEXT_SPRITE;
                        end else begin
                            // Exact bounded division for arbitrary zoom:
                            // r=floor((64*(target-origin)+31)/step).
                            // A 9-cycle radix-4 restoring divider is much smaller
                            // than a combinational divider and replaces an
                            // unbounded source-row walk. The final remainder
                            // reconstructs both row origin and accumulator,
                            // so no multiplier or DSP is needed.
                            ydiv_dividend<=({6'd0,descriptor_target_offset}
                                           << 6) + 18'd31;
                            ydiv_quotient<=0;ydiv_remainder<=0;
                            ydiv_divisor<=descriptor_zoomy_step;
                            ydiv_total_rows<=descriptor_total_rows;
                            ydiv_count<=5'd9;state<=S_YDIV;
                        end
                    end
                end
                S_YDIV: begin
                    ydiv_dividend<={ydiv_dividend[15:0],2'b00};
                    ydiv_remainder<=ydiv_next_remainder;
                    ydiv_quotient<=ydiv_next_quotient;
                    if(ydiv_count==1) begin
                        ydiv_count<=0;
                        if(ydiv_next_quotient>=ydiv_total_rows) begin
                            state<=S_NEXT_SPRITE;
                        end else begin
                            source_row<=ydiv_next_quotient[10:0];
                            dest_y<=$signed({4'd0,target_y})
                                    + (ydiv_adjust_value >>> 6);
                            y_accum<=ydiv_adjust_value[5:0];
                            state<=S_YMAP;
                        end
                    end else ydiv_count<=ydiv_count-1'b1;
                end
                S_YMAP: begin
                    if(!vertical_allowed || dest_y>$signed({4'd0,target_y}) ||
                       source_row>=total_rows) state<=S_NEXT_SPRITE;
                    else if(($signed({4'd0,target_y})>=dest_y) &&
                            ($signed({4'd0,target_y})<dest_y+$signed({10'd0,y_sum[8:6]}))) begin
                        if(palette_cache_hit) begin
                            palette_table<=palette_cache_data[palette_cache_index];
                            source_column<=0;x_accum<=6'h20;
                            dest_x<=$signed({d5[11],d5[11:0]})-13'sd8;
                            state<=S_X_SOURCE;
                        end else begin
							burst_lookup_tag<=palette_base;
							if(burst_cache_hit) begin
								cache_ack_pending<=1;
							end else begin
								cache_ack_pending<=0;
								mem_addr<=sprite_burst({palette_base,3'b0});
								mem_req<=1;
							end
                            state<=S_PALETTE_WAIT;
                        end
                    end else begin
                        dest_y<=dest_y+{10'd0,y_sum[8:6]};
                        y_accum<=y_sum[5:0];source_row<=source_row+1'b1;
                    end
                end
                S_PALETTE_WAIT: if(read_ack) begin
					mem_req<=0;cache_ack_pending<=0;
					palette_table<=read_data;source_column<=0;
					palette_cache_data[palette_cache_index]<=read_data;
                    palette_cache_tags[palette_cache_index]<=palette_base;
                    palette_cache_valid[palette_cache_index]<=1;
                    x_accum<=6'h20;
                    dest_x<=$signed({d5[11],d5[11:0]})-13'sd8;
                    state<=S_X_SOURCE;
                end
                S_X_SOURCE: begin
                    if(source_column>=total_columns) state<=S_NEXT_SPRITE;
                    else if(x_sum[8:6]==0) begin
                        x_accum<=x_sum[5:0];source_column<=source_column+1'b1;
                    end else if(!data_cache_valid || data_cache_tag!=wanted_tag) begin
						burst_lookup_tag<=wanted_tag;
						if(burst_cache_hit) begin
							cache_ack_pending<=1;
						end else begin
							cache_ack_pending<=0;
							mem_addr<=sprite_burst({wanted_tag,3'b000});
							mem_req<=1;
						end
                        state<=S_DATA_WAIT;
                    end else if(zoomx_step==9'h040 && zoomy_step==9'h040 &&
                                source_column[1:0]==2'b00 &&
                                source_column+11'd4<=total_columns) begin
                        state<=S_X_EMIT4;
                    end else begin
                        emit_count<=x_sum[8:6];x_accum<=x_sum[5:0];
                        state<=S_X_EMIT;
                    end
                end
                S_DATA_WAIT: if(read_ack) begin
					mem_req<=0;cache_ack_pending<=0;
					data_cache<=read_data;data_cache_tag<=wanted_tag;
                    data_cache_valid<=1;
                    // This request was issued only after S_X_SOURCE proved
                    // x_sum nonzero and the source column in range.  Bypass
                    // that identical decision on return, saving one clock per
                    // tile burst while preserving the exact emit path.
                    if(zoomx_step==9'h040 && zoomy_step==9'h040 &&
                       source_column[1:0]==2'b00 &&
                       source_column+11'd4<=total_columns) begin
                        state<=S_X_EMIT4;
                    end else begin
                        emit_count<=x_sum[8:6];
                        x_accum<=x_sum[5:0];
                        state<=S_X_EMIT;
                    end
                end
                S_X_EMIT: begin
                    // Once a 1:1 row is resident, emit consecutive pixels
                    // every clock. The render RAM read port is already one
                    // destination pixel ahead in this state. A burst-boundary
                    // cache miss pauses without advancing and resumes safely.
                    if(!data_cache_valid || data_cache_tag!=wanted_tag) begin
						burst_lookup_tag<=wanted_tag;
						if(burst_cache_hit) begin
							cache_ack_pending<=1;
						end else begin
							cache_ack_pending<=0;
							mem_addr<=sprite_burst({wanted_tag,3'b000});
							mem_req<=1;
						end
						state<=S_DATA_WAIT;
                    end else begin
                        dest_x<=dest_x+1'b1;
                        if(emit_count==1) begin
                            source_column<=source_column+1'b1;
                            if(source_column+1'b1>=total_columns) begin
                                emit_count<=0;state<=S_NEXT_SPRITE;
                            end else if(zoomx_step==9'h040) begin
                                emit_count<=1;state<=S_X_EMIT;
                            end else begin
                                emit_count<=0;state<=S_X_SOURCE;
                            end
                        end else emit_count<=emit_count-1'b1;
                    end
                end
                S_X_EMIT4: begin
                    // Four adjacent pixels occupy four distinct interleaved
                    // X lanes.  The source column is aligned to a four-pixel
                    // group, so each group remains inside one 8-pixel tile;
                    // tile-row and flip mapping remain exact for larger
                    // sprites too.
                    if(!data_cache_valid || data_cache_tag!=lane_tag[0]) begin
						burst_lookup_tag<=lane_tag[0];
						if(burst_cache_hit) begin
							cache_ack_pending<=1;
						end else begin
							cache_ack_pending<=0;
							mem_addr<=sprite_burst({lane_tag[0],3'b000});
							mem_req<=1;
						end
						state<=S_DATA_WAIT;
                    end else begin
                        dest_x<=dest_x+13'sd4;
                        source_column<=source_column+11'd4;
                        if(source_column+11'd4>=total_columns)
                            state<=S_NEXT_SPRITE;
                        else state<=S_X_SOURCE;
                    end
                end
                S_NEXT_SPRITE: begin
                    if(render_pos==0) begin
                        bank_filling[fill_bank]<=0;
                        line_valid[fill_bank]<=fill_epoch==frame_epoch &&
                                                   !frame_boundary;
                        state<=S_IDLE;
                    end
                    else begin
                        // The active-cache port has been reading the next
                        // reverse-order descriptor throughout the current
                        // sprite.  At this boundary its registered output is
                        // already valid, so consume it here and avoid a
                        // redundant per-sprite wait state.
                        render_pos<=render_pos-1'b1;
                        descriptor<=active_render_descriptor;
                        render_clip<=active_render_clip;
                        flipx<=render_w5[15];
                        flipy<=render_w4[15];
                        size_x_tiles<=8'd1<<render_w5[14:12];
                        size_x_shift<=render_w5[14:12];
                        size_y_shift<=render_w4[14:12];
                        size_y_mask<=(8'd1<<render_w4[14:12])-8'd1;
                        if(!render_w0[13]) begin
                            zoomx_step<=(render_w1[7:0]==0)?9'h040:
                                       {1'b0,render_w1[7:0]}+1'b1;
                            zoomy_step<=(render_w1[7:0]==0)?9'h040:
                                       {1'b0,render_w1[7:0]}+1'b1;
                        end else begin
                            zoomx_step<=(render_w1[15:8]==0)?9'h040:
                                       {1'b0,render_w1[15:8]}+1'b1;
                            zoomy_step<=(render_w1[7:0]==0)?9'h040:
                                       {1'b0,render_w1[7:0]}+1'b1;
                        end
                        descriptor_origin_x<=$signed({render_w5[11],
                                                       render_w5[11:0]})-13'sd8;
                        descriptor_output_width<=descriptor_width_sum[18:6];
                        if(active_setup_origin_x>active_setup_clip_max_x ||
                           active_setup_right_x<active_setup_clip_min_x) begin
                            state<=S_NEXT_SPRITE;
                        end else if(active_setup_zoomy_step==9'h040) begin
                            if(!active_setup_vertical_allowed ||
                               $signed({4'd0,target_y})<active_setup_origin_y ||
                               $signed({4'd0,target_y})>=active_setup_bottom_y) begin
                                dest_y<=active_setup_origin_y;
                                source_row<=0;y_accum<=6'h20;
                                state<=S_NEXT_SPRITE;
                            end else begin
                                dest_y<=$signed({4'd0,target_y});
                                source_row<=source_row_delta($signed({4'd0,target_y})
                                                             -active_setup_origin_y);
                                y_accum<=6'h20;state<=S_YMAP;
                            end
                        end else if(!active_setup_vertical_allowed ||
                                    $signed({4'd0,target_y})<active_setup_origin_y) begin
                            dest_y<=active_setup_origin_y;
                            source_row<=0;y_accum<=6'h20;
                            state<=S_NEXT_SPRITE;
                        end else begin
                            ydiv_dividend<=({6'd0,active_setup_target_offset}
                                             << 6) + 18'd31;
                            ydiv_quotient<=0;ydiv_remainder<=0;
                            ydiv_divisor<=active_setup_zoomy_step;
                            ydiv_total_rows<=active_setup_total_rows;
                            ydiv_count<=5'd9;state<=S_YDIV;
                        end
                    end
                end
                default: begin
                    // Recover conservatively from an illegal state: cancel
                    // the producer transaction instead of leaking ownership
                    // forever or publishing a partially rendered line.
                    mem_req<=0;
					cache_ack_pending<=0;
                    bank_filling<='0;
                    line_valid[fill_bank]<=0;
                    active_list_valid<=0;
                    state<=S_IDLE;
                end
            endcase

			// The unified cache is write-snooped at burst granularity. Also
			// discard the two smaller hot entries that bypass its tag lookup.
			// This comes after the state updates so invalidation wins a same-
			// clock cache return from the old contents.
			if(cache_invalidate) begin
				if(data_cache_valid && data_cache_tag==cache_invalidate_tag)
					data_cache_valid<=0;
				if(palette_cache_valid[cache_invalidate_tag[2:0]] &&
				   palette_cache_tags[cache_invalidate_tag[2:0]]==
					cache_invalidate_tag)
					palette_cache_valid[cache_invalidate_tag[2:0]]<=0;
			end
        end
    end

`ifdef VERILATOR
    // Bank ownership is deliberately simulation-checked here rather than
    // exposed through a debug menu or synthesized telemetry.
    always_ff @(posedge clk) if(!reset) begin
        assert((line_valid & bank_filling)=='0)
            else $fatal(1,"sprite bank simultaneously filling and valid");
        assert($onehot0(bank_filling))
            else $fatal(1,"multiple sprite line banks owned by producer");
        if(|bank_filling) begin
            assert(bank_filling[fill_bank])
                else $fatal(1,"sprite fill_bank does not name owned bank");
            assert(fill_bank!=display_bank)
                else $fatal(1,"sprite producer overwrote display bank");
        end
        if(state==S_IDLE)
            assert(bank_filling=='0)
                else $fatal(1,"sprite bank ownership leaked into idle");
		// The arithmetic bench proves the shared radix-4 step exhaustively;
		// sprite scenarios prove that the live controller maintains its input
		// invariant and uses exactly the bounded nine-cycle schedule.
		if(state==S_YDIV) begin
			assert(ydiv_count>=5'd1 && ydiv_count<=5'd9);
			assert(ydiv_divisor!=9'd0);
			assert(ydiv_remainder<{10'd0,ydiv_divisor});
		end
    end
`endif
endmodule
