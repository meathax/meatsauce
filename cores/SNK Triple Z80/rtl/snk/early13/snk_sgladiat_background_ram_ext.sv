//AlphaMissionCore_Back1_sync.sv
//Author: @RndMnkIII
//Date: 16/03/2022
`default_nettype none
`timescale 1ns/1ps

module snk_sgladiat_background_ram_ext(
 output wire bg_vram_en,output wire [12:0] bg_vram_index,input wire [7:0] bg_vram_data,
 output wire [14:0] bg_socket_addr,input wire [7:0] bg_byte_data,
 input [7:0] native_bg_x,native_bg_y,
    input wire tnk3_mode,
    input  wire VIDEO_RSTn,
    input wire clk,
    input wire CK1,
    input wire RESET,
    //Flip screen control
    input wire INV,
    input wire INVn,
    //common video data bus
    input wire [7:0] VD_in,
    output logic [7:0] VD_out,
    //hps_io rom interface
	input wire         [24:0] ioctl_addr,
	input wire         [7:0] ioctl_data,
	input wire               ioctl_wr,
    //Registers
    input wire B1SY,
    input wire B1SX,

    //MSBs
    input wire B1Y8,
    input wire B1X8,

    //VIDEO/CPU Selector
    input wire V_C,

    //B address
    input wire H8,
    input wire [4:0] Y, //Y[7:3] in schematics
    input wire H2,
    input wire H1,
    input wire H0,
    input wire [7:0] X, 

    input wire [12:0] VA,
    input wire BACK1_VRAM_CSn,
    input wire [1:0] B1_TILEBANK, //from CPU_PCB 5A(15,12)
    
    //A address
    input wire VFLGn,

    //side SRAM control
    input wire VRD,
    input wire VDG,
    input wire VOE,
    input wire VWE,

    //clocking
    input wire CK1n,
    input wire LA,
    input wire VLK,
    //input wire H3

    //Back1 data color
    input wire [3:0] B1_COLORBANK,
    input wire B1_COLBK, JMP_B1D7,
    output logic [7:0] B1D
);
    //Y Scroll Register, Adder section
    logic [2:0] XOR_YSR;
    wire [7:0] B1Y={native_bg_y[7:3],native_bg_y[2:0]^{3{INVn}}};
    assign XOR_YSR[2] = VD_in[2] ^ INVn;
    assign XOR_YSR[1] = VD_in[1] ^ INVn;
    assign XOR_YSR[0] = VD_in[0] ^ INVn;

    //*** Synchronous Hack ***
    reg [7:0] vdin_r;
    always @(posedge clk) begin
        vdin_r <= {VD_in[7:3],XOR_YSR};
    end



    logic [8:0] B1H;
    logic [2:0] B1Hn;
    logic c14_dum3;
    logic [1:0] c12_dum;
    //Y7~3 -> Y[4:0]
    ttl_74283_nodly c14 (.A({1'b1, B1Y[2:0]}),    .B({1'b1, H2,H1,H0}), .C_in(1'b0),     .Sum({c14_dum3,B1H[2:0]}),           .C_out()        );
    logic c13_cout;
    ttl_74283_nodly c13 (.A(B1Y[6:3]),            .B(Y[3:0]),           .C_in(1'b0),     .Sum(B1H[6:3]),                      .C_out(c13_cout));
    ttl_74283_nodly c12 (.A({2'b11,B1Y8,B1Y[7]}), .B({2'b11, H8,Y[4]}), .C_in(c13_cout), .Sum({c12_dum,B1H[8:7]}),            .C_out()        );

    assign B1Hn[0] = ~B1H[0];
    assign B1Hn[1] = ~B1H[1];
    assign B1Hn[2] = ~B1H[2];

    logic [8:0] B1HQ;
    //logic [2:0] d13_dum;
    logic [5:0] d13_q;
    ttl_74174_sync d13
    (
        .Reset_n(VIDEO_RSTn),
        .Clk(clk),
        .Cen(CK1n),
        .Clr_n(1'b1),
        .D({3'b111,B1Hn}),
        .Q(d13_q)
    );
    assign B1HQ[2:0] = d13_q[2:0];

    logic [5:0] d12_q;
    ttl_74174_sync d12
    (
        .Reset_n(VIDEO_RSTn),
        .Clk(clk),
        .Cen(CK1n),
        .Clr_n(1'b1),
        .D(B1H[8:3]),
        .Q(d12_q)
    );
    assign B1HQ[8:3] = d12_q[5:0];

    //X Scroll Register, Adder section
    reg [7:0] vdinX_r;
     always @(posedge clk) begin
        vdinX_r <= VD_in;
    end

    wire [7:0] B1X=native_bg_x;

    logic [8:0] B1V;
    logic a12_cout;
    ttl_74283_nodly a12 (.A(B1X[3:0]),    .B(X[3:0]), .C_in(1'b0),         .Sum(B1V[3:0]), .C_out(a12_cout));
    logic a11_cout;
    ttl_74283_nodly a11 (.A(B1X[7:4]),    .B(X[7:4]), .C_in(a12_cout),     .Sum(B1V[7:4]), .C_out(a11_cout));
    assign B1V[8] = B1X8 ^ a11_cout;

    //2:1 Back1 SRAM bus addresses MUX
    //ttl_74157 A_2D({B3,A3,B2,A2,B1,A1,B0,A0})
    logic h12_CSn; //SRAM chip select signal
    logic [11:0] A;
    logic dum3,dum2,dum1;

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) e12 (.Enable_bar(1'b0), .Select(V_C),
                .A_2D({VA[11],B1HQ[8],VA[10],B1HQ[7],VA[9],B1HQ[6],VA[8],B1HQ[5]}), .Y(A[11:8]));

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) e13 (.Enable_bar(1'b0), .Select(V_C),
                .A_2D({VA[7],B1HQ[4],VA[6],B1HQ[3],VA[5],B1V[8],VA[4],B1V[7]}), .Y(A[7:4]));

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) e14 (.Enable_bar(1'b0), .Select(V_C),
                .A_2D({VA[3],B1V[6],VA[2],B1V[5],VA[1],B1V[4],VA[0],B1V[3]}), .Y(A[3:0]));

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) d2 (.Enable_bar(1'b0), .Select(V_C),
                .A_2D({1'b0,1'b0,1'b0,1'b0,1'b0,1'b0,BACK1_VRAM_CSn,VFLGn}), .Y({dum3,dum2,dum1,h12_CSn}));

    wire tnk_b1b0 = VA[0] | BACK1_VRAM_CSn;
    wire tnk_b1b1 = ~(VA[0] & ~BACK1_VRAM_CSn);
    wire tnk_l3_csn, tnk_l4_csn, tnk_addr_dummy, tnk_cs_dummy;
    ttl_74157 #(.DELAY_RISE(0),.DELAY_FALL(0)) tnk_cs_mux(
        .Enable_bar(1'b0),.Select(V_C),
        .A_2D({VA[1],B1V[3],tnk_b1b0,VFLGn,tnk_b1b1,VFLGn,1'b1,1'b1}),
        .Y({tnk_addr_dummy,tnk_l3_csn,tnk_l4_csn,tnk_cs_dummy}));
    wire attr_sel = tnk3_mode && !(tnk_b1b1 | VDG);
    logic BACK1_SEL;
    assign BACK1_SEL = ~((tnk3_mode ? tnk_b1b0 : BACK1_VRAM_CSn) | VDG);

    //data bus multiplexer from VD_in  
    logic [7:0] D, Din;
    assign Din = (BACK1_SEL && VRD) ?  VD_in : 8'hFF;

    //--- HM6264LP-15 8Kx8 150ns SRAM ---
    logic [7:0] back1_Q;
    logic [7:0] Dreg;
    logic h12_CS;

    assign h12_CS = ~h12_CSn;

    // Normal SG source: H=(column-4)&511; X=(row+40)&255.
    // Prefetch advances one increasing source column before output palette latch.
    wire [8:0] native_physical_h={H8,Y,H2,H1,H0};
    wire [8:0] native_column={B1X8,native_bg_x}+native_physical_h-9'd10;
    wire [7:0] native_vertical=X+native_bg_y-8'd40;
    wire [14:0] native_rom_address={B1_TILEBANK,Dreg,native_vertical[2:0],native_column[2:1]};
    logic [12:0] h12_addr1;
    assign h12_addr1 = INV ? {2'b00,native_column[8:3],native_vertical[7:3]} : {2'b00,B1HQ[7:3],B1V[8:3]};

    assign back1_Q=8'hff; assign bg_vram_index=h12_addr1; assign bg_vram_en=INV ? 1'b1 : ~VFLGn;
 snk_hsj_enabled_response #(.WIDTH(8)) bg_response_hold(.clk(clk),.read_en(bg_vram_en),.read_data(bg_vram_data),.held_data(Dreg));

    wire [7:0] attr_cpu_q, attr_video_q;
    // Canonical HSJ tops tie tnk3_mode=0; attribute RAM and output are unused.
 assign attr_cpu_q=8'hff; assign attr_video_q=8'h00;
    wire [7:0] attr_stage1, attr_stage2, attr_stage3;
    ttl_74273_sync attr1(.RESETn(VIDEO_RSTn),.CLRn(1'b1),.Clk(clk),.Cen(VLK),.D(attr_video_q),.Q(attr_stage1));
    ttl_74273_sync attr2(.RESETn(VIDEO_RSTn),.CLRn(1'b1),.Clk(clk),.Cen(LA),.D(attr_stage1),.Q(attr_stage2));
    ttl_74273_sync attr3(.RESETn(VIDEO_RSTn),.CLRn(1'b1),.Clk(clk),.Cen(B1HQ[2]),.D(attr_stage2),.Q(attr_stage3));
    wire [5:0] attr_palette_q;
    ttl_74174_sync attr_palette(.Reset_n(VIDEO_RSTn),.Clk(clk),.Cen(B1HQ[0]),
        .Clr_n(1'b1),.D({2'b11,attr_stage3[3:0]}),.Q(attr_palette_q));
    assign B1D[7:4] = tnk3_mode ? {(JMP_B1D7 ? B1_COLBK : attr_palette_q[3]),attr_palette_q[2:0]} : B1_COLORBANK;
    assign D = (!VOE) ? back1_Q : 8'hff;
    assign VD_out = (BACK1_SEL && !VRD) ? D : ((attr_sel && !VRD && !VOE) ? attr_cpu_q : 8'hff);

    //added delay using FF
    //ttl_74273_sync Dreg_dly(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(CK1), .D(D), .Q(Dreg));

    //Background tile ROM address generator
    logic [7:0] F12_Q;
    ttl_74273_sync f12(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(VLK), .D(Dreg), .Q(F12_Q));

    logic [7:0] F13_Q;
    ttl_74273_sync f13(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(LA), .D(F12_Q), .Q(F13_Q));

    logic [7:0] F14_Q;
    ttl_74273_sync f14(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(B1HQ[2]), .D(F13_Q), .Q(F14_Q));

    logic H14_A0;
    logic H14_A1;
    assign H14_A0 = B1HQ[1] ^ INV; //IC 11D Unit B
    assign H14_A1 = B1HQ[2] ^ INV; //IC 11D Unit A

    //MBM27256-25 250ns 32Kx8 P10 BACK1 ROM ---
    //hps_io rom load interface
    wire H14_D_cs = (ioctl_addr >= 25'h40_000) & (ioctl_addr < 25'h48_000);
    
    logic [7:0] H14_D;
    assign bg_socket_addr = INV ? native_rom_address : {(tnk3_mode ? attr_stage3[5:4] : B1_TILEBANK), F14_Q[7:0], B1V[2:0], H14_A1, H14_A0};
 assign H14_D = bg_byte_data;

    logic [7:0] G14_Q;
    ttl_74273_sync g14(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(B1HQ[0]), .D(H14_D), .Q(G14_Q));

    logic G14_S;
    assign G14_S = INV ? native_column[0] : (B1HQ[0] ^ INV);
    wire [7:0] native_pixel_byte=INV ? H14_D : G14_Q; //IC 11D Unit C
    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) a2 (.Enable_bar(1'b0), .Select(G14_S),
                .A_2D({native_pixel_byte[7],native_pixel_byte[3],native_pixel_byte[6],native_pixel_byte[2],native_pixel_byte[5],native_pixel_byte[1],native_pixel_byte[4],native_pixel_byte[0]}), .Y(B1D[3:0]));
endmodule