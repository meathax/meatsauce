// Program/GFX/OKI views of the shared immutable ROM image.
// Program words are 68000 big endian; packed GFX rows remain low-byte first.
module steel_rom_clients(
    input wire clk,reset,invalidate,
    input wire cpu_request,
    input wire [18:0] cpu_word_address,
    output wire cpu_ready,
    output wire [15:0] cpu_data,
    input wire gfx_request,
    input wire [22:0] gfx_address,
    output wire gfx_ready,
    output wire [63:0] gfx_data,
    input wire [17:0] oki_address,
    output wire oki_ready,
    output wire [7:0] oki_data,
    output wire memory_request,
    output wire [24:0] memory_address,
    input wire memory_ready,memory_acknowledged,
    input wire [63:0] memory_data,
    output wire [31:0] cpu_hits,cpu_misses,gfx_hits,gfx_misses,oki_hits,oki_misses
);
    wire [2:0] requests,acknowledged;
    wire [24:0] addresses[0:2];
    wire [63:0] fill_data,cpu_line,gfx_line,oki_line;
    wire [24:0] cpu_byte_address={5'b0,cpu_word_address,1'b0};
    wire [24:0] sample_address=25'h600000+{7'b0,oki_address};
    wire [15:0] cpu_word=cpu_line >> {cpu_word_address[1:0],4'b0};
    assign cpu_data={cpu_word[7:0],cpu_word[15:8]};
    // Text rows use four bytes, so their upper/lower half can share one line.
    assign gfx_data=gfx_line >> {gfx_address[2:0],3'b0};
    assign oki_data=oki_line >> {oki_address[2:0],3'b0};
    steel_rom_cache #(.SET_BITS(9),.WAY_BITS(2)) cpu_cache(
        .clk(clk),.reset(reset),.invalidate(invalidate),.request(cpu_request),
        .address(cpu_byte_address),.ready(cpu_ready),.data(cpu_line),
        .memory_request(requests[0]),.memory_address(addresses[0]),
        .memory_acknowledged(acknowledged[0]),.memory_data(fill_data),
        .hits(cpu_hits),.misses(cpu_misses));
    steel_rom_cache #(.SET_BITS(9),.WAY_BITS(2)) gfx_cache(
        .clk(clk),.reset(reset),.invalidate(invalidate),.request(gfx_request),
        .address({2'b0,gfx_address}),.ready(gfx_ready),.data(gfx_line),
        .memory_request(requests[1]),.memory_address(addresses[1]),
        .memory_acknowledged(acknowledged[1]),.memory_data(fill_data),
        .hits(gfx_hits),.misses(gfx_misses));
    steel_rom_cache #(.SET_BITS(6),.WAY_BITS(1)) sample_cache(
        .clk(clk),.reset(reset),.invalidate(invalidate),.request(1'b1),
        .address(sample_address),.ready(oki_ready),.data(oki_line),
        .memory_request(requests[2]),.memory_address(addresses[2]),
        .memory_acknowledged(acknowledged[2]),.memory_data(fill_data),
        .hits(oki_hits),.misses(oki_misses));
    steel_rom_arbiter arbiter(.clk(clk),.reset(reset || invalidate),
        .request(requests),.address0(addresses[0]),.address1(addresses[1]),.address2(addresses[2]),
        .acknowledged(acknowledged),.data(fill_data),.memory_request(memory_request),
        .memory_address(memory_address),.memory_ready(memory_ready),
        .memory_acknowledged(memory_acknowledged),.memory_data(memory_data));
endmodule
