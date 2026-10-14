// Shared SemiCom sound-board Z80 bus and memory map.
// Sound chips and sample-bank address remapping remain at the board owner.
module tumble_semicom_z80 #(
    parameter YM_ENABLE = 1,
    parameter CPU_4M = 0
)(
    input             clk,
    input             rst,
    input             enable,
    input      [ 7:0] command,
    input      [ 7:0] rom_data,
    input             rom_ok,
    input      [ 7:0] ym_data,
    input             ym_irq_n,
    input      [ 7:0] oki_data,
    output reg [15:0] rom_addr,
    output            rom_cs,
    output reg [ 7:0] ym_din,
    output            ym_cs_n,
    output            ym_rd_n,
    output            ym_wr_n,
    output            ym_a0,
    output reg [ 7:0] oki_din,
    output            oki_wr_n,
    output reg [ 7:0] sample_bank
);

wire [1:0] z80_cen_bus;
wire cen_cpu;
wire [15:0] z80_addr;
wire [7:0] z80_dout;
reg [7:0] z80_din;
wire z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
wire z80_rfsh_n, z80_halt_n, z80_busak_n;
wire z80_rom_read = enable && !z80_mreq_n && !z80_rd_n && z80_addr <= 16'hcfff;
wire z80_ram_read = enable && !z80_mreq_n && !z80_rd_n &&
                    z80_addr >= 16'hd000 && z80_addr <= 16'hd7ff;
wire ym_select = enable && YM_ENABLE && !z80_mreq_n && z80_addr >= 16'hf000 && z80_addr <= 16'hf001;
wire oki_select = enable && !z80_mreq_n && z80_addr == 16'hf002;
wire latch_select = enable && !z80_mreq_n && z80_addr == 16'hf008;
wire bank_select = enable && !z80_mreq_n && z80_addr == 16'hf00e;
wire z80_wait_n = !z80_rom_read || rom_ok;
wire z80_mem_write = enable && !z80_mreq_n && !z80_wr_n;
wire z80_ram_write = z80_mem_write && z80_addr >= 16'hd000 && z80_addr <= 16'hd7ff;
wire z80_oki_write = oki_select && !z80_wr_n;

// Power-up contents are zero, matching MAME; soft reset preserves RAM.
reg [7:0] sound_ram [0:2047];

jtframe_frac_cen #(.W(2),.WC(7)) u_z80_cen(
    .clk  ( clk       ),
    .n    ( CPU_4M ? 7'd1 : 7'd5 ),
    .m    ( CPU_4M ? 7'd12 : 7'd64 ),
    .cen  ( z80_cen_bus ),
    .cenb (           )
);
assign cen_cpu = z80_cen_bus[0];

T80s #(.Mode(0),.T2Write(1),.IOWait(1)) u_z80(
    .RESET_n ( ~(rst || !enable) ),
    .CLK     ( clk       ),
    .CEN     ( cen_cpu   ),
    .WAIT_n  ( z80_wait_n),
    .INT_n   ( YM_ENABLE ? ym_irq_n : 1'b1 ),
    .NMI_n   ( 1'b1      ),
    .BUSRQ_n ( 1'b1      ),
    .M1_n    ( z80_m1_n  ),
    .MREQ_n  ( z80_mreq_n),
    .IORQ_n  ( z80_iorq_n),
    .RD_n    ( z80_rd_n  ),
    .WR_n    ( z80_wr_n  ),
    .RFSH_n  ( z80_rfsh_n),
    .HALT_n  ( z80_halt_n),
    .BUSAK_n ( z80_busak_n),
    .OUT0    ( 1'b1      ),
    .A       ( z80_addr  ),
    .DI      ( z80_din   ),
    .DO      ( z80_dout  )
);

always @* begin
    rom_addr = z80_addr;
    ym_din = z80_dout;
    oki_din = z80_dout;
end

assign rom_cs = z80_rom_read;
assign ym_cs_n = !ym_select;
assign ym_rd_n = z80_rd_n;
assign ym_wr_n = z80_wr_n;
assign ym_a0 = z80_addr[0];
assign oki_wr_n = !z80_oki_write;
wire sample_bank_wr = bank_select && !z80_wr_n;

// Registered block-RAM read: the T80 samples DI at a later clock enable.
reg [7:0] sound_ram_q;
always @(posedge clk) begin
    if (z80_ram_write) sound_ram[z80_addr[10:0]] <= z80_dout;
    sound_ram_q <= sound_ram[z80_addr[10:0]];
end

always @* begin
    case (1'b1)
        z80_rom_read: z80_din = rom_data;
        z80_ram_read: z80_din = sound_ram_q;
        ym_select:    z80_din = ym_data;
        oki_select:   z80_din = oki_data;
        latch_select: z80_din = command;
        default:      z80_din = 8'hff;
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        sample_bank <= 8'd0;
    end else begin
        if (sample_bank_wr) sample_bank <= z80_dout;
    end
end

endmodule

// Jump Kids has its own Z80 map and an interrupting main-CPU sound latch.
// It reuses the T80 core while exposing the external OKI bank copy separately.
module tumble_jumpkids_z80(
    input             clk,
    input             rst,
    input             enable,
    input             irq,
    input      [ 7:0] command,
    input      [ 7:0] rom_data,
    input             rom_ok,
    input      [ 7:0] oki_data,
    output reg [15:0] rom_addr,
    output            rom_cs,
    output reg [ 7:0] oki_din,
    output            oki_wr_n,
    output            irq_ack,
    output reg [ 7:0] sample_bank
);

wire [1:0] z80_cen_bus;
wire [15:0] z80_addr;
wire [7:0] z80_dout;
reg [7:0] z80_din;
wire z80_m1_n, z80_mreq_n, z80_iorq_n, z80_rd_n, z80_wr_n;
wire z80_rfsh_n, z80_halt_n, z80_busak_n;
wire z80_rom_read = enable && !z80_mreq_n && !z80_rd_n && z80_addr <= 16'h0fff;
wire z80_ram_read = enable && !z80_mreq_n && !z80_rd_n &&
                    z80_addr >= 16'h8000 && z80_addr <= 16'h87ff;
wire oki_select = enable && !z80_mreq_n && z80_addr == 16'h9800;
wire latch_select = enable && !z80_mreq_n && z80_addr == 16'ha000;
wire bank_select = enable && !z80_mreq_n && z80_addr == 16'h9000;
wire z80_wait_n = !z80_rom_read || rom_ok;
wire z80_mem_write = enable && !z80_mreq_n && !z80_wr_n;
wire z80_ram_write = z80_mem_write && z80_addr >= 16'h8000 && z80_addr <= 16'h87ff;
wire sample_bank_wr = bank_select && !z80_wr_n;
// Power-up contents are zero, matching MAME; soft reset preserves RAM.
reg [7:0] sound_ram [0:2047];

jtframe_frac_cen #(.W(2),.WC(7)) u_z80_cen(
    .clk  ( clk          ),
    .n    ( 7'd1         ),
    .m    ( 7'd12        ),
    .cen  ( z80_cen_bus ),
    .cenb (              )
);

T80s #(.Mode(0),.T2Write(1),.IOWait(1)) u_z80(
    .RESET_n ( ~(rst || !enable) ),
    .CLK     ( clk                ),
    .CEN     ( z80_cen_bus[0]     ),
    .WAIT_n  ( z80_wait_n         ),
    .INT_n   ( ~irq               ),
    .NMI_n   ( 1'b1               ),
    .BUSRQ_n ( 1'b1               ),
    .M1_n    ( z80_m1_n           ),
    .MREQ_n  ( z80_mreq_n         ),
    .IORQ_n  ( z80_iorq_n         ),
    .RD_n    ( z80_rd_n           ),
    .WR_n    ( z80_wr_n           ),
    .RFSH_n  ( z80_rfsh_n         ),
    .HALT_n  ( z80_halt_n         ),
    .BUSAK_n ( z80_busak_n        ),
    .OUT0    ( 1'b1               ),
    .A       ( z80_addr           ),
    .DI      ( z80_din            ),
    .DO      ( z80_dout           )
);

always @* begin
    rom_addr = z80_addr;
    oki_din = z80_dout;
end

assign rom_cs = z80_rom_read;
assign oki_wr_n = !(oki_select && !z80_wr_n);
// One acknowledgement event per bus cycle. The T80 holds IORQ/M1 low
// across clock enables; clearing on that level would discard a new command
// arriving before the current acknowledgement cycle finishes.
wire irq_ack_cycle = enable && !z80_iorq_n && !z80_m1_n;
reg irq_ack_cycle_d;
always @(posedge clk) begin
    if (rst || !enable) irq_ack_cycle_d <= 1'b0;
    else irq_ack_cycle_d <= irq_ack_cycle;
end
assign irq_ack = irq_ack_cycle && !irq_ack_cycle_d;

// Registered block-RAM read: the T80 samples DI at a later clock enable.
reg [7:0] sound_ram_q;
always @(posedge clk) begin
    if (z80_ram_write) sound_ram[z80_addr[10:0]] <= z80_dout;
    sound_ram_q <= sound_ram[z80_addr[10:0]];
end

always @* begin
    case (1'b1)
        z80_rom_read: z80_din = rom_data;
        z80_ram_read: z80_din = sound_ram_q;
        oki_select:   z80_din = oki_data;
        latch_select: z80_din = command;
        default:      z80_din = 8'hff;
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        sample_bank <= 8'd0;
    end else begin
        if (sample_bank_wr) sample_bank <= z80_dout;
    end
end

endmodule
