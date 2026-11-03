//============================================================================
//  Arcade: Taito System SJ
//
//  Manufaturer: Taito
//  Type: Arcade Game
//  Genre: 
//  Orientation: 
//
//  Hardware Description by Anton Gale
//  https://github.com/MiSTer-devel/Arcade-TaitoSJ_MiSTer
//
//============================================================================
`timescale 1ns/1ps

module taitosj_fpga(
	input clkm_48MHZ,
	input clkm_32MHZ,
	input [7:0] pcb,	
	output reg [2:0] RED,    
	output reg [2:0] GREEN,	 
	output reg [2:0] BLUE,	 
	output core_pix_clk,			
	output H_SYNC,				
	output V_SYNC,				
	output H_BLANK,
	output V_BLANK,
	input RESET_n,				
	input pause,
	//joystick controls

	input [15:0] P1CONTROLS,
	input [7:0] DIP1,
	input [7:0] DIP2,
	input [7:0] DIP3,	
   input [4:0] DBG_SPR_FIRST,
   input [4:0] DBG_SPR_LAST,
 	input [24:0] dn_addr,
	input 		 dn_wr,
	input [7:0]  dn_data,
	output signed [15:0] audio_l, //from jt49_1 & 2
	output signed [15:0] audio_r, //from jt49_1 & 2
	input [15:0] hs_address,
	output [7:0] hs_data_out,
	input [7:0] hs_data_in,
	input hs_write
);

wire m_right 	= P1CONTROLS[0];
wire m_left 	= P1CONTROLS[1];	
wire m_down		= P1CONTROLS[2];   
wire m_up		= P1CONTROLS[3];  	
wire m_shoot	= P1CONTROLS[4];
wire m_shoot2	= P1CONTROLS[5]; 	
wire m_coina	= P1CONTROLS[6]; 
wire m_start1p	= P1CONTROLS[7];	
wire m_coinb	= P1CONTROLS[8]; 
wire m_start2p	= P1CONTROLS[9];	
wire m_service	= P1CONTROLS[10]; 
wire m_gunright= P1CONTROLS[12]; 
wire m_gunleft	= P1CONTROLS[13]; 
wire m_gundn	= P1CONTROLS[14]; 
wire m_gunup	= P1CONTROLS[15]; 

//SYSTEM SJ CLOCKS - VIDEO
reg clkm_24MHZ, clkm_12MHZ, clkm_3MHZ, clkm_1p5MHZ;
reg clkm_6MHZ,clk2_6MHZ,clk3_6MHZ;
reg clkb_6MHZ,clkb_3MHZ,clkc_6MHZ,clkm_750HZ,clkb_750HZ,clk2B_6MHZ;

//core clock generation logic based on jtframe code
reg [5:0] cencnt =6'd0;

always @(posedge clkm_48MHZ) begin
	cencnt  <= cencnt+5'd1;
end

always @(posedge clkm_48MHZ) begin
	clkm_24MHZ	  	<= cencnt[0]   == 1'd0;
	clkm_12MHZ		<= cencnt[1:0] == 2'd0;
	clkm_6MHZ		<= cencnt[2:0] == 3'd0;
	clkc_6MHZ		<= cencnt[2:0] == 3'd0;
	clk2_6MHZ		<= cencnt[2:0] == 3'd1;	
	clk2B_6MHZ		<= cencnt[2:0] == 3'd7;	   //phase adjuster tried 0,1,2,3,7 
	clk3_6MHZ		<= cencnt[2:0] == 3'd3;	
	clkb_6MHZ		<= cencnt[2:0] == 3'd4;
   clkm_3MHZ		<= cencnt[3:0] == 4'd0;
	clkb_3MHZ		<= cencnt[3:0] == 4'd8;	
   clkm_1p5MHZ		<= cencnt[4:0] == 5'd0;		
   clkm_750HZ		<= cencnt[5:0] == 6'd0;			
   clkb_750HZ		<= cencnt[5:0] == 6'd32;			
end

assign core_pix_clk=clkc_6MHZ;

//SYSTEM SJ CLOCKS - CPU
reg clkm_16MHZ,clkm_8MHZ, clkm_8MHZn, clkm_4MHZ,clkm_4MHZn,clkm_2MHZ;

reg [3:0] mcpucnt =4'd0;

always @(posedge clkm_32MHZ) begin
	mcpucnt  <= mcpucnt+4'd1;
end

always @(posedge clkm_32MHZ) begin
	clkm_16MHZ	  	<= mcpucnt[0]   == 1'd0;
	clkm_8MHZ	  	<= mcpucnt[1:0] == 2'd0;
	clkm_8MHZn	  	<= mcpucnt[1:0] == 2'd2;	
	clkm_4MHZ	  	<= mcpucnt[2:0] == 3'd0;
	clkm_4MHZn	  	<= mcpucnt[2:0] == 3'd4;
	clkm_2MHZ	  	<= mcpucnt[3:0] == 4'd0;
end

//Z80A (Main CPU) address & databus definitions
wire Z80A_MREQ,Z80A_WR,Z80A_RD,Z80A_IOREQ,Z80A_RFSH,Z80A_M1,Z80A_INT;
reg Z80A_BUSAK;
wire [15:0] Z80A_addrbus;
wire [7:0]  Z80A_databus_in,Z80A_databus_out,Z80A_RAM_out,Z80A_MROM_out,Z80A_BROM_out,MCU_ROM_out,Z80A_SCRAM_out;

//chip selects:
wire MROMRQ,BROMRQ,SRAMREQ,HTCLR,EXROM1,EXROM2,EPORT1,EPORT2,TIME_RESET,COIN_SET,EXPORT,SCRAM;
wire MCU,MCU_ROM,MCU_ROM_RD;

//program ROM 
assign MROMRQ   = (Z80A_addrbus[15]    == 1'b0)   & !BANK_SEL & !Z80A_MREQ; //Main Program ROM
assign BROMRQ	 = (Z80A_addrbus[15]    == 1'b0)   &  BANK_SEL & !Z80A_MREQ; //Main Program Banked ROM
assign MCU_ROM  = (Z80A_addrbus[15:13] == 3'b111) & !BANK_SEL & !Z80A_MREQ; //E000 - EFFF - MCU ROM

//work RAM
assign SRAMREQ  = (Z80A_addrbus[15:11] == 5'b10000) 						? 1'b1 : 1'b0; //8000 - 87FF - Main CPU RAM

//MCU
assign MCU 		 = (Z80A_addrbus[15:9] == 7'b1000100) 						? 1'b0 : 1'b1; //8800 - 89FF - MCU Read/Write


//VRAM
assign CDR1RQ	 = (Z80A_addrbus[15:11] == 5'b10010)						? 1'b0 : 1'b1; //9000 - 97FF - Character Generator RAM
assign CDR2RQ	 = (Z80A_addrbus[15:11] == 5'b10011)						? 1'b0 : 1'b1; //9800 - 9FFF - Character Generator RAM
assign CDR3RQ	 = (Z80A_addrbus[15:11] == 5'b10100)						? 1'b0 : 1'b1; //A000 - A7FF - Character Generator RAM
assign CDR4RQ	 = (Z80A_addrbus[15:11] == 5'b10101)						? 1'b0 : 1'b1; //A800 - AFFF - Character Generator RAM
assign CDR5RQ	 = (Z80A_addrbus[15:11] == 5'b10110)						? 1'b0 : 1'b1; //B000 - B7FF - Character Generator RAM
assign CDR6RQ	 = (Z80A_addrbus[15:11] == 5'b10111)						? 1'b0 : 1'b1; //B800 - BFFF - Character Generator RAM
assign CHARQ	 = (Z80A_addrbus[15:12] == 4'b1100) 						? 1'b0 : 1'b1; //C000 - CFFF - Tilemap RAM

assign PROT_SEL =	(Z80A_addrbus==16'hD48B);//Space Cruiser Protection Selection

//D5XX registers (WRITE)
assign SPH1	 			= (Z80A_addrbus == 16'hD500)							? Z80A_WR : 1'b1; //Horizontal Scroll  - Tilemap #1
assign SPV1	 			= (Z80A_addrbus == 16'hD501)							? Z80A_WR : 1'b1; //Vertical Scroll    - Tilemap #1  
assign SPH2	 			= (Z80A_addrbus == 16'hD502)							? Z80A_WR : 1'b1; //Horizontal Scroll  - Tilemap #2
assign SPV2	 			= (Z80A_addrbus == 16'hD503)							? Z80A_WR : 1'b1; //Vertical Scroll    - Tilemap #2  
assign SPH3	 			= (Z80A_addrbus == 16'hD504)							? Z80A_WR : 1'b1; //Horizontal Scroll  - Tilemap #3
assign SPV3	 			= (Z80A_addrbus == 16'hD505)							? Z80A_WR : 1'b1; //Vertical Scroll    - Tilemap #3  
assign SMD12 			= (Z80A_addrbus == 16'hD506)							? Z80A_WR : 1'b1; //Bank & Colour Code - Tilemap #1 & 2
assign SMD3	 			= (Z80A_addrbus == 16'hD507)							? Z80A_WR : 1'b1; //Bank & Colour Code - Tilemap #3
assign HTCLR	 		= (Z80A_addrbus == 16'hD508)							? Z80A_WR : 1'b1; //Hit Detection Clear
assign EXROM1	 		= (Z80A_addrbus == 16'hD509)							? Z80A_WR : 1'b1; //External Graphics ROM Low Address
assign EXROM2	 		= (Z80A_addrbus == 16'hD50A)							? Z80A_WR : 1'b1; //External Graphics ROM High Address
assign EPORT1	 		= (Z80A_addrbus == 16'hD50B)							? Z80A_WR : 1'b1; //Sound CPU <-> Main CPU Interface
assign EPORT2	 		= (Z80A_addrbus == 16'hD50C)							? Z80A_WR : 1'b1; //Main CPU D0 -> Sound CPU DB2
assign TIME_RESET	 	= (Z80A_addrbus == 16'hD50D)							? Z80A_WR : 1'b1; //Reset Watchdog
assign COIN_SET 		= (Z80A_addrbus == 16'hD50E)							? Z80A_WR : 1'b1; //COINLOCK & SOUNDSTOP signals 
assign EXPORT	 		= (Z80A_addrbus == 16'hD50F)  						? Z80A_WR : 1'b1; 

assign SCRRQ 			= (Z80A_addrbus[15:8] == 8'b11010000) 				? 1'b0 	 : 1'b1; //D000 - D0FF - Column scroll
assign OBJRQ 			= (Z80A_addrbus[15:8] == 8'b11010001) & !Z80A_MREQ & Z80A_RFSH ? 1'b0 : 1'b1; //D100 - D1FF - Object data (sprite locations etc.)
assign VCRRQ 			= (Z80A_addrbus[15:8] == 8'b11010010) 				? 1'b0 	 : 1'b1; //D200 - D2FF - Palette
assign PRY				= (Z80A_addrbus[15:8] == 8'b11010011) 				? Z80A_WR : 1'b1; //D300 - D3FF - Priority
assign HTRRQ			= (Z80A_addrbus[15:2] == 14'b11010100000000) 	? Z80A_RD : 1'b1; //D400 - D403 - Collision
assign EXRHR			= (Z80A_addrbus[15:2] == 14'b11010100000001) 	? Z80A_RD : 1'b1; //D404 - D407 - External ROM
assign AY_0_SEL		= (Z80A_addrbus[15:1] == 15'b110101000000111) 	? 1'b1 	 : 1'b0; //D40E - D40F - CPU controlled AY soundchip
assign SOFF				= (Z80A_addrbus[15:8] == 8'b11010110) 				? Z80A_WR : 1'b1; //D600 - D6FF - Screen Inversion, Spritebank Select, Tilemap enables


assign SCRAM			= (Z80A_addrbus[15:8] == 8'b11011000)				? 1'b1 : 1'b0;


//CPU read selection logic
// ******* PRIMARY CPU IC SELECTION LOGIC FOR TILE, SPRITE, SOUND & GAME EXECUTION ********
assign Z80A_databus_in =	(MROMRQ  						& !Z80A_RD) 	? Z80A_MROM_out 		:
									(BROMRQ  						& !Z80A_RD) 	? Z80A_BROM_out 		:
									(MCU_ROM							& !Z80A_RD)		? MCU_ROM_out			:
									(SRAMREQ  						& !Z80A_RD) 	? Z80A_RAM_out  		:
									(SCRAM							& !Z80A_RD)		? Z80A_SCRAM_out		:
									(!OBJRQ 							& !Z80A_RD)		? Z80A_OD_out 			:
									(!EXRHR 							& !Z80A_RD)		? EXT_DATA				:
									(!HTRRQ 							& !Z80A_RD)		? HIT_DATA				:
									(!CHARQ							& !Z80A_RD)    ? Z80A_CPU_CD_data 	:
									(!SCRRQ    						& !Z80A_RD)		? Z80A_SCD_data_out 	:
									(PROT_SEL						& !Z80A_RD)    ? PROT_DATA				:
									(Z80A_addrbus == 16'hD40D	& !Z80A_RD) 	? INPUT5X 				:
									(Z80A_addrbus == 16'hD40C	& !Z80A_RD) 	? INPUT4X 				:
									(Z80A_addrbus == 16'hD40B	& !Z80A_RD) 	? INPUT3X 				:
									(Z80A_addrbus == 16'hD40A	& !Z80A_RD) 	? DIPSWA  				:
									(Z80A_addrbus == 16'hD409	& !Z80A_RD) 	? INPUT1X 				:
									(Z80A_addrbus == 16'hD408 	& !Z80A_RD) 	? INPUT0X 				:
									(AY_0_SEL         			& !Z80A_RD)    ? AY_0_databus_out   :
									(!MCU & pcb[2]					& !Z80A_RD)		? mcu_bs_dout			: //8'b11111111   		:
									(!MCU & !pcb[2]				& !Z80A_RD)		? 8'b11111111			:
									
									8'b00000000;

wire PUR = 1'b1;
wire CHARQ,SOFF,PRY,VCRRQ,OBJRQ,SCRRQ,SMD3,SMD12,SPV3,SPH3,SPV2,SPH2,SPV1,SPH1;
wire CDR6RQ,CDR5RQ,CDR4RQ,CDR3RQ,CDR2RQ,CDR1RQ; //VRAM CHIP SELECTS
wire OBJ_CINV,SN3OFF,SN2OFF,SN1OFF,VINV,HINV,HITOB,HLP0,HLP1,HLP2;

wire WD_RESET,INT_RST,PROT_SEL,OBJ,SCN1,SCN2,SCN3;
wire HTRRQ,EXRHR;
reg rZ80A_INT;

wire [7:0]  CRD,CGD,CBD,CRDH,CGDH,CBDH;
reg  CCH3,CCH1,CCH2;			//Tile Map x Character Bank
reg  [2:0] MD1,MD2,MD3; 	//Tile Map x Colour Codes
reg  [1:0] MD0;			  	//Sprite Colour Code
reg  [7:0] SN11_in,SN21_in,SN31_in;
reg  [7:0] SN12_in,SN22_in,SN32_in;
reg  [7:0] SN13_in,SN23_in,SN33_in;
wire [3:0] OB;
wire [2:0] SN1,SN2,SN3;
reg  [7:0] reset_counter;
reg  [4:0] PRIORITY;
wire [3:0] EB16_out;
wire [7:0] HIT_DATA;
wire wait_n = !pause;
wire [15:0] RGB;
wire SN1LD,SN2LD,SN3LD,PH01,PH23,PH45,PH67;
wire BLANK;
wire [4:0] syncbus_HM;
wire [8:0] syncbus_HN;
wire [7:0] syncbus_H,syncbus_V,syncbus_PH;
wire [7:0] SCD,Z80A_SCD_data_out,Z80A_OD_out;
wire [12:0] OBJ_CHA;

reg  [10:0] CD_CHA;
reg  [7:0] S_DATA; //scroll data

reg  [4:0] DHPH5,DHPH3,DHPH1; //HORIZONTAL SCROLL REGISTERS
wire [4:0] DH,DH2;
wire [5:0] HORZBITS,HORZBITS2;

reg  [7:0] DVPH7,DVPH5,DVPH3; //VERTICAL SCROLL REGISTERS
wire [7:0] DV,VERTBITS;
wire [7:0] CD_out,Z80A_CPU_CD_data;
reg  [5:0] MA;

wire [14:0] EXT_ROM_ADDR;
reg  [14:0] EX_COUNTER;
reg  [7:0] D509,D50A;
wire [7:0] EXT_DATA;
reg  [7:0] PROT_DATA,ALP_PROT;


//wire CDRRQ;
//assign CDRRQ =!(CDR1RQ&CDR2RQ&CDR3_6); //U54B - CPU is not writing to graphics memory
reg [11:0] Z80A_VRAMR,Z80A_VRAMG,Z80A_VRAMB;
reg CDR_B,CDR_G,CDR_R;

always @(posedge clkm_48MHZ) begin
//  if (clkm_6MHZ) begin
    Z80A_VRAMB <= {!CDR6RQ, Z80A_addrbus[10:0]};
    Z80A_VRAMG <= {!CDR5RQ, Z80A_addrbus[10:0]};
    Z80A_VRAMR <= {!CDR4RQ, Z80A_addrbus[10:0]};
    CDR_B <= !Z80A_WR & !(CDR3RQ & CDR6RQ);
    CDR_G <= !Z80A_WR & !(CDR2RQ & CDR5RQ);
    CDR_R <= !Z80A_WR & !(CDR1RQ & CDR4RQ);
//  end
end

dpram_dc #(.widthad_a(12)) U105_U104_RAM_2016 //VIDEO RAM
(
	.clock_a(clkm_48MHZ),
	.address_a(VRAM_ADDR), //!SELVRAM_B1
	.data_a(),
	.wren_a(1'b0),
	.q_a(CBD),
	
	.clock_b(clkm_32MHZ),
	.address_b(Z80A_VRAMB),
	.data_b(Z80A_databus_out),
	.wren_b(CDR_B),
	.q_b()
);

dpram_dc #(.widthad_a(12)) U107_U106_RAM_2016 //VIDEO RAM
(
	.clock_a(clkm_48MHZ),
	.address_a(VRAM_ADDR), //!SELVRAM_B1
	.data_a(),
	.wren_a(1'b0),
	.q_a(CGD),
	
	.clock_b(clkm_32MHZ),
	.address_b(Z80A_VRAMG),
	.data_b(Z80A_databus_out),
	.wren_b(CDR_G),
	.q_b()
);

dpram_dc #(.widthad_a(12)) U109_U108_RAM_2016 //VIDEO RAM
(
	.clock_a(clkm_48MHZ), //clkm_48MHZ
	.address_a(VRAM_ADDR), //!SELVRAM_B1
	.data_a(),
	.wren_a(1'b0),
	.q_a(CRD),
	
	.clock_b(clkm_32MHZ),
	.address_b(Z80A_VRAMR),
	.data_b(Z80A_databus_out),
	.wren_b(CDR_R),
	.q_b()
);

// VRAM address mux
reg [11:0] VRAM_ADDR;
reg        CINV;
always @(clkm_48MHZ) begin
    case (syncbus_HN[2:1])
        2'd0: begin VRAM_ADDR = {CCH3, CD_CHA}; CINV = HINV;     end
        2'd1: begin VRAM_ADDR = OBJ_CHA[11:0];  CINV = OBJ_CINV; end
        2'd2: begin VRAM_ADDR = {CCH1, CD_CHA}; CINV = HINV;     end
        2'd3: begin VRAM_ADDR = {CCH2, CD_CHA}; CINV = HINV;     end
    endcase
end

// Pixel bit reversal
assign CRDH = CINV ? {CRD[0],CRD[1],CRD[2],CRD[3],CRD[4],CRD[5],CRD[6],CRD[7]} : CRD;
assign CGDH = CINV ? {CGD[0],CGD[1],CGD[2],CGD[3],CGD[4],CGD[5],CGD[6],CGD[7]} : CGD;
assign CBDH = CINV ? {CBD[0],CBD[1],CBD[2],CBD[3],CBD[4],CBD[5],CBD[6],CBD[7]} : CBD;

always @(posedge PH45) begin //45 //syncbus_PH[4]
	SN11_in <= CRDH;
	SN12_in <= CGDH;
	SN13_in <= CBDH;
end

always @(posedge PH67) begin //67 //syncbus_PH[6]
	SN21_in <= CRDH;
	SN22_in <= CGDH;
	SN23_in <= CBDH;
end

always @(posedge PH01) begin //01 syncbus_PH[0]
	SN31_in <= CRDH;
	SN32_in <= CGDH;
	SN33_in <= CBDH;
end

ls166x3 CRGB1( //layer 1
	.clk(clkm_6MHZ),
	//.ce(clkm_6MHZ),
	.pinA(SN11_in),
	.pinB(SN12_in),
	.pinC(SN13_in),	
	.PE(SN1LD),
	.clr(SN1OFF),
	.QH(SN1)
);

ls166x3 CRGB2( //layer 2
	.clk(clkm_6MHZ),
	//.ce(clkm_6MHZ),
	.pinA(SN21_in),
	.pinB(SN22_in),
	.pinC(SN23_in),	
	.PE(SN2LD),
	.clr(SN2OFF),
	.QH(SN2)
);

ls166x3 CRGB3( //layer 3
	.clk(clkm_6MHZ),
	//.ce(clkm_6MHZ),
	.pinA(SN31_in),
	.pinB(SN32_in),
	.pinC(SN33_in),	
	.PE(SN3LD),
	.clr(SN3OFF),
	.QH(SN3)
);


reg BANK_SEL,SOUND_STOP,COIN_LOCK;

always @(posedge COIN_SET) begin
	BANK_SEL<=Z80A_databus_out[7];
	SOUND_STOP<=Z80A_databus_out[1];
	COIN_LOCK<=Z80A_databus_out[0];
end

//watchdog reset
always @(posedge V_BLANK or negedge TIME_RESET) reset_counter <= (!TIME_RESET) ? 8'd0 : reset_counter;
assign WD_RESET = !reset_counter[7];

//collision detection logic
assign OBJ =!(|OB[2:0]);
assign SCN1=!(|SN1[2:0]);
assign SCN2=!(|SN2[2:0]);
assign SCN3=!(|SN3[2:0]);

hit_bus HB(
	.clkm_6MHZ(clkm_6MHZ),
	.clkb_6MHZ(clkb_6MHZ),
	.OBJ(OBJ),
	.SCN1(SCN1),
	.SCN2(SCN2),
	.SCN3(SCN3),
	.HTCLR(HTCLR),
	.HLP0(HLP0),
	.HLP1(HLP1),
	.HLP2(HLP2),	
	.HITOB(HITOB),
	.HTRRQ(HTRRQ),
	.syncbus_HM(syncbus_HM),
	.ADDR_ED(Z80A_addrbus[1:0]),
	.HIT_DATA(HIT_DATA)
);

always @(posedge SMD12) {CCH2,MD2,CCH1,MD1}<=Z80A_databus_out; 	//D506
always @(posedge SMD3)  {MD0,CCH3,MD3}<= Z80A_databus_out[5:0];	//D507
always @(posedge PRY)   PRIORITY<=Z80A_databus_out[4:0];				//D300 - Priority Control
wire Z80A_BUSAK_OUT;

//First Z80 CPU responsible for main game logic
T80pa Z80A(
	.RESET_n(RESET_n&WD_RESET),
	.WAIT_n(wait_n/*&U91_wait_n*/),
	.INT_n(Z80A_INT), //Z80A_INT
	.BUSRQ_n(mcu_busrq_n),
	.NMI_n(PUR),
	.CLK(clkm_32MHZ), //clkm_32MHZ
	.CEN_p(clkm_4MHZ), //clkm_4MHZ
	.CEN_n(clkm_4MHZn), //clkm_4MHZn
	.MREQ_n(Z80A_MREQ),
	.IORQ_n(Z80A_IOREQ),
	.RFSH_n(Z80A_RFSH),
	.BUSAK_n(Z80A_BUSAK_OUT),
	.M1_n(Z80A_M1),
	.DI(Z80A_databus_in),
	.DO(Z80A_databus_out),
	.A(Z80A_addrbus_CPU),
	.WR_n(Z80A_WR),
	.RD_n(Z80A_RD)
);

// --- Z80 address bus mux: CPU or MCU DMA ---
wire [15:0] Z80A_addrbus_MCU;
wire [15:0] Z80A_addrbus_CPU;

always @(posedge clkm_4MHZ) Z80A_BUSAK<=Z80A_BUSAK_OUT;

assign Z80A_addrbus = Z80A_BUSAK ? Z80A_addrbus_CPU : Z80A_addrbus_MCU;

// =============================================================================
// Z80 ↔ MCU address decode
// Active-HIGH strobes generated from Z80 bus signals.
// MCU address space: $8800-$8FFF (!MCU asserted)
// =============================================================================
wire mcu_zlread_n  = !(!MCU & !Z80A_MREQ & Z80A_RFSH & !Z80A_RD &  Z80A_WR & !Z80A_addrbus[0]); // Z80 reads  $8800
wire mcu_zstatus_n = !(!MCU & !Z80A_MREQ & Z80A_RFSH & !Z80A_RD &  Z80A_WR &  Z80A_addrbus[0]); // Z80 reads  $8801
wire mcu_zlwrite_n = !(!MCU & !Z80A_MREQ & Z80A_RFSH &  Z80A_RD & !Z80A_WR & !Z80A_addrbus[0]); // Z80 writes $8800
wire mcu_zintrq_n  = !(!MCU & !Z80A_MREQ & Z80A_RFSH &  Z80A_RD & !Z80A_WR &  Z80A_addrbus[0]); // Z80 writes $8801

// =============================================================================
// MC68705P3 Soft-Core MCU
// =============================================================================
wire [7:0] mcu_port_a_out, mcu_port_a_in;
wire [7:0] mcu_port_b_out;
wire [7:0] mcu_port_c_out, mcu_port_c_in;
wire [7:0] mcu_port_a_ddr, mcu_port_b_ddr;
wire [7:0] mcu_port_c_ddr;
wire [7:0] mcu_port_b_in;
wire [10:0] mcu_rom_addr;
wire [7:0]  mcu_rom_data;
wire mcu_int_n;

mc68705p3 MCU68705(
    .clk        (clkm_48MHZ),
    .ce         (clkb_750HZ),
    .reset      (!RESET_n|!pcb[2]),	  // hold in reset if no MCU configured

    .int_n      (mcu_int_n),          // from glue: 68ACCEPT

    .port_a_out (mcu_port_a_out),
    .port_a_in  (mcu_port_a_in),      // from glue: latch or DMA data
    .port_a_ddr (mcu_port_a_ddr),

    .port_b_out (mcu_port_b_out),
    .port_b_in  (mcu_port_b_in),
    .port_b_ddr (mcu_port_b_ddr),

    .port_c_out (mcu_port_c_out),
    .port_c_in  (mcu_port_c_in),      // from glue: ZREADY, ZACCEPT, BUSAK
    .port_c_ddr (mcu_port_c_ddr),

    .rom_addr   (mcu_rom_addr),
    .rom_data   (mcu_rom_data)
);

// Port B input: effective pin levels considering DDR
// DDR=1 (output): reads back output register
// DDR=0 (input): pulled HIGH by external pull-ups
assign mcu_port_b_in = (mcu_port_b_out & mcu_port_b_ddr) | (~mcu_port_b_ddr);

// =============================================================================
// Glue Logic — schematic UMCU_7x, UMCU_9/10/11/13, UMCU_18A, UMCU_23x, UMCU_21x
// =============================================================================
wire [7:0]  mcu_bs_dout;             // Z80 reads from $8800/$8801
wire        mcu_busrq_n;            // Bus request → Z80
wire        mcu_z80_int_n;          // Qualified VBLANK → Z80 ~INT
wire [15:0] mcu_dma_addr;           // DMA address
wire [7:0]  mcu_dma_wdata;          // DMA write data
wire        mcu_dma_wr;             // DMA write enable
wire        mcu_dma_active;         // bus mastered
wire [7:0]  mcu_dma_rdata;          // DMA read data (from mux below)

mcu_z80_glue GLUE(
    .clk            (clkm_48MHZ),
    .reset_n        (RESET_n),

    // MCU ports
    .port_a_out     (mcu_port_a_out),
    .port_b_out     (mcu_port_b_out),
    .port_b_ddr     (mcu_port_b_ddr),
    .port_c_out     (mcu_port_c_out),

    // Z80 bus decode
    .zlread_n       (mcu_zlread_n),
    .zlwrite_n      (mcu_zlwrite_n),
    .zstatus_n      (mcu_zstatus_n),
    .zintrq_n       (mcu_zintrq_n),

    // Z80 data & control
    .z80_dout       (Z80A_databus_out),
    .busak_n        (Z80A_BUSAK),
    .m1_n           (Z80A_M1),
    .iorq_n         (Z80A_IOREQ),
    .cpuint_n       (rZ80A_INT),

    // DMA read data from address mux
    .dma_rdata      (mcu_dma_rdata),

    // Outputs → MCU port inputs
    .port_a_in      (mcu_port_a_in),
    .port_c_in      (mcu_port_c_in),

    // Outputs → Z80
    .z80_rdata      (mcu_bs_dout),
    .busrq_n        (mcu_busrq_n),
    .z80_int_n      (mcu_z80_int_n),
    .mcu_int_n      (mcu_int_n),

    // Outputs → DMA
    .dma_addr       (mcu_dma_addr),
    .dma_wdata      (mcu_dma_wdata),
    .dma_wr         (mcu_dma_wr),
    .dma_active     (mcu_dma_active)
);

// Route MCU DMA address to Z80 address bus when bus is mastered
assign Z80A_addrbus_MCU = mcu_dma_addr;

// =============================================================================
// MCU DMA Read Data Mux — full Z80 address space decode
// =============================================================================
wire MCU_SRAMREQ = (mcu_dma_addr[15:11] == 5'b10000);  // $8000-$87FF

wire [7:0] mcu_ram_rdata;  // from work RAM port B q_b

reg [7:0] mcu_dma_rdata_mux;
always @(*) begin
    casez (mcu_dma_addr[15:11])
        5'b0????: mcu_dma_rdata_mux = BANK_SEL ? Z80A_BROM_out : Z80A_MROM_out; // $0000-$7FFF ROM
        5'b10000: mcu_dma_rdata_mux = mcu_ram_rdata;                              // $8000-$87FF RAM
        5'b10010, 5'b10011, 5'b10100, 5'b10101, 5'b10110, 5'b10111:
                  mcu_dma_rdata_mux = 8'hFF;                                      // $9000-$BFFF VRAM (no port B)
        5'b1100?: mcu_dma_rdata_mux = Z80A_CPU_CD_data;                           // $C000-$CFFF Tilemap
        5'b11010: begin
            casez (mcu_dma_addr[10:8])
                3'b000: mcu_dma_rdata_mux = Z80A_SCD_data_out;                    // $D000-$D0FF Scroll
                3'b001: mcu_dma_rdata_mux = Z80A_OD_out;                          // $D100-$D1FF Objects
                3'b100: begin                                                      // $D400-$D4FF I/O
                    case (mcu_dma_addr[3:0])
                        4'h8: mcu_dma_rdata_mux = INPUT0X;
                        4'h9: mcu_dma_rdata_mux = INPUT1X;
                        4'hA: mcu_dma_rdata_mux = DIPSWA;
                        4'hB: mcu_dma_rdata_mux = INPUT3X;
                        4'hC: mcu_dma_rdata_mux = INPUT4X;
                        4'hD: mcu_dma_rdata_mux = INPUT5X;
                        default: mcu_dma_rdata_mux = 8'hFF;
                    endcase
                end
                default: mcu_dma_rdata_mux = 8'hFF;
            endcase
        end
        5'b111??: mcu_dma_rdata_mux = MCU_ROM_out;                                // $E000-$FFFF MCU board ROM
        default:  mcu_dma_rdata_mux = 8'hFF;
    endcase
end

assign mcu_dma_rdata = mcu_dma_rdata_mux;


eprom_mcu mcu_rom(	
	.ADDR(mcu_rom_addr),
	.CLK(clkm_48MHZ),//
	.DATA(mcu_rom_data),//

	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),//
	.DATA_IN(dn_data),
	.CS_DL(ep5_cs_i),
	.WR(dn_wr)
);

// E000 ROM - Z80-accessible ROM on MCU daughter board ($E000-$EFFF)
extra_rom mcu_board_e000_rom(
	.ADDR(Z80A_addrbus[11:0]),
	.CLK(clkm_48MHZ),
	.DATA(MCU_ROM_out),

	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),
	.DATA_IN(dn_data),
	.CS_DL(ep6_cs_i),
	.WR(dn_wr)
);

wire [9:0] sound_outAY1;
wire [9:0] sound_outAY2;
wire [9:0] sound_outAY3;
wire AY_1_sample;
wire AY_2_sample;
wire AY_3_sample;
wire [7:0] AY1_IOA_out,AY2_IOA_out;

game_sound EXT_SOUND(
	//clocks
	.clkm_48MHZ(clkm_48MHZ),			//master clock
	.clkm_32MHZ(clkm_32MHZ),
	.clkm_3MHZ(clkm_3MHZ),			//sound CPU clock
	.clkb_3MHZ(clkb_3MHZ),
	.clkm_1p5MHZ(clkm_1p5MHZ),		//AY clock
	
	//control inputs
	.nSND_RST(RESET_n),

	.EPORT1(EPORT1),
	.EPORT2(EPORT2),
	
	//ROM download handling
	.CPU_ADDR(Z80A_addrbus),
	.CPU_DIN(Z80A_databus_out),
	.dn_addr(dn_addr),
	.dn_data(dn_data),
	.snd_prom_cs_i(ep3_cs_i),
	.dn_wr(dn_wr),

	.pause(pause),
	
	.sound_outAY1(sound_outAY1),
	.sound_outAY2(sound_outAY2),
	.sound_outAY3(sound_outAY3),
	.AY_1_sample(AY_1_sample),
	.AY_2_sample(AY_2_sample),
	.AY_3_sample(AY_3_sample),
	.AY1_IOA_out(AY1_IOA_out),
	.AY2_IOA_out(AY2_IOA_out)

);

always @(posedge PROT_SEL) PROT_DATA<=PROT_DATA^8'hFF; //space cruiser protection

//Z80A - Vertical Blank Interrupt
assign INT_RST = Z80A_IOREQ|Z80A_M1;
always @(posedge V_BLANK or negedge INT_RST) begin
	rZ80A_INT <= (!INT_RST) 				? 1'b1 : 1'b0;
end

assign Z80A_INT = mcu_z80_int_n;

//main CPU (Z80A) work RAM - dual port RAM for MCU which prevents hi-score logic with this implementation
dpram_dc #(.widthad_a(11)) U14_RAM_2016 //SJ
(
	.clock_a(clkm_32MHZ),
	.address_a(Z80A_addrbus[10:0]),
	.data_a(Z80A_databus_out),
	.wren_a(!Z80A_WR & SRAMREQ),
	.q_a(Z80A_RAM_out),

	.clock_b(clkm_48MHZ),						//MCU DMA
	.address_b(mcu_dma_addr[10:0]),
	.data_b(mcu_dma_wdata),
	.wren_b(mcu_dma_wr & mcu_dma_active & MCU_SRAMREQ),
	.q_b(mcu_ram_rdata)
);

//Scroll RAM for Kick Start
dpram_dc #(.widthad_a(11)) UXX_RAM_2016 //SJ
(
	.clock_a(clkm_32MHZ),
	.address_a(Z80A_addrbus[10:0]),
	.data_a(Z80A_databus_out),
	.wren_a(!Z80A_WR & SCRAM),
	.q_a(Z80A_SCRAM_out),

	//.clock_b(clkm_48MHZ),						//MCU DMA
	//.address_b(mcu_dma_addr[10:0]),
	//.data_b(mcu_dma_wdata),
	//.wren_b(mcu_dma_wr & mcu_dma_active & MCU_SRAMREQ),
	//.q_b(mcu_ram_rdata)
);

//Z80A CPU main program program ROM #1 - This is a combination of all of the program ROMs 
eprom_0 Z80A_MAIN_PROGRAMROMS
(
	.ADDR(Z80A_addrbus[14:0]),
	.CLK(clkm_48MHZ),//
	.DATA(Z80A_MROM_out),//
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),//
	.DATA_IN(dn_data),
	.CS_DL(ep0_cs_i),
	.WR(dn_wr)
);

eprom_1 Z80A_BANK_PROGRAMROMS
(
	.ADDR(Z80A_addrbus[14:0]),
	.CLK(clkm_48MHZ),//
	.DATA(Z80A_BROM_out),//
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),//
	.DATA_IN(dn_data),
	.CS_DL(ep1_cs_i),
	.WR(dn_wr)
);


sync_bus syncbus(
	//clocks
	.clkm_48MHZ(clkm_48MHZ),
	.clkm_6MHZ(clkm_6MHZ),			//pixel clock
	.clkb_6MHZ(clkb_6MHZ),			//master clock	
	.RESET_n(RESET_n),
	.SPH1(SPH1),
	.SPH2(SPH2),
	.SPH3(SPH3),	
	.VINV(VINV),
	.HINV(HINV),	
	.Z80A_DATABUS(Z80A_databus_out),
	
	.SB_HN(syncbus_HN), 				//128HN=[7],64=[6],32=[5],16=[4],8=[3],4=[2],2=[1],1HN=[0]
	.SB_H(syncbus_H), 				//syncbus_H = 128H=[7],64=[6],32=[5],16=[4],8=[3],4=[2],2=[1],1H=[0]
	.SB_HM(syncbus_HM),
	.SB_V(syncbus_V),					//128V=[7],64V=[6],32V=[5],16V=[4],8V=[3],4V=[2],2V=[1],1V=[0]
	.PH(syncbus_PH),
	.VSYNC(V_SYNC),
	.HSYNC(H_SYNC),
	.VBL(V_BLANK),						//V.BL
	.HBL(H_BLANK),						//H.BL
	.BLANK(BLANK),
	.SN1LD(SN1LD),
	.SN2LD(SN2LD),
	.SN3LD(SN3LD),
	.PH01(PH01),	
	.PH23(PH23),
	.PH45(PH45),
	.PH67(PH67),
	.HLP0(HLP0),
	.HLP1(HLP1),	
	.HLP2(HLP2)	
);

//Horizontal Scroll
always @(posedge SPH3) DHPH5 <= Z80A_databus_out[7:3];
always @(posedge SPH2) DHPH3 <= Z80A_databus_out[7:3];
always @(posedge SPH1) DHPH1 <= Z80A_databus_out[7:3];

assign DH=	(!syncbus_PH[7]) ? DHPH5 :				//phases switched to match vertical
				(!syncbus_PH[5]) ? DHPH3 :				//when used in address generation
				(!syncbus_PH[3]) ? DHPH1 : 5'b00000;				
assign DH2=	(!syncbus_PH[5]) ? DHPH5 :				//phases switched to match original setting
				(!syncbus_PH[3]) ? DHPH3 :				//when used in scroll ram address generation
				(!syncbus_PH[1]) ? DHPH1 : 5'b00000;				

assign HORZBITS =syncbus_H[7:3]+DH;			//this is kind of a 'hack' as two parts of the circuitry need these values
assign HORZBITS2=syncbus_H[7:3]+DH2;      //at seperate times

//Vertical Scroll
always @(posedge SPV3) DVPH7 <= Z80A_databus_out[7:0];
always @(posedge SPV2) DVPH5 <= Z80A_databus_out[7:0];
always @(posedge SPV1) DVPH3 <= Z80A_databus_out[7:0];

assign DV=	(!syncbus_PH[7]) ? DVPH7 ://7
				(!syncbus_PH[5]) ? DVPH5 ://5
				(!syncbus_PH[3]) ? DVPH3 : 8'b00000000;//3

assign VERTBITS=syncbus_V[7:0]+S_DATA[7:0]+DV;

dpram_dc #(.widthad_a(12)) U5756 //SJ
(
	.clock_a(clkm_48MHZ),
	.address_a({syncbus_HN[2:1],VERTBITS[7:3],HORZBITS[4:0]}), 
	.data_a(),
	.wren_a(1'b0),
	.q_a(CD_out),
	
	.clock_b(clkm_32MHZ),
	.address_b(Z80A_addrbus[11:0]),
	.data_b(Z80A_databus_out),
	.wren_b(!Z80A_WR & !CHARQ),
	.q_b(Z80A_CPU_CD_data)
);


//------------------------------------------------- MiSTer data write selector -------------------------------------------------//
//Instantiate MiSTer data write selector to generate write enables for loading ROMs into the FPGA's BRAM
wire ep0_cs_i, ep0b_cs_i, ep1_cs_i, ep2_cs_i, ep3_cs_i, ep4_cs_i, ep5_cs_i, ep6_cs_i, ep7_cs_i, ep8_cs_i,ep9_cs_i,ep10_cs_i,ep11_cs_i,ep12_cs_i,ep13_cs_i,cp1_cs_i,cp2_cs_i,cp3_cs_i;

selector DLSEL
(
	.ioctl_addr(dn_addr),
	.ep0_cs(ep0_cs_i),
	.ep1_cs(ep1_cs_i),
	.ep2_cs(ep2_cs_i),
	.ep3_cs(ep3_cs_i),
	.ep4_cs(ep4_cs_i),
	.ep5_cs(ep5_cs_i),
	.ep6_cs(ep6_cs_i),
	.ep7_cs(ep7_cs_i),	
	.ep8_cs(ep8_cs_i),
	.ep9_cs(ep9_cs_i),	
	.ep10_cs(ep10_cs_i),
	.ep11_cs(ep11_cs_i),
	.ep12_cs(ep12_cs_i),
	.ep13_cs(ep13_cs_i),
	.cp1_cs(cp1_cs_i),
	.cp2_cs(cp2_cs_i),
	.cp3_cs(cp3_cs_i)	
);

dpram_dc #(.widthad_a(8)) U7273 //SJ
(
	.clock_a(clkm_48MHZ),
	.address_a({1'b0,syncbus_HN[2:1],HORZBITS2[4:0]}), //4=[2],2=[1]
	.data_a(),
	.wren_a(1'b0),
	.q_a(SCD),
	
	.clock_b(clkm_32MHZ),
	.address_b(Z80A_addrbus[7:0]),
	.data_b(Z80A_databus_out),
	.wren_b(!Z80A_WR & !SCRRQ),
	.q_b(Z80A_SCD_data_out)
);

wire sbclk_n=~syncbus_HN[0];

always @(posedge sbclk_n) begin
	S_DATA 			<=	SCD;
	CD_CHA[10:0]	<=	{CD_out,VERTBITS[2:0]};
end

//object data bus (sprite renderer)
obj_bus TSJ_OBJ_BUS(
	//clocks
	.clkm_48MHZ(clkm_48MHZ),
	.clkm_32MHZ(clkm_32MHZ),	
	.clkm_6MHZ(clkm_6MHZ),			//master clock
	.clkb_6MHZ(clkb_6MHZ),	
	//inputs
	.syncbus_HN(syncbus_HN),			//128HN=[7],64=[6],32=[5],16=[4],8=[3],4=[2],2=[1],1HN=[0]
	.syncbus_PH(syncbus_PH),	
	.syncbus_V(syncbus_V),				//128V=[7],64V=[6],32V=[5],16V=[4],8V=[3],4V=[2],2V=[1],1V=[0]
	.Z80A_addrbus(Z80A_addrbus),
	.Z80A_databus_out(Z80A_databus_out),
	.Z80A_WR(Z80A_WR),
	.OBJRQ(OBJRQ),
	.SOFF(SOFF),
	.VRAMR(CRDH),
	.VRAMG(CGDH),
	.VRAMB(CBDH),	
	//outputs
	.OBJ_CHA(OBJ_CHA), 		
	.Z80A_OD_out(Z80A_OD_out),
	.OBJ_CINV(OBJ_CINV),

	.SN3OFF(SN3OFF),
	.SN2OFF(SN2OFF),
	.SN1OFF(SN1OFF),
	.VINV(VINV),
	.HINV(HINV),
	.HITOB(HITOB),
	.OB(OB),

);



//START: *********** External Graphic ROM board ************ 
always @(posedge EXROM1) D509<=Z80A_databus_out;
always @(posedge EXROM2) D50A<=Z80A_databus_out;
assign EXT_ROM_ADDR={D50A[6:0],D509}+EX_COUNTER;
always @(posedge EXRHR or negedge EXROM2) EX_COUNTER <=(!EXROM2) ? 15'd0:EX_COUNTER+1;

eprom_2 EXT_ROM
(
	.ADDR({EXT_ROM_ADDR}),
	.CLK(clkm_48MHZ),//
	.DATA(EXT_DATA),//
	
	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),//
	.DATA_IN(dn_data),
	.CS_DL(ep2_cs_i),
	.WR(dn_wr)
);
//END: *********** External Graphic ROM board ************ 



always @(posedge EXPORT) begin
	case (Z80A_databus_out) 
		8'h05: 	ALP_PROT<=8'h18;
		8'h07: 	ALP_PROT<=8'h00;
		8'h0C: 	ALP_PROT<=8'h00;
		8'h0F: 	ALP_PROT<=8'h00;		
		8'h16: 	ALP_PROT<=8'h08;		
		8'h1D: 	ALP_PROT<=8'h18;	
		default: ALP_PROT<=Z80A_databus_out;	
	endcase
end
	
//Input BUS & Dip Switches - off=1
wire [7:0] INPUT5X = {AY2_IOA_out[7:4],4'b1111}; 
wire [7:0] INPUT4X = {3'b111,~m_service,m_gunup,m_gundn,m_gunright,m_gunleft}; //44 & 45 were the RILT & SERV
wire [7:0] INPUT3X = pcb[1] ? ({m_start2p,m_start1p,m_coina,ALP_PROT[4:1],m_coinb}) : {m_start2p,m_start1p,m_coina,m_coinb,4'b0000}; //34 & 35 are coin B &c? //31 hard grounded WAS '4b1101
wire [7:0] DIPSWA  = DIP1; 
wire [7:0] INPUT1X = 8'b11111111; 
wire [7:0] INPUT0X = {2'b10,m_shoot2,m_shoot,m_up,m_down,m_right,m_left}; //IN06 hard grounded
wire [7:0] DIPSWB  = DIP2; 
wire [7:0] DIPSWC  = DIP3;

wire AY_0_BDIR,AY_0_BC1,AY_0_SEL,AY_0_sample;
wire [7:0] AY_0_databus_out;
wire [9:0] sound_outAY0;

assign AY_0_BDIR=AY_0_SEL&!Z80A_WR;
assign AY_0_BC1 =AY_0_SEL&!Z80A_addrbus[0]&!Z80A_WR;
wire 	 nSND_RST=1'b1;
wire signed [15:0] audio_snd;
wire signed [15:0] audio_snd_ext;

jt49_bus AY_0(
    .rst_n(RESET_n),
    .clk(clkm_48MHZ),						// signal on positive edge
    .clk_en(clkm_1p5MHZ),  				/* synthesis direct_enable = 1 */
    
    .bdir(AY_0_BDIR),	 					// bus control pins of original chip
    .bc1(AY_0_BC1),
	 .din(Z80A_databus_out),
    .sel(1'b1), 								// if sel is low, the clock is divided by 2
    .dout(AY_0_databus_out),
    
	 .sound(sound_outAY0),  				// combined channel output
    .A(),      								// linearised channel output
    .B(),
    .C(),
    .sample(AY_0_sample),

    .IOA_in(DIPSWB),							//Dip Switch B
    .IOB_in(DIPSWC)							//Dip Switch C
);

jtframe_jt49_filters u_filters1(
            .rst    ( !nSND_RST    ),
            .clk    ( clkm_48MHZ   ),
            .din0   ( sound_outAY0 ),
            .din1   ( sound_outAY3 ), //sound_outAY3 - {1'b0,AY1_IOA_out,1'b0}
				.din2   ( {2'b0,AY1_IOA_out} ), 
            .sample ( AY_0_sample  ),
            .dout   ( audio_snd    )
);

jtframe_jt49_filters u_filters2(
            .rst    ( !nSND_RST    ),
            .clk    ( clkm_48MHZ   ),
            .din0   ( sound_outAY1 ),
            .din1   ( sound_outAY2 ),
            .din2   ( ),				
            .sample ( AY_1_sample  ),
            .dout   ( audio_snd_ext)
);

assign audio_l = (pause) ? 16'd0 : audio_snd;
assign audio_r = (pause) ? 16'd0 : audio_snd_ext;

eprom_4 EB16(
	.ADDR({PRIORITY[3:0],SCN3,SCN2,SCN1,OBJ}),
	.CLK(clkm_48MHZ),//
	.DATA(EB16_out),//

	.ADDR_DL(dn_addr),
	.CLK_DL(clkm_48MHZ),//
	.DATA_IN(dn_data),
	.CS_DL(ep4_cs_i),
	.WR(dn_wr)
);


wire [1:0] sel = PRIORITY[4] ? EB16_out[3:2] : EB16_out[1:0];
wire [5:0] ma0 = {MD0, OB[3:0]};    // Sprites
wire [5:0] ma1 = {MD1, SN1[2:0]};   // Tile Map 1
wire [5:0] ma2 = {MD2, SN2[2:0]};   // Tile Map 2
wire [5:0] ma3 = {MD3, SN3[2:0]};   // Tile Map 3
wire [3:0] onehot = 4'b0001 << sel;
wire [5:0] next_ma = ({6{onehot[0]}} & ma0) | ({6{onehot[1]}} & ma1) | ({6{onehot[2]}} & ma2) | ({6{onehot[3]}} & ma3);

always @(posedge clkm_6MHZ) MA <= next_ma;

reg U46A_Q;

wire wr_stb = Z80A_addrbus[0] | VCRRQ | Z80A_WR;  // async strobe - final bit of color data
reg wr_d1;
always @(posedge clkm_6MHZ) begin            
  wr_d1 <= wr_stb;                     
  if (wr_stb & ~wr_d1)                 // rising-edge detect 
    U46A_Q <= Z80A_databus_out[0];
end

dpram_dc #(.widthad_a(6),.width_a(16)) U67_RAM //SJ - using 16-bit memory for 9-bit
(
	.clock_a(clkm_48MHZ),
	.address_a(MA),
	.data_a(),
	.wren_a(1'b0),
	.q_a(RGB),
	
	.clock_b(clkm_32MHZ),
	.address_b(Z80A_addrbus[6:1]),
	.data_b({7'b0000000,U46A_Q,Z80A_databus_out}),
	.wren_b(!Z80A_WR & !VCRRQ),
	.q_b()
);

//no blanking logic
wire U68B=!BLANK & VCRRQ;

always @(posedge clkm_6MHZ or negedge U68B) begin
	if (!U68B) begin
		RED	<=	3'b000;
		GREEN	<=	3'b000;
		BLUE	<=	3'b000;
	end
	else begin
		RED	<=	~RGB[8:6];
		GREEN	<=	~RGB[5:3];
		BLUE	<=	~RGB[2:0];
	end
end	
endmodule