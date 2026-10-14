// Real target V30/COP and production ROM bridge, with external SDRAM stimulus.
module zero_platform_boot (
    input wire clk,reset,pause,
    input wire [15:0] main_data,cop_data,
    input wire main_ack,cop_ack,
    output wire [23:0] main_address,cop_address,
    output wire main_req,cop_req,
    output wire cpu_write,irq_ack,cop_busy,
    output wire [19:0] cpu_address,
    input wire [10:0] probe,
    output wire [15:0] text_data,palette_data,
    output wire vblank
);
    wire cpu_rom_request,cop_rom_request,cpu_rom_ack,cop_rom_valid;
    wire [23:0] cpu_rom_address,cop_rom_address;
    wire [15:0] cpu_rom_data,cop_rom_data;
    Raiden2_video_timing timing(.clk(clk),.reset(reset),.mode_60hz(1'b0),.vblank(vblank));
    ZeroTeam_rom_bridge roms (
        .clk(clk),.reset(reset),.ready(1'b1),.download(1'b0),.word_wr(1'b0),
        .word_address(27'd0),.word_data(16'd0),.gfx_req(1'b0),.gfx_address(24'd0),.gfx_kind(3'd0),
        .main_req(cpu_rom_request),.main_address(cpu_rom_address),.main_data(cpu_rom_data),.main_valid(cpu_rom_ack),
        .cop_req(cop_rom_request),.cop_address(cop_rom_address),.cop_data(cop_rom_data),.cop_valid(cop_rom_valid),
        .oki_address(18'd0),.addr1(main_address),.addr2(cop_address),.req1(main_req),.req2(cop_req),
        .ack0(1'b0),.ack1(main_ack),.ack2(cop_ack),.ack3(1'b0),
        .dout0(16'd0),.dout1(main_data),.dout2(cop_data),.dout3(16'd0)
    );
    zero_board_top target (
        .clk(clk),.reset(reset),.vblank(vblank),.pause(pause),
        .p1(8'hff),.p2(8'hff),.p3(8'hff),.p4(8'hff),.dips(16'hffff),.system_input(16'hffff),
        .rom_data(cpu_rom_data),.rom_ack(cpu_rom_ack),.rom_request(cpu_rom_request),.rom_address(cpu_rom_address),
        .cop_rom_data(cop_rom_data),.cop_rom_ack(cop_rom_valid),.cop_rom_request(cop_rom_request),.cop_rom_address(cop_rom_address),
        .cpu_address(cpu_address),.cpu_write(cpu_write),.irq_ack(irq_ack),.cop_busy(cop_busy),
        .video_probe_address(probe),.ram_probe_address(16'd0),.text_data(text_data),.palette_data(palette_data)
    );
endmodule
