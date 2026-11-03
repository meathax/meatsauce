// DEC8 byte-bus adapter around unchanged Jotego BAC06 candidate RTL.
// Register semantics: pinned MAME 0.289 decbac06.h, big-endian accessors.
module d8_bac06 #(
    parameter SIMFILE = "bac06_init.bin",
    parameter bit REVERSED_TILE_LAYOUT = 1'b0
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         i_ce12,
    input  wire         i_ce6,
    input  wire         i_mode_we,
    input  wire         i_scroll_we,
    input  wire [3:0]   i_reg_addr,
    input  wire [7:0]   i_data,
    output logic [7:0]  o_scroll_data,
    output logic        o_flip,
    input  wire         i_flip,       // driver policy; mode bit 7 alone does not select this
    input  wire         i_rev,        // with REVERSED_TILE_LAYOUT: 1 = tiles_r (Ghostbusters), 0 = dec0 'tiles'
    input  wire [8:0]   i_vdump,
    input  wire [8:0]   i_vrender,
    input  wire [8:0]   i_hdump,
    input  wire         i_lhbl,
    input  wire         i_lvbl,
    input  wire         i_hs,
    input  wire         i_vs,
    input  wire         i_vload,
    input  wire         i_hinit,
    output wire         o_ram_cs,
    output wire [13:1]  o_ram_addr,
    input  wire [15:0]  i_ram_data,
    input  wire         i_ram_ok,
    output wire         o_rom_cs,
    output wire [17:1]  o_rom_addr,
    input  wire [31:0]  i_rom_data,
    input  wire         i_rom_ok,
    output wire [7:0]   o_pixel,
    input  wire [7:0]   i_status_addr,
    output wire [7:0]   o_status_data
);
    logic [15:0] scroll [0:3];
    wire [1:0] index = i_reg_addr[2:1];
    // First two scroll registers are 16-bit; later byte pairs mirror low.
    wire high_lane = !i_reg_addr[0] && i_reg_addr < 4;
    wire [1:0] dsn = i_mode_we ? 2'b10 : high_lane ? 2'b01 : 2'b10;
    wire [12:1] address = {8'd0, i_scroll_we, 1'b0, index};
    wire [15:0] unused_cpu_data;
    always_comb o_scroll_data = i_reg_addr[0] ? scroll[index][7:0] : scroll[index][15:8];
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            o_flip <= 1'b0;
            for (int i=0; i<4; i++) scroll[i] <= '0;
        end else begin
            if (i_mode_we && index == 0) o_flip <= i_data[7];
            if (i_scroll_we) begin
                if (high_lane) scroll[index][15:8] <= i_data;
                else scroll[index][7:0] <= i_data;
            end
        end
    end
    // DEC8 planar word is {P0,P1,P2,P3}; COP expects {P2,P3,P0,P1}.
    wire [31:0] rotated = {i_rom_data[15:0],i_rom_data[31:16]};
    wire [31:0] planes;
    wire [17:1] raw_rom_addr;
    // Ghostbusters tiles_r has LSB-first pixels and the opposite half order.
    // Cobra-Command uses dec0's own 'tiles' layout (i_rev low).
    wire rev = REVERSED_TILE_LAYOUT && i_rev;
    assign o_rom_addr = rev ?
                       {raw_rom_addr[17:6],~raw_rom_addr[5],raw_rom_addr[4:1]} : raw_rom_addr;
    genvar byte_index, bit_index;
    generate
    for (byte_index=0; byte_index<4; byte_index=byte_index+1) begin : g_planes
        for (bit_index=0; bit_index<8; bit_index=bit_index+1) begin : g_bits
            assign planes[byte_index*8+bit_index] = rev ?
                rotated[byte_index*8+7-bit_index] : rotated[byte_index*8+bit_index];
        end
    end
    endgenerate
    // MASTER=0 consumes these shared pins. Keep inout nets local so the
    // donor's port directions cannot turn this wrapper's inputs into drivers.
    // COP's donor uses 256-coordinate mirroring for both the render row and
    // line-buffer write address. DEC8's visible 0..255 image needs 255-x/y.
    // Advancing the donor's flipped input coordinates by one supplies that
    // endpoint without changing the immutable vendor logic or normal scan.
    wire [8:0] vdump=i_vdump;
    wire [8:0] vrender=i_vrender + {8'd0,i_flip};
    wire [8:0] hdump=i_hdump + {8'd0,i_flip};
    wire lhbl=i_lhbl, lvbl=i_lvbl, hs=i_hs, vs=i_vs;
    wire vload=i_vload, hinit=i_hinit, flip=i_flip;
    jtcop_bac06 #(.MASTER(0), .SIMFILE(SIMFILE)) u_bac06 (
        .rst(!rst_n), .clk, .clk_cpu(clk), .pxl2_cen(i_ce12), .pxl_cen(i_ce6),
        .mode_cs(i_mode_we || i_scroll_we), .flip(flip),
        .cpu_dout({i_data,i_data}), .cpu_din(unused_cpu_data),
        .cpu_addr(address), .cpu_rnw(!(i_mode_we || i_scroll_we)), .cpu_dsn(dsn),
        .vdump(vdump), .vrender(vrender), .hdump(hdump),
        .LHBL(lhbl), .LVBL(lvbl), .HS(hs), .VS(vs),
        .vload(vload), .hinit(hinit),
        .ram_cs(o_ram_cs), .ram_addr(o_ram_addr), .ram_data(i_ram_data), .ram_ok(i_ram_ok),
        .rom_cs(o_rom_cs), .rom_addr(raw_rom_addr), .rom_data(planes), .rom_ok(i_rom_ok),
        .pxl(o_pixel), .st_addr(i_status_addr), .st_dout(o_status_data)
    );
endmodule
