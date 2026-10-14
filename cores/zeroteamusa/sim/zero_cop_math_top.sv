// Focused real COP replay of observed US distance operands; no boot/game claim.
module zero_cop_math_top(
    input wire clk,reset,cs,wr,rd,
    input wire [9:0] address,
    input wire [15:0] write_data,
    output wire [15:0] read_data,
    input wire [15:0] source_data,ram_read_data,
    output wire [23:0] source_address,
    output wire [15:0] ram_address,ram_write_data,
    output wire [1:0] ram_be,
    output wire ram_write,busy,stall,
    output wire [31:0] debug_dx,debug_dy,
    output wire [23:0] cop_rom_address,
    output wire [23:0] cop_rom_logical,
    input wire rom_bank,
    output wire cop_rom_request,
    input wire [15:0] cop_rom_data,
    input wire cop_rom_ready,
    output wire debug_axis3,
    output wire [31:0] debug_hb2
);
    ssbus_if ss_a(),ss_r();
`define IDLE(s) assign s.data=0;assign s.addr=0;assign s.select=0;assign s.write=0;assign s.read=0;assign s.query=0;
    `IDLE(ss_a) `IDLE(ss_r)
`undef IDLE
    Raiden2_cop3 cop(
        .clk(clk),.reset(reset),.cs(cs),.wr(wr),.rd(rd),.addr(address),.dsn(2'b00),.wdata(write_data),.rdata(read_data),
        .dma_ram_addr(ram_address),.dma_ram_wdata(ram_write_data),.dma_ram_rdata(ram_read_data),
        .dma_ram_we(ram_write),.dma_ram_be(ram_be),.dma_src_byte(source_address),.dma_src_rdata(source_data),
        .cop_rom_addr(cop_rom_logical),.cop_rom_req(cop_rom_request),
        .cop_rom_rdata(cop_rom_data),.cop_rom_ready(cop_rom_ready),.dma_busy(busy),.cpu_stall(stall),.ss_arr(ss_a),.ss_reg(ss_r)
    );
    raiden2_addr_main cop_map(
        .A(cop_rom_logical[19:0]),.DBEN(1'b1),.rom_bank(rom_bank),
        .board_dx(1'b0),.dx_prg_bank(4'd0),.sdr_addr(cop_rom_address)
    );
    assign debug_dx=cop.latch_dx;
    assign debug_dy=cop.latch_dy;
    assign debug_axis3=cop.hb_axis3;
    assign debug_hb2={cop.hb_size[2],cop.hb_dx[2]};
endmodule
