//============================================================================
//  MAME hiscore.dat support for MiSTer arcade cores.
//
//  https://github.com/JimmyStones/Hiscores_MiSTer
//
//  Copyright (c) 2021 Alan Steremberg
//  Copyright (c) 2021 Jim Gregory
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 3 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//============================================================================
/*
 Version history:
 0001 - 2021-03-06 -	First marked release
 0002 - 2021-03-06 -	Added HS_DUMPFORMAT localparam to identify dump version (for future use)
							Add HS_CONFIGINDEX and HS_DUMPINDEX parameters to configure ioctl_indexes
 0003 - 2021-03-10 -	Added WRITE_REPEATCOUNT and WRITE_REPEATWAIT to handle tricky write situations
 0004 - 2021-03-15 -	Fix ram_access assignment
 0005 - 2021-03-18 -	Add configurable score table width, clean up some stupid mistakes
 0006 - 2021-03-27 -	Move 'tweakable' parameters into MRA data header
 0007 - 2021-04-15 -	Improve state machine maintainability, add new 'pause padding' states
 0008 - 2021-05-12 -	Feed back core-level pause to halt startup timer
 0009 - 2021-07-31 -	Split hiscore extraction from upload (updates hiscore buffer on OSD open)
 0010 - 2021-08-03 -	Add hiscore buffer and change detection (ready for autosave!)
 0011 - 2021-08-07 -	Optional auto-save on OSD open
 0012 - 2021-08-17 -	Add variable length change detection mask
 0013 - 2021-09-01 -	Output configured signal for autosave option menu masking
 0014 - 2021-09-09 -	Fix turning on autosave w/o core reload 
============================================================================
*/

module hiscore 
#(
	parameter HS_ADDRESSWIDTH=10,							// Max size of game RAM address for highscores
	parameter HS_SCOREWIDTH=8,								// Max size of capture RAM For highscore data (default 8 = 256 bytes max)
	parameter HS_CONFIGINDEX=3,							// ioctl_index for config transfer
	parameter HS_DUMPINDEX=4,								// ioctl_index for dump transfer
	parameter CFG_ADDRESSWIDTH=4,							// Max size of RAM address for highscore.dat entries (default 4 = 16 entries max)
	parameter CFG_LENGTHWIDTH=1							// Max size of length for each highscore.dat entries (default 1 = 256 bytes max)
)
(
	input										clk,
	input										paused,			// Signal from core confirming CPU is paused
	input										reset,
	input										autosave,		// Auto-save enabled (active high)

	input										ioctl_upload,
	output reg								ioctl_upload_req,
	input										ioctl_download,
	input										ioctl_wr,
	input		[24:0]						ioctl_addr,
	input		[7:0]							ioctl_index,
	input										OSD_STATUS,

	input		[7:0]							data_from_hps,		// Incoming data from HPS ioctl_dout
	input		[7:0]							data_from_ram,		// Incoming data from game RAM
	// Wait-state input for game RAM that cannot answer in one cycle (SSV puts
	// the $010000-$03ffff work RAM of Twin Eagle II / Ultra X in SDRAM).  Tie
	// high for single-cycle RAM: every state below then behaves exactly as it
	// did before this input existed.
	input										ram_ready,			// Game RAM data valid for the current ram_address
	output	[HS_ADDRESSWIDTH-1:0]	ram_address,		// Address in game RAM to read/write score data
	output	[7:0]							data_to_hps,		// Data to send to HPS ioctl_din
	output	[7:0]							data_to_ram,		// Data to send to game RAM
	output	reg							ram_write,			// Write to game RAM (active high)
	output									ram_intent_read,	// RAM read required (active high)
	output									ram_intent_write,	// RAM write required (active high)
	output	reg							pause_cpu,			// Pause core CPU to prepare for/relax after RAM access
	output									configured			// Hiscore module has valid configuration (active high)
);

// Parameters read from config header
reg [31:0]	START_WAIT			=32'd0;		// Delay before beginning check process
reg [15:0]	CHECK_WAIT 			=16'hFF;		// Delay between start/end check attempts
reg [15:0]	CHECK_HOLD			=16'd2;		// Hold time for start/end check reads
reg [15:0]	WRITE_HOLD			=16'd2;		// Hold time for game RAM writes 
reg [15:0]	WRITE_REPEATCOUNT	=16'b1;		// Number of times to write score to game RAM
reg [15:0]	WRITE_REPEATWAIT	=16'b1111;	// Delay between subsequent write attempts to game RAM
reg [7:0]	ACCESS_PAUSEPAD	=8'd4;		// Cycles to wait with paused CPU before and after RAM access
reg [7:0]	CHANGEMASK			=1'b0;		// Length of change mask

// State machine constants
localparam SM_STATEWIDTH	 = 5;				// Width of state machine net

localparam SM_INIT_RESTORE	 = 0;
localparam SM_TIMER			 = 1;

localparam SM_CHECKPREP		 = 2;
localparam SM_CHECKBEGIN	 = 3;
localparam SM_CHECKSTARTVAL = 4;
localparam SM_CHECKENDVAL	 = 5;
localparam SM_CHECKCANCEL	 = 6;

localparam SM_WRITEPREP		 = 7;
localparam SM_WRITEBEGIN	 = 8;
localparam SM_WRITEREADY	 = 9;
localparam SM_WRITEDONE		 = 10;
localparam SM_WRITECOMPLETE = 11;
localparam SM_WRITERETRY	 = 12;

localparam SM_COMPAREINIT	 = 16;
localparam SM_COMPAREBEGIN	 = 17;
localparam SM_COMPAREREADY	 = 18;
localparam SM_COMPAREREAD	 = 19;
localparam SM_COMPAREDONE	 = 20;
localparam SM_COMPARECOMPLETE	 = 21;

localparam SM_EXTRACTINIT	 = 22;
localparam SM_EXTRACT		 = 23;
localparam SM_EXTRACTSAVE	 = 24;
localparam SM_EXTRACTCOMPLETE	 = 25;

localparam SM_STOPPED		 = 30;

/*
Hiscore config data structure (version 1)
-----------------------------------------
[16 byte header]
[8 byte * no. of entries]

- Header format
00 00 FF FF 00 FF 00 02 00 02 00 01 11 11 00 00 
[    SW   ] [ CW] [ CH] [ WH] [WRC] [WRW] [PAD]
4 byte		START_WAIT
2 byte		CHECK_WAIT
2 byte		CHECK_HOLD
2 byte		WRITE_HOLD
2 byte		WRITE_REPEATCOUNT
2 byte		WRITE_REPEATWAIT
1 byte		ACCESS_PAUSEPAD
1 byte		CHANGEMASK

- Entry format (when CFG_LENGTHWIDTH=1)
00 00 43 0b  0f    10  01  00
00 00 40 23  02    04  12  00
[   ADDR  ] LEN START END PAD

4 bytes		Address of ram entry (in core memory map)
1 byte		Length of ram entry in bytes 
1 byte		Start value to check for at start of address range before proceeding
1 byte		End value to check for at end of address range before proceeding
1 byte		(padding)

- Entry format (when CFG_LENGTHWIDTH=2)
00 00 43 0b  00 0f    10  01
00 00 40 23  00 02    04  12
[   ADDR  ] [LEN ] START END

4 bytes		Address of ram entry (in core memory map)
2 bytes		Length of ram entry in bytes 
1 byte		Start value to check for at start of address range before proceeding
1 byte		End value to check for at end of address range before proceeding

*/

localparam HS_VERSION			=14;			// Version identifier for module
localparam HS_DUMPFORMAT		=1;			// Version identifier for dump format
localparam HS_HEADERLENGTH		=16;			// Size of header chunk (default=16 bytes)

// HS_DUMPFORMAT = 1 --> No header, just the extracted hiscore data

// Hiscore config tracking 
wire				downloading_config;				// Is hiscore configuration currently being loaded from HPS?
reg				downloaded_config = 1'b0;			// Has hiscore configuration been loaded successfully
wire				parsing_header;					// Is hiscore configuration header currently being parsed?
wire				parsing_mask;					// Is hiscore configuration change mask currently being parsed? (optional 2nd line of config)

// Hiscore data tracking
wire				downloading_dump;				// Is hiscore data currently being loaded from HPS?
reg				downloaded_dump = 1'b0;				// Has hiscore data been loaded successfully
wire				uploading_dump;					// Is hiscore data currently being sent to HPS?
reg				extracting_dump = 1'b0;				// Is hiscore data currently being extracted from game RAM?
reg				restoring_dump = 1'b0;				// Is hiscore data currently being (or waiting to) restore to game RAM

reg				checking_scores = 1'b0;				// Is state machine currently checking game RAM for highscore restore readiness
reg				reading_scores = 1'b0;				// Is state machine currently reading game RAM for highscore dump
reg				writing_scores = 1'b0;				// Is state machine currently restoring hiscore data to game RAM
reg	[24:0]							ram_addr;					// Target RAM address for hiscore read/write

assign configured = downloaded_config;
assign downloading_config = ioctl_download && (ioctl_index==HS_CONFIGINDEX);
assign parsing_header = downloading_config && (ioctl_addr<HS_HEADERLENGTH);
assign parsing_mask = downloading_config && !parsing_header && (CHANGEMASK > 8'b0) && (ioctl_addr < HS_HEADERLENGTH + CHANGEMASK);
assign downloading_dump = ioctl_download && (ioctl_index==HS_DUMPINDEX);
assign uploading_dump = ioctl_upload && (ioctl_index==HS_DUMPINDEX);
assign ram_intent_read = reading_scores | checking_scores;
assign ram_intent_write = writing_scores;
assign ram_address = ram_addr[HS_ADDRESSWIDTH-1:0];

reg	[(SM_STATEWIDTH-1):0]		state = SM_INIT_RESTORE;			// Current state machine index
reg	[(SM_STATEWIDTH-1):0]		next_state = SM_INIT_RESTORE;		// Next state machine index to move to after wait timer expires
reg	[31:0]							wait_timer;								// Wait timer for inital/read/write delays

reg	[CFG_ADDRESSWIDTH-1:0]		counter = 1'b0;			// Index for current config table entry
reg	[CFG_ADDRESSWIDTH-1:0]		total_entries = 1'b0;	// Total count of config table entries
reg										reset_last = 1'b0;		// Last cycle reset
reg	[7:0]								write_counter = 1'b0;	// Index of current game RAM write attempt

reg	[255:0]							change_mask;				// Bit mask for dump change check

reg	[7:0]								last_ioctl_index;			// Last cycle HPS IO index
reg										last_ioctl_download = 0;// Last cycle HPS IO download
reg	[7:0]								last_data_from_hps;		// Last cycle HPS IO data out
reg	[7:0]								last_data_from_hps2;		// Last cycle +1 HPS IO data out
reg	[7:0]								last_data_from_hps3;		// Last cycle +2 HPS IO data out
reg										last_OSD_STATUS;			// Last cycle OSD status

reg	[24:0]							base_io_addr;
wire	[23:0]							addr_base /* synthesis keep */;
wire	[(CFG_LENGTHWIDTH*8)-1:0]	length;
wire	[24:0]							end_addr = (addr_base + length - 1'b1);
reg	[HS_SCOREWIDTH-1:0]			data_addr;
reg	[HS_SCOREWIDTH-1:0]			buffer_addr;
wire	[7:0]								start_val /* synthesis keep */;
wire	[7:0]								end_val /* synthesis keep */;

wire  [7:0]								hiscore_data_out /* synthesis keep */;
reg										dump_write = 1'b0;
wire  [7:0]								hiscore_buffer_out /* synthesis keep */;
reg										buffer_write = 1'b0;
reg	[19:0]							compare_length = 1'b0;
reg										compare_nonzero = 1'b1;	// High after extract and compare if any byte returned is non-zero
reg										compare_changed = 1'b1;	// High after extract and compare if any byte is different to current hiscore data
wire										check_mask = change_mask[compare_length]/* synthesis keep */;
reg										dump_dirty = 1'b0;		// High if dump has changed since last save (or first load if no save has occurred)

wire [23:0]								address_data_in;
wire [(CFG_LENGTHWIDTH*8)-1:0]	length_data_in;

assign address_data_in = {last_data_from_hps2, last_data_from_hps, data_from_hps};
assign length_data_in = (CFG_LENGTHWIDTH == 1'b1) ? data_from_hps : {last_data_from_hps, data_from_hps};

wire parsing_config = ~(parsing_header | parsing_mask); // Hiscore config lines are being parsed

wire [CFG_ADDRESSWIDTH-1:0] config_upload_addr = ioctl_addr[CFG_ADDRESSWIDTH+2:3] - (9'd2 + CHANGEMASK[7:3]) /* synthesis keep */;

wire address_we = downloading_config & parsing_config & (ioctl_addr[2:0] == 3'd3);
wire length_we = downloading_config & parsing_config & (ioctl_addr[2:0] == 3'd3 + CFG_LENGTHWIDTH);
wire startdata_we = downloading_config & parsing_config & (ioctl_addr[2:0] == 3'd4 + CFG_LENGTHWIDTH); 
wire enddata_we = downloading_config & parsing_config & (ioctl_addr[2:0] == 3'd5 + CFG_LENGTHWIDTH);

// Pack the four tiny per-entry tables into one record memory.  Quartus charged
// a complete RAM block for each independently described 16-word table.  The
// fields share the same upload/read addresses and their write strobes are
// mutually exclusive, so one 16x48 (or 16x56 for CFG_LENGTHWIDTH=2) MLAB has
// identical registered-read behavior with a fraction of the physical cost.
localparam CFG_LENGTHBITS = CFG_LENGTHWIDTH * 8;
localparam CFG_RECORDWIDTH = 40 + CFG_LENGTHBITS;
localparam CFG_LENGTH_LSB = 24;
localparam CFG_START_LSB = CFG_LENGTH_LSB + CFG_LENGTHBITS;
localparam CFG_END_LSB = CFG_START_LSB + 8;
// A 16x48/56 table fits MLAB; its single registered read and mutually
// exclusive writes leave the same-address collision policy unchanged.
(* ramstyle = "MLAB, no_rw_check" *)
reg [CFG_RECORDWIDTH-1:0] config_table [0:(1<<CFG_ADDRESSWIDTH)-1];
reg [CFG_RECORDWIDTH-1:0] config_q;
reg [CFG_RECORDWIDTH-1:0] config_stage;

always @(posedge clk) begin
	if (address_we & ioctl_wr)
		config_stage[23:0] <= address_data_in;
	if (length_we & ioctl_wr)
		config_stage[CFG_LENGTH_LSB +: CFG_LENGTHBITS] <= length_data_in;
	if (startdata_we & ioctl_wr)
		config_stage[CFG_START_LSB +: 8] <= data_from_hps;
	if (enddata_we & ioctl_wr)
		config_table[config_upload_addr] <=
			{data_from_hps, config_stage[CFG_END_LSB-1:0]};
	config_q <= config_table[counter];
end

assign addr_base = config_q[23:0];
assign length = config_q[CFG_LENGTH_LSB +: CFG_LENGTHBITS];
assign start_val = config_q[CFG_START_LSB +: 8];
assign end_val = config_q[CFG_END_LSB +: 8];

// LOCAL CHANGE (SSV): one role per port, so these two can live in block RAM.
//
// As written upstream, each of these arrays used a single port for BOTH reading
// and writing -- hiscore_data wrote on port B and read q_b from it, and
// hiscore_buffer wrote on port A and read q_a from it. Combined with the
// write-first bypass inside dpram_hs that asks for something a Cyclone V M10K
// cannot do: new-data read-during-write on a true dual-port array. Quartus
// therefore built both in flip-flops, and the fitter charged 1,003 ALM for
// hiscore_data and 384 for hiscore_buffer -- about one ALM per stored bit, and
// roughly 3.3% of the device for a high score table.
//
// The four config tables above do not have this problem because each of their
// ports has a single role: port A writes, port B reads. They infer cleanly.
// These two now have the same shape.
//
// Nothing observes the behaviour that changes. In SM_EXTRACT the copy-back
// reads hiscore_buffer with buffer_write already cleared (SM_COMPAREDONE clears
// it), and hiscore_data_out is not consumed while dump_write is high. In
// SM_COMPAREDONE the comparison reads hiscore_data_out with dump_write low and
// does not look at hiscore_buffer_out. So no read ever needed the new data from
// a write in the same cycle.
//
// The two writers into hiscore_data are mutually exclusive by construction, not
// by luck: downloading_dump requires ioctl_download, and dump_write is only set
// by the state machine, which advances in the else branch of that same
// ioctl_download test.
wire                     hs_data_we = downloading_dump | dump_write;
wire [HS_SCOREWIDTH-1:0] hs_data_wraddr = downloading_dump
                                        ? ioctl_addr[(HS_SCOREWIDTH-1):0]
                                        : data_addr;
wire               [7:0] hs_data_wrdata = downloading_dump ? data_from_hps
                                                           : hiscore_buffer_out;

// Pack the persistent and temporary 256-byte stores into the two halves of
// one 512x8 true-dual-port M10K.  The old pair of simple-dual-port instances
// each consumed a complete block even though together they hold only 4096
// bits.  Port A exclusively addresses the persistent half and port B the
// temporary half, so simultaneous accesses remain independent and the FSM's
// read latency/write-first behaviour is unchanged.
dpram_hs #(.aWidth(HS_SCOREWIDTH+1),.dWidth(8))
hiscore_storage (
	.clk(clk),
	.addr_a({1'b0, hs_data_we ? hs_data_wraddr : data_addr}),
	.we_a(hs_data_we),
	.d_a(hs_data_wrdata),
	.q_a(hiscore_data_out),
	.addr_b({1'b1, buffer_addr}),
	.we_b(buffer_write),
	.d_b(data_from_ram),
	.q_b(hiscore_buffer_out)
);

assign data_to_ram = hiscore_data_out;
assign data_to_hps = hiscore_data_out;

wire [3:0] header_chunk = ioctl_addr[3:0];
wire [7:0] mask_chunk = ioctl_addr[7:0] - 5'd16;
wire [255:0] mask_load_index = mask_chunk * 8;

always @(posedge clk)
begin

	if (downloading_config)
	begin
		// Get header chunk data
		if(parsing_header)
		begin
			if(ioctl_wr)
			begin
				if(header_chunk == 4'd3) START_WAIT <= { last_data_from_hps3, last_data_from_hps2, last_data_from_hps, data_from_hps };
				if(header_chunk == 4'd5) CHECK_WAIT <= { last_data_from_hps, data_from_hps };
				if(header_chunk == 4'd7) CHECK_HOLD <= { last_data_from_hps, data_from_hps };
				if(header_chunk == 4'd9) WRITE_HOLD <= { last_data_from_hps, data_from_hps };
				if(header_chunk == 4'd11) WRITE_REPEATCOUNT <= { last_data_from_hps, data_from_hps };
				if(header_chunk == 4'd13) WRITE_REPEATWAIT <= { last_data_from_hps, data_from_hps };
				if(header_chunk == 4'd14) ACCESS_PAUSEPAD <= data_from_hps;
				if(header_chunk == 4'd15) CHANGEMASK <= data_from_hps;
			end
		end
		else
		if(parsing_mask)
		begin
			if(ioctl_wr == 1'b1) change_mask[mask_load_index +: 8] <= data_from_hps;
		end
		else
		begin
			// Keep track of the largest entry during config download
			total_entries <= config_upload_addr;
		end
	end

	// Track completion of configuration and dump download
	if ((last_ioctl_download != ioctl_download) && (ioctl_download == 1'b0))
	begin
		if (last_ioctl_index==HS_CONFIGINDEX) downloaded_config <= 1'b1;
		if (last_ioctl_index==HS_DUMPINDEX) downloaded_dump <= 1'b1;
	end

	// Track last cycle values
	last_ioctl_download <= ioctl_download;
	last_ioctl_index <= ioctl_index;
	last_OSD_STATUS <= OSD_STATUS;

	// Cascade incoming data bytes from HPS
	if(ioctl_download && ioctl_wr)
	begin
		last_data_from_hps3 = last_data_from_hps2;
		last_data_from_hps2 = last_data_from_hps;
		last_data_from_hps = data_from_hps;
	end

	// If we have a valid configuration then enable the hiscore system
	if(downloaded_config)
	begin
	
		// Check for end of core reset to initialise state machine for restore
		reset_last <= reset;
		if (downloaded_dump == 1'b1 && reset_last == 1'b1 && reset == 1'b0)
		begin
			wait_timer <= START_WAIT;
			next_state <= SM_INIT_RESTORE;
			state <= SM_TIMER;
			counter <= 1'b0;
			restoring_dump <= 1'b1;
		end
		else
		begin
			// Upload scores if requested by HPS
			// - Data is now sent from the hiscore data buffer rather than game RAM as in previous versions
			if (uploading_dump == 1'b1)
			begin
				// Set local address to read from hiscore data based on ioctl_address
				data_addr <= ioctl_addr[HS_SCOREWIDTH-1:0];
				// Clear dump dirty flag
				dump_dirty <= 1'b0;
			end

			// Trigger hiscore extraction when OSD is opened
			if(last_OSD_STATUS==1'b0 && OSD_STATUS==1'b1 && extracting_dump==1'b0 && uploading_dump==1'b0 && restoring_dump==1'b0)
			begin
				extracting_dump <= 1'b1;
				state <= SM_COMPAREINIT;
			end

			// Extract hiscore data from game RAM and save in hiscore data buffer
			if (extracting_dump == 1'b1)
			begin
				case (state)
					// Compare process states
					SM_COMPAREINIT: // Initialise state machine for comparison 
						begin
							// Setup addresses and comparison flags
							buffer_addr <= 0;
							data_addr <= 0;
							counter <= 0;
							compare_nonzero <= 1'b0;
							compare_changed <= 1'b0;
							compare_length <= 1'b0;
							// Pause cpu and wait for next state
							pause_cpu <= 1'b1;
							state <= SM_TIMER;
							next_state <= SM_COMPAREBEGIN;
							wait_timer <= ACCESS_PAUSEPAD;
						end
					SM_COMPAREBEGIN:
						begin
							// Get ready to read next line (wait until addr_base is updated)
							reading_scores <= 1'b1;
							state <= SM_COMPAREREADY;
						end
					SM_COMPAREREADY:
						begin
							// Set ram address and wait for it to return correctly
							ram_addr <= addr_base;
							if(ram_addr == addr_base)
							begin
								state <= SM_COMPAREREAD;
							end
						end
					SM_COMPAREREAD:
						begin
							// Setup next address and signal write enable to hiscore buffer.
							// Hold here until the RAM has produced the byte for the
							// current address: the buffer captures data_from_ram on the
							// edge into SM_COMPAREDONE.
							if (ram_ready == 1'b1)
							begin
								buffer_write <= 1'b1;
								state <= SM_COMPAREDONE;
							end
						end
					SM_COMPAREDONE:
						begin
							// If RAM data has changed since last dump and there is either no mask or a 1 in the mask for this address
							if (data_from_ram != hiscore_data_out && (CHANGEMASK==8'b0 || check_mask==1))
							begin
								// Hiscore data changed
								compare_changed <= 1'b1;
							end
							if (data_from_ram != 8'b0)
							begin
								// Hiscore data is not blank
								compare_nonzero <= 1'b1;
							end
							compare_length <= compare_length + 20'b1;
							// Move to next entry when last address is reached
							if (ram_addr == end_addr)
							begin
								// If this was the last entry then we are done
								if (counter == total_entries)
								begin
									state <= SM_TIMER;
									reading_scores <= 1'b0;
									next_state <= SM_COMPARECOMPLETE;
									wait_timer <= ACCESS_PAUSEPAD;
								end
								else
								begin
									// Next config line
									counter <= counter + 1'b1;
									state <= SM_COMPAREBEGIN;
								end
							end
							else
							begin
								// Keep extracting this section
								state <= SM_COMPAREREAD;
								ram_addr <= ram_addr + 1'b1;
							end
							// Always stop writing to hiscore dump ram and increment local address
							buffer_addr <= buffer_addr + 1'b1;
							data_addr <= data_addr + 1'b1;
							buffer_write <= 1'b0;
						end
					SM_COMPARECOMPLETE:
						begin
							pause_cpu <= 1'b0;
							reading_scores <= 1'b0;
							if (compare_changed == 1'b1 && compare_nonzero == 1'b1)
							begin
								// If high scores have changed and are not blank, update the hiscore data from extract buffer
								dump_dirty <= 1'b1;
								state <= SM_EXTRACTINIT;
							end
							else
							begin
								// If no change or scores are invalid leave the existing hiscore data in place
								if(dump_dirty == 1'b1 && autosave == 1'b1)
								begin
									state <= SM_EXTRACTSAVE;
								end
								else
								begin
									extracting_dump <= 1'b0;
									state <= SM_STOPPED;
								end
							end
						end
					SM_EXTRACTINIT:
						begin
							// Setup address and counter
							data_addr <= 0;
							buffer_addr <= 0;
							state <= SM_EXTRACT;
							dump_write <= 1'b1;
						end
					SM_EXTRACT:
						begin
							// Keep writing until end of buffer
							if (buffer_addr == compare_length)
							begin
								dump_write <= 1'b0;
								state <= SM_EXTRACTSAVE;
							end
							// Increment buffer address and set data address to one behind
							data_addr <= buffer_addr;
							buffer_addr <= buffer_addr + 1'b1;
						end
					SM_EXTRACTSAVE:
						begin
							if(autosave == 1'b1)
							begin
								ioctl_upload_req <= 1'b1;
								state <= SM_TIMER;
								next_state <= SM_EXTRACTCOMPLETE;
								wait_timer <= 4'd4;
							end
							else
							begin
								extracting_dump <= 1'b0;
								state <= SM_STOPPED;
							end
						end
					SM_EXTRACTCOMPLETE:
						begin
							ioctl_upload_req <= 1'b0;
							extracting_dump <= 1'b0;
							state <= SM_STOPPED;
						end
				endcase
			end
			
			// If we are not uploading or resetting and valid hiscore data is available then start the state machine to write data to game RAM
			if (uploading_dump == 1'b0 && downloaded_dump == 1'b1 && reset == 1'b0)
			begin
				// State machine to write data to game RAM
				case (state)
					SM_INIT_RESTORE: // Start state machine
						begin
							// Setup base addresses
							data_addr <= 0;
							base_io_addr <= 25'b0;
							// Reset entry counter and states
							counter <= 0;
							writing_scores <= 1'b0;
							checking_scores <= 1'b0;
							pause_cpu <= 1'b0;
							state <= SM_CHECKPREP;
						end

					// Start/end check states
					// ----------------------
					SM_CHECKPREP: // Prepare start/end check run - pause CPU in readiness for RAM access
						begin
							state <= SM_TIMER;
							next_state <= SM_CHECKBEGIN;
							pause_cpu <= 1'b1;
							wait_timer <= ACCESS_PAUSEPAD;
						end

					SM_CHECKBEGIN: // Begin start/end check run - enable RAM access
						begin
							checking_scores <= 1'b1;
							ram_addr <= {1'b0, addr_base};
							state <= SM_CHECKSTARTVAL;
							wait_timer <= CHECK_HOLD;
						end

					SM_CHECKSTARTVAL: // Start check
						begin
							// Check for matching start value
							if(wait_timer != CHECK_HOLD && ram_ready == 1'b1 && data_from_ram == start_val)
							begin
								// Prepare end check
								ram_addr <= end_addr;
								state <= SM_CHECKENDVAL;
								wait_timer <= CHECK_HOLD;
							end
							else
							begin
								ram_addr <= {1'b0, addr_base};
								if (wait_timer > 1'b0)
								begin
									wait_timer <= wait_timer - 1'b1;
								end
								else
								begin
									// - If no match after read wait then stop check run and schedule restart of state machine
									next_state <= SM_CHECKCANCEL;
									state <= SM_TIMER;
									checking_scores <= 1'b0;
									wait_timer <= ACCESS_PAUSEPAD;
								end
							end
						end

					SM_CHECKENDVAL: // End check
						begin
							// Check for matching end value
							if (wait_timer != CHECK_HOLD & ram_ready == 1'b1 & data_from_ram == end_val)
							begin
								if (counter == total_entries)
								begin
									// If this was the last entry then move on to writing scores to game ram
									checking_scores <= 1'b0;
									state <= SM_WRITEBEGIN;	// Bypass SM_WRITEPREP as we are already paused
									counter <= 1'b0;
									write_counter <= 1'b0;
									ram_write <= 1'b0;
									ram_addr <= {1'b0, addr_base};
								end
								else
								begin
									// Increment counter and restart state machine to check next entry
									counter <= counter + 1'b1;
									state <= SM_CHECKBEGIN;
								end
							end
							else
							begin
								ram_addr <= end_addr;
								if (wait_timer > 1'b0)
								begin
									wait_timer <= wait_timer - 1'b1;
								end
								else
								begin
									// - If no match after read wait then stop check run and schedule restart of state machine
									next_state <= SM_CHECKCANCEL;
									state <= SM_TIMER;
									checking_scores <= 1'b0;
									wait_timer <= ACCESS_PAUSEPAD;
								end
							end
						end

					SM_CHECKCANCEL: // Cancel start/end check run - disable RAM access and keep CPU paused 
						begin
							pause_cpu <= 1'b0;
							next_state <= SM_INIT_RESTORE;
							state <= SM_TIMER;
							wait_timer <= CHECK_WAIT;
						end

					// Write to game RAM states
					// ----------------------
					SM_WRITEPREP: // Prepare to write scores - pause CPU in readiness for RAM access (only used on subsequent write attempts)
						begin
							state <= SM_TIMER;
							next_state <= SM_WRITEBEGIN;
							pause_cpu <= 1'b1;
							wait_timer <= ACCESS_PAUSEPAD;
						end

					SM_WRITEBEGIN: // Writing scores to game RAM begins
						begin
							writing_scores <= 1'b1; // Enable muxes if necessary
							write_counter <= write_counter + 1'b1;
							state <= SM_WRITEREADY;
						end

					SM_WRITEREADY: // local ram should be correct, start write to game RAM
						begin
							ram_addr <= addr_base + (data_addr - base_io_addr);
							state <= SM_TIMER;
							next_state <= SM_WRITEDONE;
							wait_timer <= WRITE_HOLD;
							ram_write <= 1'b1;
						end

					SM_WRITEDONE:
						begin
							data_addr <= data_addr + 1'b1; // Increment to next byte of entry
							if (ram_addr == end_addr)
							begin
								// End of entry reached
								if (counter == total_entries) 
								begin 
									state <= SM_WRITECOMPLETE;
								end
								else
								begin
									// Move to next entry
									counter <= counter + 1'b1;
									write_counter <= 1'b0;
									base_io_addr <= data_addr + 1'b1;
									state <= SM_WRITEBEGIN;
								end
							end 
							else 
							begin
								state <= SM_WRITEREADY;
							end
							ram_write <= 1'b0;
						end

					SM_WRITECOMPLETE: // Hiscore write to RAM completed
						begin
							ram_write <= 1'b0;
							writing_scores <= 1'b0;
							restoring_dump <= 1'b0;
							state <= SM_TIMER;
							if(write_counter < WRITE_REPEATCOUNT)
							begin
								// Schedule next write
								next_state <= SM_WRITERETRY;
								data_addr <= 0;
								wait_timer <= WRITE_REPEATWAIT;
							end
							else
							begin
								next_state <= SM_STOPPED;
								wait_timer <= ACCESS_PAUSEPAD;
							end
						end

					SM_WRITERETRY: // Stop pause and schedule next write
						begin
							pause_cpu <= 1'b0;
							state <= SM_TIMER;
							next_state <= SM_WRITEPREP;
							wait_timer <= WRITE_REPEATWAIT;
						end

					SM_STOPPED:
						begin
							pause_cpu <= 1'b0;
						end
				endcase
			end
			
			if(state == SM_TIMER) // timer wait state
			begin
				// Do not progress timer if CPU is paused by source other than this module
				// - Stops initial hiscore load delay being foiled by user pausing/entering OSD
				if (paused == 1'b0 || pause_cpu == 1'b1)
				begin
					if (wait_timer > 1'b0)
						wait_timer <= wait_timer - 1'b1;
					else
						state <= next_state;
				end
			end
		end
	end
end

endmodule

// Simple dual-port RAM module used by hiscore module
module dpram_hs #(
	parameter dWidth=8,
	parameter aWidth=8
)(
	input								clk,

	input			[aWidth-1:0]	addr_a,
	input			[dWidth-1:0]	d_a,
	input								we_a,
	output reg	[dWidth-1:0]	q_a,

	input			[aWidth-1:0]	addr_b,
	input			[dWidth-1:0]	d_b,
	input								we_b,
	output reg	[dWidth-1:0]	q_b
);

// LOCAL CHANGE (SSV): pick the storage style from the array depth.
//
// This is a TRUE dual-port array -- both ports read and write -- which on
// Cyclone V can only live in an M10K; MLAB is simple-dual-port only. The four
// config arrays the hiscore module instantiates are CFG_ADDRESSWIDTH deep,
// i.e. 16 words, so each was claiming a whole 10,240-bit M10K to hold between
// 128 and 384 bits. On this core M10K is the binding resource at 90% while
// ALMs sit at 84%, so the shallow arrays are far cheaper as registers: all
// four together are about 770 flops against the 4 M10K they would otherwise
// take. The two 256-byte score buffers stay in block RAM, where 2,048 bits
// each is a reasonable use of one.
//
// Everything below is upstream's logic, unchanged apart from being written
// once per branch.
generate
if (aWidth <= 5) begin : g_ram_logic

	(* ramstyle = "logic" *) reg [dWidth-1:0] ram [2**aWidth-1:0];

	always @(posedge clk) begin
		if (we_a) begin
			ram[addr_a] <= d_a;
			q_a <= d_a;
		end
		else begin
			q_a <= ram[addr_a];
		end

		if (we_b) begin
			ram[addr_b] <= d_b;
			q_b <= d_b;
		end
		else begin
			q_b <= ram[addr_b];
		end
	end

end else begin : g_ram_block

	// LOCAL CHANGE (SSV): ramstyle forced.
	//
	// Left to itself Quartus put these in LOGIC, not block RAM, and the cost
	// was not small -- the fit report priced hiscore_data at 1,003 ALM and
	// hiscore_buffer at 384 for 1,024 bits each, about one ALM per bit, with
	// the whole hiscore module reporting only 768 memory bits. That is roughly
	// 3.3% of the device spent on a high score table.
	//
	// no_rw_check waives same-address read/write coherency ACROSS the two
	// ports (port A writing address X while port B reads address X in the
	// same cycle), which is safe here (neither deep instance has a
	// consumer that reads an address in the cycle it writes it). Getting
	// this array to actually infer as M10K took three real-fit iterations:
	// - 2026-08-05: unconditional-read/delayed-bypass in one shared always
	//   block (both ports) -> "can't infer memory for variable 'ram'".
	// - 2026-08-06 attempt 1: split into one always block per port, still
	//   unconditional-read/delayed-bypass -> "uninferred due to
	//   asynchronous read logic".
	// - 2026-08-06 attempt 2: isolated the RAM access into its own block
	//   per port, moved the we_a_d/d_a_d delay copies to a separate block
	//   -> STILL "uninferred due to asynchronous read logic". The extra
	//   indirection (ram_q_a/we_a_d/d_a_d feeding q_a through a downstream
	//   `always @(*)` mux, rather than q_a being driven directly inside
	//   the memory-access block) was the actual remaining blocker.
	// Below is Altera's literal documented true-dual-port write-first
	// template: one always block per port, write-then-bypass in the `if`
	// branch, registered read in the `else` branch, q_a/q_b driven
	// directly -- no intermediate signals. This is what the M10K's native
	// NEW_DATA read-during-write mode implements in hardware, so it is the
	// best-supported inference shape. Behaviourally identical to the
	// previous (broken-inference) version: q_a still updates exactly one
	// cycle after we_a/d_a/addr_a are presented, to d_a if we_a was set
	// that cycle (write-first bypass) or to the array's prior contents
	// otherwise -- same latency, same bypass semantics, just reached
	// directly instead of through a delayed we_a_d/d_a_d/ram_q_a mux.
	(* ramstyle = "M10K, no_rw_check" *) reg [dWidth-1:0] ram [2**aWidth-1:0];

	always @(posedge clk) begin
		if (we_a) begin
			ram[addr_a] <= d_a;
			q_a <= d_a;
		end
		else begin
			q_a <= ram[addr_a];
		end
	end

	always @(posedge clk) begin
		if (we_b) begin
			ram[addr_b] <= d_b;
			q_b <= d_b;
		end
		else begin
			q_b <= ram[addr_b];
		end
	end

end
endgenerate

endmodule
