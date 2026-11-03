// SPDX-License-Identifier: GPL-3.0-or-later
`timescale 1ns/1ns
module hangzo_tile_video #(
    parameter TILE0="", TILE1="", TILE2="", TILE3="",
    parameter ROWS0="", ROWS1="",
    parameter [8:0] H_LAST=9'd447,
    parameter [5:0] COLUMN_LAST=6'd41
)(
    input wire clk, reset, pixel_ce, hs, flip,
    input wire [8:0] hpos, vpos,
    input wire select, write,
    input wire [3:0] region,
    input wire [11:0] offset,
    input wire [15:0] write_data,
    input wire [1:0] byte_enable,
    output wire ready,
    output reg [15:0] read_data,
    output wire [31:0] layers,
    output wire [3:0] tile16,
    output wire [3:0] layer_enable,
    output wire board_flip,
    output wire [3:0] rom_request,
    output wire [18:0] rom_address0, rom_address1, rom_address2, rom_address3,
    input wire [31:0] rom_data0, rom_data1, rom_data2, rom_data3,
    input wire [3:0] rom_ready
);
    wire [15:0] bank0, bank1, q0, q1, q2, q3, rs0, rs1;
    wire [1:0] we = byte_enable & {2{select && write}};
    reg [1:0] age;
    always @(posedge clk) begin
        if (reset || !select) age <= 0;
        else if (age != 3) age <= age + 2'd1;
    end
    assign ready = select && age >= 2;
    always @* begin
        case (region)
            3: read_data=q0; 4: read_data=q1; 5: read_data=q2; 6: read_data=q3;
            7,8: read_data=rs0; 9,10: read_data=rs1;
            default: read_data=16'hffff;
        endcase
    end
    hangzo_deco16ic #(.SIMFILE1(TILE0),.SIMFILE2(TILE1),.SIMFILRS(ROWS0),.MMRSEEK(0),
        .H_LAST(H_LAST),.COLUMN_LAST(COLUMN_LAST)) u_tile0(
        .rst(reset),.clk(clk),.pxl_cen(pixel_ce),.hs(hs),.hdump(hpos),.vdump(vpos),.flip(flip ^ board_flip),
        .pf1_fullheight(1'b1),.pf2_fullheight(1'b0),.cpu_addr(offset),.cpu_dout(write_data),
        .pf1_we(region==3 ? we : 2'd0),.pf2_we(region==4 ? we : 2'd0),
        .ctrl_addr(offset[2:0]),.ctrl_cs(select && region==1),.cpu_rnw(!write),.cpu_dsn(~byte_enable),
        .pf1_dout(q0),.pf2_dout(q1),.bank_ctl(bank0),.pf1_tile16(tile16[0]),.pf2_tile16(tile16[1]),
        .layer_enable(layer_enable[1:0]),.board_flip(board_flip),
        .pf1_pswap(1'b0),.pf2_pswap(1'b0),.pf1_rowmajor(1'b0),.pf2_rowmajor(1'b0),
        .pf1_bank({1'b0,bank0[5:4]}),.pf2_bank({1'b0,bank0[13:12]}),
        .rs_split(1'b1),.rs_addr({region==8,offset}),.rs_we((region==7 || region==8) ? we : 2'd0),.rs_dout(rs0),
        .pf1_pxl(layers[7:0]),.pf2_pxl(layers[15:8]),
        .pf1_romcs(rom_request[0]),.pf1_roma(rom_address0),.pf1_romdata(rom_data0),.pf1_romok(rom_ready[0]),
        .pf2_romcs(rom_request[1]),.pf2_roma(rom_address1),.pf2_romdata(rom_data1),.pf2_romok(rom_ready[1]),
        .ioctl_addr(4'd0),.ioctl_din(),.debug_bus(8'd0),.st_dout()
    );
    hangzo_deco16ic #(.SIMFILE1(TILE2),.SIMFILE2(TILE3),.SIMFILRS(ROWS1),.MMRSEEK(16),
        .H_LAST(H_LAST),.COLUMN_LAST(COLUMN_LAST)) u_tile1(
        .rst(reset),.clk(clk),.pxl_cen(pixel_ce),.hs(hs),.hdump(hpos),.vdump(vpos),.flip(flip ^ board_flip),
        .pf1_fullheight(1'b0),.pf2_fullheight(1'b0),.cpu_addr(offset),.cpu_dout(write_data),
        .pf1_we(region==5 ? we : 2'd0),.pf2_we(region==6 ? we : 2'd0),
        .ctrl_addr(offset[2:0]),.ctrl_cs(select && region==2),.cpu_rnw(!write),.cpu_dsn(~byte_enable),
        .pf1_dout(q2),.pf2_dout(q3),.bank_ctl(bank1),.pf1_tile16(tile16[2]),.pf2_tile16(tile16[3]),
        .layer_enable(layer_enable[3:2]),.board_flip(),
        .pf1_pswap(1'b0),.pf2_pswap(1'b0),.pf1_rowmajor(1'b0),.pf2_rowmajor(1'b0),
        .pf1_bank({1'b0,bank1[5:4]}),.pf2_bank({1'b0,bank1[13:12]}),
        .rs_split(1'b1),.rs_addr({region==10,offset}),.rs_we((region==9 || region==10) ? we : 2'd0),.rs_dout(rs1),
        .pf1_pxl(layers[23:16]),.pf2_pxl(layers[31:24]),
        .pf1_romcs(rom_request[2]),.pf1_roma(rom_address2),.pf1_romdata(rom_data2),.pf1_romok(rom_ready[2]),
        .pf2_romcs(rom_request[3]),.pf2_roma(rom_address3),.pf2_romdata(rom_data3),.pf2_romok(rom_ready[3]),
        .ioctl_addr(4'd0),.ioctl_din(),.debug_bus(8'd0),.st_dout()
    );
endmodule
