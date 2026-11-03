// SPDX-License-Identifier: GPL-3.0-or-later
// Bridge held renderer requests to the CPU bus's synchronous video RAM ports
// and a held request/reply graphics-ROM service. Addresses are byte offsets.
module spinal_video_mem_adapter (
    input  logic clk, reset,
    input  logic request,
    input  logic [3:0] space,
    input  logic [21:0] address,
    output wire ready,
    output wire [63:0] data,
    output logic [10:0] vram_address,
    output logic [9:0] sprite_address,
    output logic [7:0] row_address,
    input  logic [15:0] vram0, vram1, row,
    input  logic [63:0] sprite_block,
    input  logic video_write_commit,
    input  logic [23:0] video_write_address,
    output wire rom_request,
    output logic [3:0] rom_space,
    output logic [21:0] rom_address,
    input  logic rom_ready,
    input  logic [63:0] rom_data
);
    typedef enum logic [2:0] {IDLE, RAM_REPLY, ROM_ARM, ROM_WAIT, DRAIN} state_t;
    state_t state = IDLE;
    logic [3:0] held_space;
    logic [21:0] held_address;
    wire [21:0] read_address=state==IDLE && request ? address : held_address;
    wire [15:0] local_word = held_space==0 ? vram0 : held_space==1 ? vram1 : row;
    wire ram_collision=video_write_commit && (
        (space==0 && video_write_address>=24'h080000 && video_write_address<24'h081000 && video_write_address[11:1]==address[11:1]) ||
        (space==1 && video_write_address>=24'h082000 && video_write_address<24'h083000 && video_write_address[11:1]==address[11:1]) ||
        (space==2 && video_write_address>=24'hffc000 && video_write_address<24'hffc800 && video_write_address[10:3]==address[10:3]) ||
        (space==3 && video_write_address>=24'hffd000 && video_write_address<24'hffd200 && video_write_address[8:1]==address[8:1])
    );
    assign vram_address=read_address[11:1];
    assign sprite_address=read_address[10:1];
    assign row_address=read_address[8:1];
    assign rom_request=state==ROM_WAIT;
    assign ready=state==RAM_REPLY || (state==ROM_WAIT && rom_ready);
    assign data=state==RAM_REPLY ? (held_space==2 ? sprite_block : {48'd0,local_word}) : rom_data;

    // Reset blocks new admissions. An already accepted request completes even
    // during reset so its producer can drain it; the ROM tuple stays fixed.
    always_ff @(posedge clk) begin
        case(state)
        // Wait until a same-word CPU write commits before issuing an on-chip
        // read. No mixed-port read-during-write value is assumed.
        IDLE: if(!reset && request && (space>=4 || !ram_collision)) begin
            held_space<=space;held_address<=address;
            if(space<4) begin
                state<=RAM_REPLY;
            end else begin
                rom_space<=space;rom_address<=address;state<=rom_ready ? ROM_ARM : ROM_WAIT;
            end
        end
        RAM_REPLY: state<=DRAIN;
        ROM_ARM: if(!rom_ready) state<=ROM_WAIT;
        ROM_WAIT: if(rom_ready) state<=DRAIN;
        DRAIN: if(!request) state<=IDLE;
        default: state<=IDLE;
        endcase
    end
endmodule
