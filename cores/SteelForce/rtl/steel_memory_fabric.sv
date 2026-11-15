// Single-clock board ROM fabric: three cached read clients and real IOCTL storage.
module steel_memory_fabric(
    input wire clk,reset,mortalr,
    input wire ioctl_download,ioctl_wr,
    input wire [15:0] ioctl_index,
    input wire [24:0] ioctl_addr,
    input wire [7:0] ioctl_din,
    output wire ioctl_wait,image_valid,image_mortalr,download_active,error,
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
    output wire [31:0] cpu_hits,cpu_misses,gfx_hits,gfx_misses,oki_hits,oki_misses,
    output wire [12:0] sdram_address,
    output wire [1:0] sdram_bank,sdram_dqm,
    output wire sdram_cs_n,sdram_ras_n,sdram_cas_n,sdram_we_n,sdram_drive,
    output wire [15:0] sdram_data_out,
    input wire [15:0] sdram_data_in
);
    wire read_request,read_ready,read_ack;
    wire [24:0] read_address;
    wire [63:0] read_data;
    steel_rom_storage storage(.clk(clk),.reset(reset),.mortalr(mortalr),
        .ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_din(ioctl_din),.ioctl_wait(ioctl_wait),
        .image_valid(image_valid),.image_mortalr(image_mortalr),
        .download_active(download_active),.error(error),.read_request(read_request),
        .read_address(read_address),.read_accepted(),.read_acknowledged(read_ack),
        .read_data(read_data),.read_ready(read_ready),
        .sdram_address(sdram_address),.sdram_bank(sdram_bank),.sdram_dqm(sdram_dqm),
        .sdram_cs_n(sdram_cs_n),.sdram_ras_n(sdram_ras_n),.sdram_cas_n(sdram_cas_n),
        .sdram_we_n(sdram_we_n),.sdram_drive(sdram_drive),
        .sdram_data_out(sdram_data_out),.sdram_data_in(sdram_data_in));
    steel_rom_clients clients(.clk(clk),.reset(reset),.invalidate(!image_valid || download_active),
        .cpu_request(cpu_request),.cpu_word_address(cpu_word_address),
        .cpu_ready(cpu_ready),.cpu_data(cpu_data),.gfx_request(gfx_request),
        .gfx_address(gfx_address),.gfx_ready(gfx_ready),.gfx_data(gfx_data),
        .oki_address(oki_address),.oki_ready(oki_ready),.oki_data(oki_data),
        .memory_request(read_request),.memory_address(read_address),
        .memory_ready(read_ready),.memory_acknowledged(read_ack),.memory_data(read_data),
        .cpu_hits(cpu_hits),.cpu_misses(cpu_misses),.gfx_hits(gfx_hits),.gfx_misses(gfx_misses),
        .oki_hits(oki_hits),.oki_misses(oki_misses));
endmodule
