// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from Violent Storm jtviostorm_k056832.sv; MAME 0.289 is the
// register, byte-lane and raw ROM readback reference. The same register
// ports feed the line renderer. tile_addr[22:2] addresses aligned RAW
// 32-bit words in the unchanged 5 MiB k056832 region. tile_data is little
// endian by byte address. Raw readback never uses a decoded render copy.
module gaiapolis_k056832 (
    input wire monster,
    input clk,rst,
    input reg_cs,b_cs,vram_cs,romrd_cs,cpu_we,cpu_rnw,
    input [4:0] reg_addr,
    input [1:0] b_addr,
    input [12:1] vram_cpu_addr,
    input [12:0] rom_cpu_addr,
    input [15:0] cpu_din,
    input [1:0] cpu_dsn,
    output reg [15:0] cpu_dout,
    output [17:1] vram_addr,
    output [1:0] vram_we,
    input [15:0] vram_dout,
    output tile_cs,
    output [22:2] tile_addr,
    input [31:0] tile_data,
    input tile_ok,
    output tile_wait,
    output [4:0] selected_page,
    // Legacy renderer/debug port: low nine bits of the effective bank.
    // The complete bank is retained internally for RAW ROM readback.
    output [8:0] rom_bank,
    output mode_5bpp,
    // Raw REG0..REG1F; word i occupies bits16*i +:16.
    output [511:0] config_regs,
    output [3:0] layer_page0,layer_page1,layer_page2,layer_page3,
    output signed [15:0] layer_dx0,layer_dx1,layer_dx2,layer_dx3,
    output signed [15:0] layer_dy0,layer_dy1,layer_dy2,layer_dy3,
    output [1:0] layer_flip0,layer_flip1,layer_flip2,layer_flip3,
    output gflip_x,gflip_y,
    output signed [12:0] corr_x,
    output signed [11:0] corr_y
);
    reg [15:0] regs[0:31],bregs[0:3];
    genvar cfg;
    generate for(cfg=0;cfg<32;cfg=cfg+1) begin : export_config
        assign config_regs[16*cfg +: 16]=regs[cfg];
    end endgenerate
    integer index;
    wire write_active=cpu_we && !cpu_rnw;
    function [15:0] combine_word(input [15:0] old_word,input [15:0] new_word,input [1:0] dsn);
        begin
            combine_word=old_word;
            if(!dsn[1]) combine_word[15:8]=new_word[15:8];
            if(!dsn[0]) combine_word[7:0]=new_word[7:0];
        end
    endfunction
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            for(index=0;index<32;index=index+1) regs[index]<=16'd0;
            for(index=0;index<4;index=index+1) bregs[index]<=16'd0;
        end else begin
            if(reg_cs && write_active) regs[reg_addr]<=combine_word(regs[reg_addr],cpu_din,cpu_dsn);
            if(b_cs && write_active) bregs[b_addr]<=combine_word(bregs[b_addr],cpu_din,cpu_dsn);
        end
    end
    assign selected_page=regs[0][1] ? 5'd16 : {1'b0,regs[5'h19][4:3],regs[5'h19][1:0]};
    // change_rombank(): num banks = 0x500000 / 0x2000 = 640, NOT 512.
    wire [31:0] bank_register={regs[5'h1b],regs[5'h1a]};
    // 640=5*128. Preserve the low seven bits and reduce the upper 25 bits
    // modulo five; each nibble has equal weight because 16 mod 5 is one.
    function automatic [9:0] wrap_raw_bank(input [31:0] value);
        reg [4:0] pair0,pair1,pair2;
        reg [5:0] left_sum,right_sum;
        reg [6:0] nibble_sum;
        reg [4:0] folded_sum;
        reg [2:0] upper_remainder;
        begin
            pair0={1'b0,value[10:7]}+{1'b0,value[14:11]};
            pair1={1'b0,value[18:15]}+{1'b0,value[22:19]};
            pair2={1'b0,value[26:23]}+{1'b0,value[30:27]};
            left_sum={1'b0,pair0}+{1'b0,pair1};
            right_sum={1'b0,pair2}+{5'd0,value[31]};
            nibble_sum={1'b0,left_sum}+{1'b0,right_sum};
            folded_sum={1'b0,nibble_sum[3:0]}+{2'd0,nibble_sum[6:4]};
            upper_remainder=3'(folded_sum % 5'd5);
            wrap_raw_bank={upper_remainder,value[6:0]};
        end
    endfunction
    // Monster's MAME raw region has768 banks (6MiB / 8KiB).
    // 768=3*256; powers of16 all have residue1 modulo3.
    function automatic [9:0] wrap_monster_bank(input [31:0] value);
        reg [4:0] pair0,pair1,pair2;
        reg [5:0] left_sum;
        reg [6:0] sum;
        reg [1:0] remainder;
        begin
            pair0={1'b0,value[11:8]}+{1'b0,value[15:12]};
            pair1={1'b0,value[19:16]}+{1'b0,value[23:20]};
            pair2={1'b0,value[27:24]}+{1'b0,value[31:28]};
            left_sum={1'b0,pair0}+{1'b0,pair1};
            sum={1'b0,left_sum}+{2'd0,pair2};
            remainder=2'(sum % 7'd3);
            wrap_monster_bank={remainder,value[7:0]};
        end
    endfunction
    wire [9:0] raw_bank=monster ? wrap_monster_bank(bank_register) : wrap_raw_bank(bank_register);
    // 2048 rows per bank: 5 bytes/row (Monster Maulers), 4 bytes/row (Gaiapolis).
    wire [22:0] raw_bank_base={13'd0,raw_bank} * (monster ? 23'd10240 : 23'd8192);
    assign rom_bank=raw_bank[8:0];
    assign mode_5bpp=regs[3][7:6]==2'b11;
    assign layer_page0={regs[8][4:3],regs[12][4:3]};
    assign layer_page1={regs[9][4:3],regs[13][4:3]};
    assign layer_page2={regs[10][4:3],regs[14][4:3]};
    assign layer_page3={regs[11][4:3],regs[15][4:3]};
    assign layer_dx0=regs[20]; assign layer_dx1=regs[21];
    assign layer_dx2=regs[22]; assign layer_dx3=regs[23];
    assign layer_dy0=regs[16]; assign layer_dy1=regs[17];
    assign layer_dy2=regs[18]; assign layer_dy3=regs[19];
    assign layer_flip0=regs[1][1:0]; assign layer_flip1=regs[1][3:2];
    assign layer_flip2=regs[1][5:4]; assign layer_flip3=regs[1][7:6];
    assign gflip_x=regs[0][4]; assign gflip_y=regs[0][5];
    assign corr_x={regs[29][11],regs[29][11:0]};
    assign corr_y={regs[30][10],regs[30][10:0]};
    assign vram_addr={selected_page,vram_cpu_addr};
    assign vram_we=(vram_cs && write_active) ? ~cpu_dsn : 2'b00;

    // mw_rom_word_r() has two address views of the SAME raw bytes:
    // chunky pair = bank*10240+(offset/2)*5+(offset%2)*2;
    // plane-five = bank*10240+(offset/4)*5+4, returned at word bits 12/4.
    localparam RD_IDLE=2'd0,RD_W0=2'd1,RD_W1=2'd2,RD_DONE=2'd3;
    reg [1:0] rd_state;
    reg [22:0] rd_byte_addr;
    reg rd_plane5;
    reg rd_gap; // one CS-low cycle before RD_W1 (see gaiapolis_rom_arb)
    reg [1:0] rd_pair;
    reg [31:0] rd_word0;
    reg [7:0] rd_byte1;
    wire [12:0] rd_offset=rom_cpu_addr;
    assign tile_cs=rd_state==RD_W0 || (rd_state==RD_W1 && !rd_gap);
    assign tile_addr=rd_byte_addr[22:2]+(rd_state==RD_W1 ? 21'd1 : 21'd0);
    assign tile_wait=romrd_cs && cpu_rnw && rd_state!=RD_DONE;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            rd_state<=RD_IDLE; rd_byte_addr<=23'd0; rd_plane5<=1'b0; rd_gap<=1'b0;
            rd_pair<=2'd0; rd_word0<=32'd0; rd_byte1<=8'd0;
        end else case(rd_state)
            RD_IDLE: if(romrd_cs && cpu_rnw) begin
                rd_plane5<=bregs[2][3]; rd_pair<=rd_offset[1:0];
                if(bregs[2][3])
                    rd_byte_addr<=raw_bank_base+({12'd0,rd_offset[12:2]}*23'd5)+23'd4;
                else
                    rd_byte_addr<=raw_bank_base+({11'd0,rd_offset[12:1]}*(monster ? 23'd5 : 23'd4))+
                                  (rd_offset[0] ? 23'd2 : 23'd0);
                rd_state<=RD_W0;
            end
            RD_W0: if(!romrd_cs || !cpu_rnw) rd_state<=RD_IDLE;
                else if(tile_ok) begin
                    rd_word0<=tile_data;
                    rd_state<=(!rd_plane5 && rd_byte_addr[1:0]==2'd3) ? RD_W1 : RD_DONE;
                    rd_gap<=1'b1;
                end
            RD_W1: if(!romrd_cs || !cpu_rnw) rd_state<=RD_IDLE;
                else if(rd_gap) rd_gap<=1'b0;
                else if(tile_ok) begin rd_byte1<=tile_data[7:0]; rd_state<=RD_DONE; end
            RD_DONE: if(!romrd_cs) rd_state<=RD_IDLE;
            default: rd_state<=RD_IDLE;
        endcase
    end
    reg [15:0] raw_pair;
    reg [7:0] fifth_byte;
    always @* begin
        case(rd_byte_addr[1:0])
            2'd0: begin raw_pair={rd_word0[7:0],rd_word0[15:8]}; fifth_byte=rd_word0[7:0]; end
            2'd1: begin raw_pair={rd_word0[15:8],rd_word0[23:16]}; fifth_byte=rd_word0[15:8]; end
            2'd2: begin raw_pair={rd_word0[23:16],rd_word0[31:24]}; fifth_byte=rd_word0[23:16]; end
            default: begin raw_pair={rd_word0[31:24],rd_byte1}; fifth_byte=rd_word0[31:24]; end
        endcase
        cpu_dout=16'hffff;
        if(vram_cs && cpu_rnw) cpu_dout=vram_dout;
        else if(romrd_cs && cpu_rnw && rd_state==RD_DONE)
            cpu_dout=rd_plane5 ? (!monster ? 16'h0000 : {3'd0,fifth_byte[3'd7-{rd_pair,1'b0}],7'd0,
                                 fifth_byte[3'd6-{rd_pair,1'b0}],4'd0}) : raw_pair;
    end
endmodule
