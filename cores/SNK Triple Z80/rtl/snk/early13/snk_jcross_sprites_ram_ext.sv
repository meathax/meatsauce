//AlphaMissionCore_Front_sync.sv
//Author: @RndMnkIII
//Date: 15/03/2022
`default_nettype none
`timescale 1ns/1ps


module snk_jcross_sprites_ram_ext(
 output wire spr_vram_en,output wire [7:0] spr_vram_index,input wire [31:0] spr_vram_word,
 output wire [14:0] sp_socket_addr,input wire [23:0] sp_plane_data,
    input wire tnk3_mode,
    input wire wave_c_mode,
    input  wire VIDEO_RSTn,
    input wire clk,
    input wire CK1,
    //Side SRAM address selector V/C
    input wire V_C,
    //B address
    input wire FRONT_VIDEO_CSn,
    input wire [11:0] VA,
    input wire [7:0] VD_in,
    output logic [7:0] VD_out,
    //hps_io rom interface
	input wire         [24:0] ioctl_addr,
	input wire         [7:0] ioctl_data,
	input wire               ioctl_wr,
    //A address
    input wire VCKn,
    //front SRAM control
    input wire VRD,
    input wire VDG,
    input wire VOE,
    input wire VWE,
    //clocking
    input wire [4:0] FH,
    input wire [8:0] FV,
    input wire LC,
    input wire VLK,
    input wire FCK,
    input wire H3,
    input wire LD,
    input wire CK0,
    //front data output
    output logic [7:0] FD,
    output logic [8:0] FL_Y
);
    logic [7:0] D0_in, D1_in, D2_in, D3_in;
    logic [7:0] Q0, Q1, Q2, Q3;
 wire[31:0]sprite_read_held;
 logic VCKn_reg;
 assign spr_vram_index={FH[4:0],H3,2'b00}; assign spr_vram_en=~VCKn_reg;
 snk_hsj_enabled_response #(.WIDTH(32))sprite_response_hold(.clk(clk),.read_en(spr_vram_en),.read_data(spr_vram_word),.held_data(sprite_read_held));
    logic [7:0] D0_out, D1_out, D2_out, D3_out;
    logic [7:0] Dreg0, Dreg1, Dreg2, Dreg3;

    logic F1B3, F1B2, F1B1, F1B0;
    ttl_74139_nodly b2_cpu_pcb(.Enable_bar(FRONT_VIDEO_CSn), .A_2D(VA[1:0]), .Y_2D({F1B3, F1B2, F1B1, F1B0}));
    
    //bus multiplexers between video data common bus and front SRAM ICs.
    logic F2_EN; //F10 LS32 UnitA
    logic F3_EN; //F10 LS32 UnitB
    logic F4_EN; //F10 LS32 UnitC
    logic F5_EN; //F10 LS32 UnitD

    assign F2_EN =~(F1B0 | VDG);
    assign F3_EN =~(F1B1 | VDG);
    assign F4_EN =~(F1B2 | VDG);
    assign F5_EN =~(F1B3 | VDG);

    assign D0_in = (F2_EN && VRD) ? VD_in : 8'hFF;
    assign D1_in = (F3_EN && VRD) ? VD_in : 8'hFF;
    assign D2_in = (F4_EN && VRD) ? VD_in : 8'hFF;
    assign D3_in = (F5_EN && VRD) ? VD_in : 8'hFF;

    // DIR=L B->A, DIR=H A->B
    // A (VD) -> B(Dx)
    logic [10:0] A;
    logic B3CSn, B2CSn, B1CSn, B0CSn;
    logic d2_dummy;
    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) d5 (.Enable_bar(1'b0), .Select(V_C), .A_2D({F1B3,VCKn,F1B2,VCKn,F1B1,VCKn,F1B0,VCKn}), .Y({B3CSn, B2CSn, B1CSn, B0CSn}));

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) d2 (.Enable_bar(1'b0), .Select(V_C), .A_2D({1'b0,1'b0,(VA[11] & !tnk3_mode),1'b0,VA[10],1'b0,1'b0,1'b0}), .Y({A[10:8],d2_dummy}));

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) d3 (.Enable_bar(1'b0), .Select(V_C), .A_2D({VA[9],1'b0,VA[8],1'b0,VA[7],FH[4],VA[6],FH[3]}), .Y(A[7:4]));

    ttl_74157 #(.DELAY_RISE(0), .DELAY_FALL(0)) d4 (.Enable_bar(1'b0), .Select(V_C), .A_2D({VA[5],FH[2],VA[4],FH[1],VA[3],FH[0],VA[2],H3}), .Y(A[3:0]));

    //--- HM6116P-3 2Kx8 300ns SRAM x 4 ICs ---

    //add one clock delay to VCKn
    always @(posedge clk) begin
        VCKn_reg <= VCKn;
    end

    assign Q0=8'hff; assign Dreg0=sprite_read_held[7:0];

    assign Q1=8'hff; assign Dreg1=sprite_read_held[15:8];


    assign Q2=8'hff; assign Dreg2=sprite_read_held[23:16];

    assign Q3=8'hff; assign Dreg3=sprite_read_held[31:24];

    assign D0_out = (!VOE && !F1B0) ? Q0 : 8'hff;
    assign D1_out = (!VOE && !F1B1) ? Q1 : 8'hff;
    assign D2_out = (!VOE && !F1B2) ? Q2 : 8'hff;
    assign D3_out = (!VOE && !F1B3) ? Q3 : 8'hff;

    assign VD_out = ( (!VRD && F2_EN) ? D0_out : (
                      (!VRD && F3_EN) ? D1_out : (
                      (!VRD && F4_EN) ? D2_out : (
                      (!VRD && F5_EN) ? D3_out : 8'hff
                    ))));

    //add one clock delay to VLK
    logic VLK_reg;
    always @(posedge clk) begin
        VLK_reg <= VLK;
    end

    logic [7:0] G2_Q;
    ttl_74273_sync g2(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(VLK_reg), .D(Dreg0), .Q(G2_Q));
    logic [7:0] Tile_num;
    ttl_74273_sync g3(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(VLK_reg), .D(((tnk3_mode && !wave_c_mode) || !VCKn) ? Dreg1 : 8'hff), .Q(Tile_num));
    logic [7:0] Y_offset;
    ttl_74273_sync g4(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(VLK_reg), .D(Dreg2), .Q(Y_offset));
    logic [7:0] G5_Q;
    ttl_74273_sync g5(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(VLK_reg), .D(((tnk3_mode && !wave_c_mode) || !VCKn) ? Dreg3 : 8'hff), .Q(G5_Q));
    
    logic [3:0] Spr_color_bank;
    logic X_offset_MSB;
    logic Spr_bank_MSB;
    logic Spr_bank_LSB;
    logic Y_offset_MSB;

    assign Spr_bank_MSB = wave_c_mode ? G5_Q[5] : (tnk3_mode ? 1'b0 : ~G5_Q[5]);
    assign  X_offset_MSB = ~G5_Q[4];


    logic [7:0] X_offset;
    genvar i;
    generate
        for(i=0; i<8; i++) begin : x_offset_gen
            assign X_offset[i] = ~G2_Q[i];
        end
    endgenerate

    ttl_74174_sync f7
    (
        .Reset_n(VIDEO_RSTn),
        .Clk(clk),
        .Cen(FCK),
        .Clr_n(1'b1),
        .D({G5_Q[7],G5_Q[3:0],1'b0}),
        .Q({FL_Y[8],Spr_color_bank,Spr_bank_LSB})
    );

    ttl_74273_sync f6(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(FCK), .D(Y_offset), .Q(FL_Y[7:0]));

    logic [7:0] G7_Q;
    ttl_74273_sync g7(.RESETn(VIDEO_RSTn), .CLRn(1'b1), .Clk(clk), .Cen(FCK), .D(Tile_num), .Q(G7_Q));

    //logic e7_D;
    logic e5_cout;
    logic [3:0] e5_sum;

    //assign e7_D = FV[8] ^ X_offset_MSB;

    logic [3:0] e4_sum;
    logic e7_C;
    logic X8OFFr, FV8r, E5COUTr;
    logic [3:0] E5SUMr, E4SUMr;

    always @(posedge clk) begin
        X8OFFr  <= X_offset_MSB;
        FV8r    <= FV[8];
        E5COUTr <= e5_cout;
        E5SUMr  <= e5_sum;
        E4SUMr  <= e4_sum;
    end

    //assign e7_C = e7_D ^ e5_cout;
     assign e7_C = FV8r ^ X8OFFr ^ E5COUTr;

    logic e4_cout;
    ttl_74283_nodly e5 (.A(FV[7:4]), .B(X_offset[7:4]), .C_in(e4_cout),  .Sum(e5_sum), .C_out(e5_cout));

    ttl_74283_nodly e4 (.A(FV[3:0]), .B(X_offset[3:0]), .C_in(1'b1), .Sum(e4_sum), .C_out(e4_cout));

    logic e6_B;
    //assign e6_B = &e5_sum;
    assign e6_B = &E5SUMr;

    logic e8_C;
    ////////////Hack: insert one clock cycle delay to e7_C,e6_B
    // reg e7_Cr, e6_Br;
    // always @(posedge clk) begin
    //     e7_Cr    <= e7_C;
    //     e6_Br    <= e6_B;
    // end
    // assign e8_C = ~(e7_Cr & e6_Br);
     assign e8_C = ~(e7_C & e6_B);

    logic [5:0] F9_Q;

    ttl_74174_sync f9
    (
        .Reset_n(VIDEO_RSTn),
        .Clk(clk),
        .Cen(FCK),
        .Clr_n(1'b1),
        .D({e8_C,(E4SUMr ^ {4{tnk3_mode && !wave_c_mode && G5_Q[5]}}),Spr_bank_MSB}),
        .Q(F9_Q)
    );

    logic f8_dum5, f8_dum0;

    ttl_74174_sync f8
    (
        .Reset_n(VIDEO_RSTn),
        .Clk(clk),
        .Cen(LC),
        .Clr_n(1'b1),
        .D({1'b1,Spr_color_bank,1'b1}),
        .Q({f8_dum5,FD[6:3],f8_dum0})
    );
    assign FD[7] = 1'b0;

    // Canonical Jumping Cross:25 sprites; attribute6 has no bank with256 native tiles.
    // VLK prefetch advances the scan count before this gate: sprite24 is processed at count25.
    reg header_valid=0,row_valid=0;
    always @(posedge clk)begin
      if(!VIDEO_RSTn)begin header_valid<=0;row_valid<=0;end
      else begin
        if(VLK_reg)header_valid<=({FH,H3}<6'd26);
        if(FCK)row_valid<=header_valid;
      end
    end
    //MBM27256-25 250ns 32Kx8x3 FRONT ROMS ---
    wire P11_H11_cs = (ioctl_addr >= 25'h50_000) & (ioctl_addr < 25'h58_000);
	 wire P12_H9_cs  = (ioctl_addr >= 25'h60_000) & (ioctl_addr < 25'h68_000); 
	 wire P13_H8_cs  = (ioctl_addr >= 25'h70_000) & (ioctl_addr < 25'h78_000);

    logic [7:0] H11_D, H11_Dout; //On PCB pulled to Vcc with 4.7Kx8 RA7
    assign sp_socket_addr = {F9_Q[0],Spr_bank_LSB,G7_Q,F9_Q[4:1],FCK};
 assign H11_Dout = sp_plane_data[7:0];

    assign H11_D = (!F9_Q[5]&&row_valid) ? H11_Dout : 8'hFF;
    //assign H11_D = (!f9q5_reg) ? H11_Dout : 8'hFF; //HACK ADDED ONE FCK CLOCK PERIOD DELAY TO F9_Q[5]

    logic [7:0] H9_D, H9_Dout; //On PCB pulled to Vcc with 4.7Kx8 RA6
     assign H9_Dout = sp_plane_data[15:8];
    assign H9_D = (!F9_Q[5]&&row_valid) ? H9_Dout : 8'hFF;
    //assign H9_D = (!f9q5_reg) ? H9_Dout : 8'hFF; //HACK ADDED ONE FCK CLOCK PERIOD DELAY TO F9_Q[5]

    logic [7:0] H8_D,H8_Dout; //On PCB pulled to Vcc with 4.7Kx8 RA5
     assign H8_Dout = sp_plane_data[23:16];
    assign H8_D = (!F9_Q[5]&&row_valid) ? H8_Dout : 8'hFF;
    //assign H8_D = (!f9q5_reg) ? H8_Dout : 8'hFF; //HACK ADDED ONE FCK CLOCK PERIOD DELAY TO F9_Q[5]

//    logic LD_reg;
//    always @(posedge clk) begin
//       LD_reg <= LD; 
//    end
    snk_jcross_sprites_ext_PLSO_shift g10 (.RESETn(VIDEO_RSTn), .CLK(clk), .CEN(~CK0), .LOADn(LD), .SI(1'b1), .D(H11_D), .SO(FD[0])); //Hack CLK should be CK0
    snk_jcross_sprites_ext_PLSO_shift g9  (.RESETn(VIDEO_RSTn), .CLK(clk), .CEN(~CK0), .LOADn(LD), .SI(1'b1), .D(H9_D),  .SO(FD[1])); //Hack CLK should be CK0
    snk_jcross_sprites_ext_PLSO_shift g8  (.RESETn(VIDEO_RSTn), .CLK(clk), .CEN(~CK0), .LOADn(LD), .SI(1'b1), .D(H8_D),  .SO(FD[2])); //Hack CLK should be CK0
endmodule

module snk_jcross_sprites_ext_PLSO_shift (RESETn, CLK, CEN, LOADn, SI, D, SO); 
    input wire RESETn, CLK, CEN, SI, LOADn; 
    input wire [7:0] D; 
    output wire SO;

    reg [7:0] tmp; 
    reg last_cen;

    always @(posedge CLK) 
    begin 
        if (!RESETn) begin
            tmp <= 0;
            last_cen = 1'b1;
        end
        else begin
            last_cen <= CEN;

            if (CEN && !last_cen) begin
                if (!LOADn) tmp <= D; 
                else        tmp <= {tmp[6:0], SI};
            end 
        end
    end 

    assign SO = tmp[7]; 
endmodule 
