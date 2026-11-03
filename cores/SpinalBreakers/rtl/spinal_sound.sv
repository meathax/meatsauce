// SPDX-License-Identifier: GPL-3.0-or-later
// T80/JT10 sound subsystem. All enables and memory service share clk.
// Program requests remain asserted through the CPU read; ready/data must remain
// valid until request drops. ADPCM service must meet the JT10 read deadline.
module spinal_sound (
    input logic clk,reset,cpu_ce,ym_ce,bus_request,
    input logic command_write,input logic [7:0] command_data,
    output wire program_request,output wire [3:0] program_region,
    output wire [21:0] program_offset,input logic program_ready,input logic [7:0] program_data,
    output wire [19:0] adpcma_address,output wire [4:0] adpcma_bank,output wire adpcma_roe_n,
    input logic [7:0] adpcma_data,
    output wire signed [15:0] sound_l,sound_r,output wire sample,output wire cpu_bus_idle,bus_ack
);
    wire signed [15:0] ym_left,ym_right;
    assign sound_l=reset ? 16'sd0 : ym_left;
    assign sound_r=reset ? 16'sd0 : ym_right;
    wire [15:0] address;
    wire [16:0] rom_address;
    wire rom_banked,m1_n,mreq_n,iorq_n,rd_n,wr_n,rfsh_n;
    wire nmi_n,int_n,ym_cs_n,ym_irq_n,halt_n,busak_n;
    wire [7:0] cpu_out,io_data,ym_data;
    wire [1:0] bank;
    assign cpu_bus_idle=mreq_n && iorq_n;
    assign bus_ack=!busak_n;
    logic [7:0] ram[0:2047];
    logic [7:0] ram_data;
    wire ram_selected=address>=16'h7800 && address<16'h8000;
    assign program_request=!mreq_n && !rd_n && !ram_selected;
    assign program_region=rom_banked ? 4'd1 : 4'd2;
    assign program_offset={5'b0,rom_address};
    wire [7:0] cpu_in=!iorq_n ? io_data : (ram_selected ? ram_data : program_data);
    always_ff @(posedge clk) begin
        ram_data<=ram[address[10:0]];
        if(!reset && !mreq_n && !wr_n && ram_selected)ram[address[10:0]]<=cpu_out;
    end
    spinal_sound_control control(.clk(clk),.reset(reset),.command_write(command_write),.command_data(command_data),
        .z80_address(address),.z80_data_out(cpu_out),.iorq_n(iorq_n),.m1_n(m1_n),.rd_n(rd_n),.wr_n(wr_n),
        .ym_data(ym_data),.ym_irq_n(ym_irq_n),.io_data(io_data),.ym_cs_n(ym_cs_n),.nmi_n(nmi_n),.int_n(int_n),
        .bank(bank),.rom_banked(rom_banked),.rom_address(rom_address));
    wire recovered_cpu_ce;
    wire [15:0] sound_cpu_debt;
    wire sound_cpu_debt_overflow;
    spinal_sound_cpu_recovery sound_recovery(.clk(clk),.reset(reset),
        .freeze(bus_request && bus_ack),.nominal(cpu_ce),
        .blocked(program_request && !program_ready),.ce(recovered_cpu_ce),
        .debt(sound_cpu_debt),.overflow(sound_cpu_debt_overflow));
    T80s cpu(.RESET_n(!reset),.CLK(clk),.CEN(recovered_cpu_ce),.WAIT_n(!program_request || program_ready),
        .INT_n(int_n),.NMI_n(nmi_n),.BUSRQ_n(!bus_request),.OUT0(1'b0),.DI(cpu_in),
        .M1_n(m1_n),.MREQ_n(mreq_n),.IORQ_n(iorq_n),.RD_n(rd_n),.WR_n(wr_n),.RFSH_n(rfsh_n),
        .HALT_n(halt_n),.BUSAK_n(busak_n),.A(address),.DOUT(cpu_out));
    jt10 ym(.rst(reset),.clk(clk),.cen(ym_ce),.din(cpu_out),.addr(address[1:0]),
        .cs_n(ym_cs_n),.wr_n(wr_n),.dout(ym_data),.irq_n(ym_irq_n),
        .adpcma_addr(adpcma_address),.adpcma_bank(adpcma_bank),.adpcma_roe_n(adpcma_roe_n),
        .adpcma_data(adpcma_data),.adpcmb_addr(),.adpcmb_roe_n(),.adpcmb_data(8'hff),
        .psg_A(),.psg_B(),.psg_C(),.fm_left(),.fm_right(),.psg_snd(),
        .snd_left(ym_left),.snd_right(ym_right),.snd_sample(sample),.ch_enable(6'h3f));
endmodule
