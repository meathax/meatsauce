
`default_nettype none

module rom_controller 
(
    // reset
    input reset,

    // clock
    input clk,

    // program ROM interface
    input  prog_rom_cs,
    input  prog_rom_oe,
    input  [22:0] prog_rom_addr, // word address.
    output [15:0] prog_rom_data,
    output prog_rom_data_valid,

//    // program ROM 2 interface
    input  prog_rom_2_cs,
    input  prog_rom_2_oe,
    input  [22:0] prog_rom_2_addr, // word address.
    output [15:0] prog_rom_2_data,
    output prog_rom_2_data_valid,

    // sprite ROM #1 interface
    input sprite_rom_cs,
    input sprite_rom_oe,
    input  [19:0] sprite_rom_addr,
    output [31:0] sprite_rom_data,
    output sprite_rom_data_valid,    
    
    // sound ROM #1 interface
    input sound_rom_cs,
    input sound_rom_oe,
    input  [18:0] sound_rom_addr,
    output [7:0] sound_rom_data,
    output sound_rom_data_valid,        

    // IOCTL interface
    input [24:0] ioctl_addr,
    input [7:0] ioctl_data,
    input [15:0] ioctl_index,
    input ioctl_wr,
    input ioctl_download,
    output ioctl_wait,
    output download_busy,

    // SDRAM interface
    output reg [22:0] sdram_addr,
    output reg [31:0] sdram_data,
    output reg sdram_we,
    output reg sdram_req,
    input  sdram_ack,
    input  sdram_valid,
    input  [31:0] sdram_q
  );

localparam NONE         = 0; 
localparam PROG_ROM     = 1;
localparam PROG_ROM_2   = 2;
localparam SPRITE_ROM   = 3;
localparam SOUND_ROM    = 4;
  
// ROM wires
reg [2:0] rom;
reg [2:0] next_rom;
reg [2:0] pending_rom;

// ROM request wires
reg prog_rom_ctrl_req;
reg prog_rom_2_ctrl_req;
reg sprite_rom_ctrl_req;
reg sound_rom_ctrl_req;

// ROM acknowledge wires
reg prog_rom_ctrl_ack;
reg prog_rom_2_ctrl_ack;
reg sprite_rom_ctrl_ack;
reg sound_rom_ctrl_ack;

reg prog_rom_ctrl_hit;
reg prog_rom_2_ctrl_hit;
reg sprite_rom_ctrl_hit;
reg sound_rom_ctrl_hit;

// ROM valid wires
reg prog_rom_ctrl_valid;
reg prog_rom_2_ctrl_valid;
reg sprite_rom_ctrl_valid;
reg sound_rom_ctrl_valid;

// address mux wires
reg [22:0] prog_rom_ctrl_addr;
reg [22:0] prog_rom_2_ctrl_addr;
reg [22:0] sprite_rom_ctrl_addr;
reg [22:0] sound_rom_ctrl_addr;

// Completed download words retain their address/data until the SDRAM ACK.
// Four descriptors leave twelve bytes of skid capacity after backpressure.
reg [22:0] download_addresses [0:3];
reg [31:0] download_words [0:3];
reg [1:0] download_rd = 0, download_wr = 0;
reg [2:0] download_count = 0;
reg [1:0] download_byte = 0;
reg [23:0] download_shift = 0;
reg [22:0] download_partial_addr = 0;
reg download_last_active = 0, download_drain = 0, download_error = 0;
reg download_selected = 0, fence_selected = 0;
localparam FENCE_IDLE=0, FENCE_REQUEST=1, FENCE_REPLY=2;
reg [1:0] fence_state = FENCE_IDLE;
wire download_active = ioctl_download && ioctl_index == 0;
wire download_req = download_count != 0;
wire [22:0] download_addr = download_addresses[download_rd];
wire [31:0] download_data = download_words[download_rd];
wire download_pop = sdram_ack && download_selected && download_req;
wire download_word = download_active && ioctl_wr && !download_error &&
                     download_byte == 3 && ioctl_addr[1:0] == 3 &&
                     ioctl_addr[24:2] == download_partial_addr;
wire download_push = download_word && (download_count < 4 || download_pop);
// Queued words and errors imply DRAIN: it starts before assembly completes
// and ends only on the final fence reply. Avoid feeding FIFO count through
// the global mode/address mux when that registered lifecycle already owns it.
wire download_mode = download_active || download_drain;
wire fence_req = !download_active && !download_req && !download_error && fence_state == FENCE_REQUEST;
assign ioctl_wait = download_active && (download_req || download_error);
// The immediate mode gates memory admission/publication. Keep the game reset
// on its registered lifecycle flag, avoiding a high-fanout combinational mux.
// Admission is already blocked for the one SYS edge before this flag asserts.
assign download_busy = download_drain;

// control wires
reg ctrl_req;

// The loader is independent of the game reset: download_busy holds that reset
// until a read fence proves the final accepted write has physically completed.
// Resetting this queue from the game reset would deadlock the download.
always @(posedge clk) begin
    download_last_active <= download_active;
    // ACK belongs to the mux selection on the preceding acceptance edge.
    // A late higher-priority request must not retire another client's word.
    download_selected <= download_mode && download_req;
    fence_selected <= download_mode && fence_req;
    if (download_active && !download_last_active) begin
        download_byte <= 0;
        download_error <= 0;
        download_drain <= 1;
        fence_state <= FENCE_IDLE;
    end
    if (download_active && ioctl_wr) begin
        if (ioctl_addr[1:0] != download_byte ||
            (download_byte != 0 && ioctl_addr[24:2] != download_partial_addr))
            download_error <= 1;
        download_shift <= {download_shift[15:0], ioctl_data};
        download_byte <= download_byte + 1'b1;
        if (download_byte == 0) download_partial_addr <= ioctl_addr[24:2];
        if (download_word && !download_push) download_error <= 1;
    end
    if (download_push) begin
        download_addresses[download_wr] <= download_partial_addr;
        download_words[download_wr] <= {download_shift, ioctl_data};
        download_wr <= download_wr + 1'b1;
    end
    if (download_pop) download_rd <= download_rd + 1'b1;
    case ({download_push, download_pop})
        2'b10: download_count <= download_count + 1'b1;
        2'b01: download_count <= download_count - 1'b1;
        default: begin end
    endcase
    if (!download_active && download_last_active) begin
        if (download_byte != 0) download_error <= 1;
        fence_state <= FENCE_REQUEST;
    end
    if (!download_active && fence_state == FENCE_REQUEST && sdram_ack && fence_selected)
        fence_state <= FENCE_REPLY;
    if (!download_active && fence_state == FENCE_REPLY && sdram_valid) begin
        fence_state <= FENCE_IDLE;
        download_drain <= 0;
    end
end

segment 
#(
    .ROM_ADDR_WIDTH(18), // 0x40000 x 16 words = 512k
    .ROM_DATA_WIDTH(16),
    .ROM_OFFSET(24'h000000)
) prog_rom_segment 
(
    .reset(reset),
    .clk(clk),
    .cs(prog_rom_cs),
    .oe(prog_rom_oe),
    .ctrl_addr(prog_rom_ctrl_addr),
    .ctrl_req(prog_rom_ctrl_req),
    .ctrl_ack(prog_rom_ctrl_ack),
    .ctrl_valid(prog_rom_ctrl_valid),
    .ctrl_hit(prog_rom_ctrl_hit),
    .ctrl_data(sdram_q),
    .rom_addr(prog_rom_addr),
    .rom_data(prog_rom_data)
);

segment 
#(
    .ROM_ADDR_WIDTH(18), 
    .ROM_DATA_WIDTH(16),
    .ROM_OFFSET(24'h040000)
) prog_rom_2_segment 
(
    .reset(reset),
    .clk(clk),
    .cs(prog_rom_2_cs),
    .oe(prog_rom_2_oe),
    .ctrl_addr(prog_rom_2_ctrl_addr),
    .ctrl_req(prog_rom_2_ctrl_req),
    .ctrl_ack(prog_rom_2_ctrl_ack),
    .ctrl_valid(prog_rom_2_ctrl_valid),
    .ctrl_hit(prog_rom_2_ctrl_hit),
    .ctrl_data(sdram_q),
    .rom_addr(prog_rom_2_addr),
    .rom_data(prog_rom_2_data)
);

segment 
#(
    .ROM_ADDR_WIDTH(19),  // 0x80000 x 8 words = 256k // audio z80
    .ROM_DATA_WIDTH(8),
    .ROM_OFFSET(24'h80000)
) sound_rom_segment
(
    .reset(reset),
    .clk(clk),
    .cs(sound_rom_cs),
    .oe(sound_rom_oe),
    .ctrl_addr(sound_rom_ctrl_addr),
    .ctrl_req(sound_rom_ctrl_req),
    .ctrl_ack(sound_rom_ctrl_ack),
    .ctrl_valid(sound_rom_ctrl_valid),
    .ctrl_hit(sound_rom_ctrl_hit),
    .ctrl_data(sdram_q),
    .rom_addr(sound_rom_addr),
    .rom_data(sound_rom_data)
);

segment 
#(
    .ROM_ADDR_WIDTH(20), // 0x100000 x 32 words - 4MB
    .ROM_DATA_WIDTH(32),
    .ROM_OFFSET(24'h200000),
    .REGISTER_REQUEST(1)
) sprite_rom_segment
(
    .reset(reset),
    .clk(clk),
    .cs(sprite_rom_cs),
    .oe(sprite_rom_oe),
    .ctrl_addr(sprite_rom_ctrl_addr),
    .ctrl_req(sprite_rom_ctrl_req),
    .ctrl_ack(sprite_rom_ctrl_ack),
    .ctrl_valid(sprite_rom_ctrl_valid),
    .ctrl_hit(sprite_rom_ctrl_hit),
    .ctrl_data(sdram_q),
    .rom_addr(sprite_rom_addr),
    .rom_data(sprite_rom_data)
);

// latch the next ROM
always @ (posedge clk, posedge reset) begin
    if ( reset == 1 ) begin
        rom <= NONE;
        pending_rom <= NONE;
    end else begin
        // default to not having any ROM selected
        rom <= NONE;

        // set the current ROM register when ROM data is not being downloaded
        if ( download_mode == 0 ) begin
            rom <= next_rom;
        end;

        // set the pending ROM register when a request is acknowledged (i.e.
        // a new request has been started)
        if ( sdram_ack == 1 ) begin
            pending_rom <= rom;
        end

        sdram_valid_reg <= sdram_valid;
    end
end

reg sdram_valid_reg;

   
// select cpu data input based on what is active
assign prog_rom_data_valid    = prog_rom_cs   & ( prog_rom_ctrl_hit   | (pending_rom == PROG_ROM   ? sdram_valid : 0) ) & ~reset & ~download_mode;
assign prog_rom_2_data_valid  = prog_rom_2_cs & ( prog_rom_2_ctrl_hit | (pending_rom == PROG_ROM_2 ? sdram_valid : 0) ) & ~reset & ~download_mode;
assign sprite_rom_data_valid  = sprite_rom_cs & ( sprite_rom_ctrl_hit | (pending_rom == SPRITE_ROM ? sdram_valid : 0) ) & ~reset & ~download_mode;
assign sound_rom_data_valid   = sound_rom_cs  & ( sound_rom_ctrl_hit  | (pending_rom == SOUND_ROM  ? sdram_valid : 0) ) & ~reset & ~download_mode;

always @ (*) begin

    // mux the next ROM in priority order

    next_rom <= NONE;  // default
    case (1)
        sprite_rom_ctrl_req:    next_rom <= SPRITE_ROM;
        sound_rom_ctrl_req:     next_rom <= SOUND_ROM;
        prog_rom_ctrl_req:      next_rom <= PROG_ROM;
        prog_rom_2_ctrl_req:    next_rom <= PROG_ROM_2;
    endcase

    // route SDRAM acknowledge wire to the current ROM
    prog_rom_ctrl_ack <= 0;
    prog_rom_2_ctrl_ack <= 0;
    sprite_rom_ctrl_ack <= 0;
    sound_rom_ctrl_ack <= 0;

    case (rom)
        PROG_ROM:       prog_rom_ctrl_ack <= sdram_ack;
        PROG_ROM_2:     prog_rom_2_ctrl_ack <= sdram_ack;
        SPRITE_ROM:     sprite_rom_ctrl_ack <= sdram_ack;
        SOUND_ROM:      sound_rom_ctrl_ack <= sdram_ack;
    endcase

    
    // route SDRAM valid wire to the pending ROM
    prog_rom_ctrl_valid   <= 0;
    prog_rom_2_ctrl_valid <= 0;
    sprite_rom_ctrl_valid <= 0;
    sound_rom_ctrl_valid  <= 0;

    case (pending_rom)
        PROG_ROM:       prog_rom_ctrl_valid   <= sdram_valid;
        PROG_ROM_2:     prog_rom_2_ctrl_valid <= sdram_valid;
        SPRITE_ROM:     sprite_rom_ctrl_valid <= sdram_valid;
        SOUND_ROM:      sound_rom_ctrl_valid  <= sdram_valid;
    endcase


    // mux ROM request
    ctrl_req <= prog_rom_ctrl_req |
                prog_rom_2_ctrl_req |
                sound_rom_ctrl_req |
                sprite_rom_ctrl_req ;

     // mux SDRAM address in priority order
     sdram_addr <= 0;
     case (1)
        download_mode:          sdram_addr <= download_req ? download_addr : 23'b0;
        sprite_rom_ctrl_req:    sdram_addr <= sprite_rom_ctrl_addr;
        sound_rom_ctrl_req:     sdram_addr <= sound_rom_ctrl_addr;
        prog_rom_ctrl_req:      sdram_addr <= prog_rom_ctrl_addr;
        prog_rom_2_ctrl_req:    sdram_addr <= prog_rom_2_ctrl_addr;
     endcase 
     
    // set SDRAM data input
    sdram_data <= download_data;
    // sdram_data <= download_addr;  poor man's testbench

    // set SDRAM request
    sdram_req <= download_mode ? (download_req || fence_req) : ctrl_req;

    // enable writing to the SDRAM when downloading ROM data
    sdram_we <= download_mode && download_req;
end

endmodule 
