// SPDX-License-Identifier: GPL-3.0-or-later
// Bandit's Intel 8751 interface, matching MAME's dec0_8751_state callbacks.
module bandit_mcu #(
    parameter integer SYS_HZ=60000000
)(
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic        run_enable,
    input  logic        command_we,
    input  logic        command_reset,
    input  logic [15:0] command_data,
    input  logic        rom_load_we,
    input  logic [11:0] rom_load_addr,
    input  logic [7:0]  rom_load_data,
    output wire         irq5,
    output wire         mcu_cen,
    output logic [15:0] response
);
    localparam integer MCU_NUM=SYS_HZ==60000000 ? 2 : 1;
    localparam integer MCU_DEN=SYS_HZ==60000000 ? 15 : 6;

    wire osc_ce;
    madmotor_frac_ce #(.NUM(MCU_NUM),.DEN(MCU_DEN)) mcu_clock(
        .clk(clk),.reset(reset),.ce(osc_ce));
    wire cen=osc_ce && run_enable && !pause && !clear_active;
    wire core_reset=reset || !run_enable;
    wire rst=core_reset;

    logic [15:0] command;
    logic [7:0] port0_latch,port2_latch;
    logic int1n;
    logic [7:0] rom_data,ram_q;
    logic [15:0] rom_addr;
    wire [15:0] pre_rom;
    wire [6:0] ram_addr;
    wire [7:0] ram_data;
    wire ram_we;
    wire [7:0] x_dout;
    wire [15:0] x_addr;
    wire x_wr,x_acc;
    wire sfr_wr;
    wire [7:0] sfr_wa,sfr_wd;
    logic [7:0] ram [0:127];
    logic [7:0] code_rom [0:4095];
    logic [6:0] clear_addr;
    logic clear_active;

    wire [7:0] p0_input = (port2_latch[4] ? 8'hff : command[15:8]) &
                          (port2_latch[5] ? 8'hff : command[7:0]);
    wire irq5_write=sfr_wr && (sfr_wa==8'ha0) && port2_latch[2] && !sfr_wd[2];

    assign irq5=irq5_write;
    assign mcu_cen=cen;

    // The code ROM is loaded by the same byte stream as the other Bandit ROMs.
    // Its synchronous read and the 128-byte RAM schedule match jtframe_8751mcu.
    always_ff @(posedge clk) begin
        if(rom_load_we) code_rom[rom_load_addr]<=rom_load_data;
        if(cen) rom_data<=code_rom[rom_addr[11:0]];
        rom_addr<=pre_rom;
    end

    always_ff @(posedge clk) begin
        if(core_reset) begin
            clear_active<=1'b1;
            clear_addr<=7'd0;
            ram_q<=8'd0;
        end else if(clear_active) begin
            ram[clear_addr]<=8'd0;
            if(&clear_addr) clear_active<=1'b0;
            else clear_addr<=clear_addr+1'b1;
        end else if(cen) begin
            ram_q<=ram[ram_addr];
            if(ram_we) ram[ram_addr]<=ram_data;
        end
    end

    always_ff @(posedge clk) begin
        if(rst) begin
            command<=16'd0;
            response<=16'd0;
            port0_latch<=8'hff;
            port2_latch<=8'hff;
            int1n<=1'b1;
        end else begin
            if(command_reset) begin
                command<=16'd0;
                response<=16'd0;
            end
            if(command_we) begin
                command<=command_data;
                if(port2_latch[3]) int1n<=1'b0;
            end
            if(sfr_wr) begin
                case(sfr_wa)
                    8'h80: port0_latch<=sfr_wd;
                    8'ha0: begin
                        if(sfr_wd[3]==1'b0) int1n<=1'b1;
                        if(sfr_wd[6] && !port2_latch[6])
                            response[7:0]<=port0_latch;
                        if(sfr_wd[7] && !port2_latch[7])
                            response[15:8]<=port0_latch;
                        port2_latch<=sfr_wd;
                    end
                    default: begin end
                endcase
            end
        end
    end

    jt8051 u_mcu(
        .rst(rst),.clk(clk),.cen(cen),
        .int0n(1'b1),.int1n(int1n),
        .p0_i(p0_input),.p1_i(8'hff),.p2_i(8'hff),.p3_i(8'hff),
        .p0_o(),.p1_o(),.p2_o(),.p3_o(),
        .rom_data(rom_data),.rom_addr(pre_rom),
        .ram_din(ram_q),.ram_dout(ram_data),.ram_addr(ram_addr),.ram_we(ram_we),
        .x_din(8'hff),.x_dout(x_dout),.x_addr(x_addr),.x_wr(x_wr),.x_acc(x_acc),
        .sfr_wr(sfr_wr),.sfr_wa(sfr_wa),.sfr_wd(sfr_wd),.p0_force(8'h00));

`ifdef VERILATOR
    always_comb begin
        if(!rst && x_acc) $fatal(1,"Bandit 8751 unexpectedly used MOVX");
    end
`endif
endmodule
