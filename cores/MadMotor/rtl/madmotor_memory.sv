// SPDX-License-Identifier: GPL-3.0-or-later
// Same-clock CPU/video memory, using the staged JTFRAME whole-byte banks.
// Reads retire after one edge. Read-during-write returns the previous word.
module madmotor_memory #(parameter SERVICE_ENABLE=0)(
    input tri0 bandit,
    input wire clk,
    input wire [23:0] address,
    input wire [15:0] write_data,
    input wire [1:0] be,
    input wire write_strobe,work_cs,aux_cs,
    input wire [2:0] pf_cs,
    output wire [15:0] work_q,aux_q,
    output wire [15:0] pf_q [3],
    input wire [12:0] vram_addr [3],
    output wire [15:0] vram_data [3],
    input wire [12:0] service_addr,
    input wire [15:0] service_data,
    input wire [1:0] service_we,
    output wire [15:0] service_q
);
    wire [15:0] pf_video [3],aux_video,aux1_video,aux2_video;
    wire [15:0] aux0_q,aux1_q,aux2_q;
    wire aux1_cs=bandit && address[23:11]==13'h490;
    wire aux2_cs=bandit && address[23:11]==13'h499;
    assign aux_q=aux1_cs?aux1_q:aux2_cs?aux2_q:aux0_q;
    reg [2:0] tile_selected;
    always @(posedge clk) tile_selected<={vram_addr[2][12],vram_addr[1][12],vram_addr[0][12]};
    assign vram_data[0]=tile_selected[0]?pf_video[0]:aux_video;
    assign vram_data[1]=tile_selected[1]?pf_video[1]:(bandit?aux1_video:16'd0);
    assign vram_data[2]=tile_selected[2]?pf_video[2]:(bandit?aux2_video:16'd0);
    madmotor_dual_ram16 #(.AW(13)) work_ram(
        .clk0(clk),.addr0(address[13:1]),.data0(write_data),.we0(be&{2{write_strobe&&work_cs}}),.q0(work_q),
        .clk1(clk),.addr1(SERVICE_ENABLE ? service_addr : 13'd0),
        .data1(SERVICE_ENABLE ? service_data : 16'd0),
        .we1(SERVICE_ENABLE ? service_we : 2'b00),.q1(service_q));
    madmotor_dual_ram16 #(.AW(12)) pf0(
        .clk0(clk),.addr0(address[12:1]),.data0(write_data),.we0(be&{2{write_strobe&&pf_cs[0]}}),.q0(pf_q[0]),
        .clk1(clk),.addr1(vram_addr[0][11:0]),.data1(16'd0),.we1(2'b00),.q1(pf_video[0]));
    madmotor_dual_ram16 #(.AW(10)) pf1(
        .clk0(clk),.addr0(address[10:1]),.data0(write_data),.we0(be&{2{write_strobe&&pf_cs[1]}}),.q0(pf_q[1]),
        .clk1(clk),.addr1(vram_addr[1][9:0]),.data1(16'd0),.we1(2'b00),.q1(pf_video[1]));
    madmotor_dual_ram16 #(.AW(11)) pf2(
        .clk0(clk),.addr0(bandit?{1'b0,address[10:1]}:address[11:1]),.data0(write_data),.we0(be&{2{write_strobe&&pf_cs[2]}}),.q0(pf_q[2]),
        .clk1(clk),.addr1(bandit?{1'b0,vram_addr[2][9:0]}:vram_addr[2][10:0]),.data1(16'd0),.we1(2'b00),.q1(pf_video[2]));
    madmotor_dual_ram16 #(.AW(10)) aux_ram(
        .clk0(clk),.addr0(address[10:1]),.data0(write_data),.we0(be&{2{write_strobe&&aux_cs&&!aux1_cs&&!aux2_cs}}),.q0(aux0_q),
        .clk1(clk),.addr1(vram_addr[0][9:0]),.data1(16'd0),.we1(2'b00),.q1(aux_video));
    madmotor_dual_ram16 #(.AW(10)) aux1_ram(
        .clk0(clk),.addr0(address[10:1]),.data0(write_data),.we0(be&{2{write_strobe&&aux_cs&&aux1_cs}}),.q0(aux1_q),
        .clk1(clk),.addr1(vram_addr[1][9:0]),.data1(16'd0),.we1(2'b00),.q1(aux1_video));
    madmotor_dual_ram16 #(.AW(10)) aux2_ram(
        .clk0(clk),.addr0(address[10:1]),.data0(write_data),.we0(be&{2{write_strobe&&aux_cs&&aux2_cs}}),.q0(aux2_q),
        .clk1(clk),.addr1(vram_addr[2][9:0]),.data1(16'd0),.we1(2'b00),.q1(aux2_video));
endmodule
