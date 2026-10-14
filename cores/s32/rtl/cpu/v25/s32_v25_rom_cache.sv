// SPDX-License-Identifier: GPL-3.0-or-later
//
// Small read-only cache for the NEC V25's external 64 KiB program image.
// A miss fetches one aligned 8-byte line from the System 32 SDRAM p5 port;
// subsequent instruction/operand words in that line complete without another
// SDRAM transaction.

`default_nettype none

module s32_v25_rom_cache (
    input  wire        clk,
    input  wire        rst,
    input  wire        invalidate,

    input  wire        cpu_req,
    input  wire [15:1] cpu_addr,
    output reg  [15:0] cpu_data,
    output reg         cpu_ack,

    output reg         rom_req,
    output reg  [15:3] rom_addr,
    input  wire [63:0] rom_data,
    input  wire        rom_ack
);

// 32 direct-mapped lines x 8 bytes = 256 bytes. Address bits [2:1] select a
// little-endian word, [7:3] select the line, and [15:8] form its tag.
reg [63:0] line_data [0:31];
reg  [7:0] line_tag  [0:31];
reg [31:0] line_valid;

reg        miss_pending;
reg        miss_discard;
reg  [4:0] miss_index;
reg  [7:0] miss_tag;
reg  [1:0] miss_word;
reg        queued_req;
reg [15:1] queued_addr;

wire [15:1] lookup_addr  = queued_req ? queued_addr : cpu_addr;
wire [4:0] lookup_index = lookup_addr[7:3];
wire [7:0] lookup_tag   = lookup_addr[15:8];
wire       lookup_hit   = line_valid[lookup_index] &&
                          line_tag[lookup_index] == lookup_tag;

function automatic [15:0] select_word(
    input [63:0] line,
    input  [1:0] word_sel
);
begin
    case (word_sel)
        2'd0: select_word = line[15:0];
        2'd1: select_word = line[31:16];
        2'd2: select_word = line[47:32];
        default: select_word = line[63:48];
    endcase
end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cpu_data     <= 16'hffff;
        cpu_ack      <= 1'b0;
        rom_req      <= 1'b0;
        rom_addr     <= 13'd0;
        line_valid   <= 32'd0;
        miss_pending <= 1'b0;
        miss_discard <= 1'b0;
        miss_index   <= 5'd0;
        miss_tag     <= 8'd0;
        miss_word    <= 2'd0;
        queued_req   <= 1'b0;
        queued_addr  <= 15'd0;
    end else begin
        cpu_ack <= 1'b0;
        rom_req <= 1'b0;

        // Program download changes bytes behind the cache. An already-issued
        // SDRAM request cannot be cancelled, so drain and discard that response
        // before launching a queued retry from the CPU arbiter.
        if (invalidate) begin
            line_valid <= 32'd0;
            queued_req <= 1'b0;
            if (rom_ack && miss_pending) begin
                miss_pending <= 1'b0;
                miss_discard <= 1'b0;
            end else if (miss_pending) begin
                miss_discard <= 1'b1;
            end else begin
                miss_discard <= 1'b0;
            end
        end else begin
            if (cpu_req && miss_pending) begin
                queued_req  <= 1'b1;
                queued_addr <= cpu_addr;
            end

            if (rom_ack && miss_pending) begin
                miss_pending <= 1'b0;
                if (miss_discard) begin
                    miss_discard <= 1'b0;
                end else begin
                    line_data[miss_index]  <= rom_data;
                    line_tag[miss_index]   <= miss_tag;
                    line_valid[miss_index] <= 1'b1;
                    cpu_data               <= select_word(rom_data, miss_word);
                    cpu_ack                <= 1'b1;
                end
            end else if (!miss_pending && (queued_req || cpu_req)) begin
                queued_req <= 1'b0;
                if (lookup_hit) begin
                    cpu_data <= select_word(
                        line_data[lookup_index], lookup_addr[2:1]
                    );
                    cpu_ack <= 1'b1;
                end else begin
                    miss_index   <= lookup_index;
                    miss_tag     <= lookup_tag;
                    miss_word    <= lookup_addr[2:1];
                    miss_pending <= 1'b1;
                    rom_addr     <= lookup_addr[15:3];
                    rom_req      <= 1'b1;
                end
            end
        end
    end
end

endmodule

// Golden Axe has a dedicated RBF, so its V25 program fetch path can favour
// area over a general-purpose working set. V25 instruction fetches are
// strongly sequential and SDRAM already returns an aligned 8-byte line. A
// single retained line serves the common four-word sequence while avoiding
// the 32-line variable-index array that Quartus 17 maps into ALMs/registers.
module s32_v25_rom_line_buffer (
    input  wire        clk,
    input  wire        rst,
    input  wire        invalidate,
    input  wire        cpu_req,
    input  wire [15:1] cpu_addr,
    output reg  [15:0] cpu_data,
    output reg         cpu_ack,
    output reg         rom_req,
    output reg  [15:3] rom_addr,
    input  wire [63:0] rom_data,
    input  wire        rom_ack
);

reg [63:0] line_data;
reg [12:0] line_tag;
reg        line_valid;
reg        miss_pending;
reg        miss_discard;
reg [12:0] miss_tag;
reg  [1:0] miss_word;
reg        queued_req;
reg [15:1] queued_addr;

wire [15:1] lookup_addr = queued_req ? queued_addr : cpu_addr;
wire [12:0] lookup_tag  = lookup_addr[15:3];
wire        lookup_hit  = line_valid && line_tag == lookup_tag;

function automatic [15:0] select_word(
    input [63:0] line,
    input  [1:0] word_sel
);
begin
    case (word_sel)
        2'd0: select_word = line[15:0];
        2'd1: select_word = line[31:16];
        2'd2: select_word = line[47:32];
        default: select_word = line[63:48];
    endcase
end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        cpu_data     <= 16'hffff;
        cpu_ack      <= 1'b0;
        rom_req      <= 1'b0;
        rom_addr     <= 13'd0;
        line_data    <= 64'd0;
        line_tag     <= 13'd0;
        line_valid   <= 1'b0;
        miss_pending <= 1'b0;
        miss_discard <= 1'b0;
        miss_tag     <= 13'd0;
        miss_word    <= 2'd0;
        queued_req   <= 1'b0;
        queued_addr  <= 15'd0;
    end else begin
        cpu_ack <= 1'b0;
        rom_req <= 1'b0;

        if (invalidate) begin
            line_valid <= 1'b0;
            queued_req <= 1'b0;
            if (rom_ack && miss_pending) begin
                miss_pending <= 1'b0;
                miss_discard <= 1'b0;
            end else if (miss_pending) begin
                miss_discard <= 1'b1;
            end else begin
                miss_discard <= 1'b0;
            end
        end else begin
            if (cpu_req && miss_pending) begin
                queued_req  <= 1'b1;
                queued_addr <= cpu_addr;
            end

            if (rom_ack && miss_pending) begin
                miss_pending <= 1'b0;
                if (miss_discard) begin
                    miss_discard <= 1'b0;
                end else begin
                    line_data  <= rom_data;
                    line_tag   <= miss_tag;
                    line_valid <= 1'b1;
                    cpu_data   <= select_word(rom_data, miss_word);
                    cpu_ack    <= 1'b1;
                end
            end else if (!miss_pending && (queued_req || cpu_req)) begin
                queued_req <= 1'b0;
                if (lookup_hit) begin
                    cpu_data <= select_word(line_data, lookup_addr[2:1]);
                    cpu_ack  <= 1'b1;
                end else begin
                    miss_tag     <= lookup_tag;
                    miss_word    <= lookup_addr[2:1];
                    miss_pending <= 1'b1;
                    rom_addr     <= lookup_addr[15:3];
                    rom_req      <= 1'b1;
                end
            end
        end
    end
end

endmodule

`default_nettype wire
