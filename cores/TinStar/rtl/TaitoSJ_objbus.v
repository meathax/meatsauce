module obj_bus (
	//clocks
	input clkm_48MHZ,
	input clkm_32MHZ,	
	input clkm_6MHZ,					//pixel clock
	input clkb_6MHZ,			
	//inputs
	input [8:0] syncbus_HN,			//H.BL=![8],HBL=[8],128HN=[7],64=[6],32=[5],16=[4],8=[3],4=[2],2=[1],1HN=[0]
	input [7:0] syncbus_PH,	
	input [7:0] syncbus_V,			//128V=[7],64V=[6],32V=[5],16V=[4],8V=[3],4V=[2],2V=[1],1V=[0]
	input [15:0] Z80A_addrbus,
	input [7:0] Z80A_databus_out,
	input Z80A_WR,
	input OBJRQ,
	input SOFF,

	input [7:0] VRAMR,
	input [7:0] VRAMG,
	input [7:0] VRAMB,
	//outputs
	output [12:0] OBJ_CHA, 			//extra 2 bits bit 12 for syncing, bit 11 for OBJCH
	output [7:0] Z80A_OD_out,
	output OBJ_CINV,

	output reg SN3OFF,
	output reg SN2OFF,
	output reg SN1OFF,
	output reg VINV,
	output reg HINV,
	output HITOB,
	output reg [3:0] OB	

);

//internal registers
reg  [7:0] QX_bus,OD_L1,OD_L2;
reg OBJOFF,OBJEX,OMD,VINVx,HINVx,SDUMMY,LNSL1,LNSL2,line_clock,LNSL;
wire OMD1,OD1_PH7,OBJCH;

always @(posedge SOFF) {OBJOFF,SN3OFF,SN2OFF,SN1OFF,SDUMMY,OBJEX,VINVx,HINVx} = Z80A_databus_out; //U32 internal to object bus
//This ram stores the sprite location, sprite index and additional attributes.
//The ram is written to once per line by the Z80 and read and sent to the sprite
//hardware based on the scan-line horizontal position
wire [7:0] OD;

dpram_dc #(.widthad_a(8), .instance_name("OBJ_RAM")) U1817_RAM //SJ - object data ram - 256 bytes
(
	.clock_a(clkm_48MHZ),
	.address_a({OBJEX,!syncbus_HN[8],syncbus_HN[7:4],!syncbus_HN[2],syncbus_HN[1]}),
	.data_a(),
	.wren_a(1'b0),
	.q_a(OD),
	
	.clock_b(clkm_32MHZ),
	.address_b({Z80A_addrbus[7:2],(Z80A_addrbus[1]^!Z80A_addrbus[0]),!Z80A_addrbus[0]}),
	.data_b(Z80A_databus_out),
	.wren_b(!Z80A_WR & !OBJRQ),
	.q_b(Z80A_OD_out)
);

/*
RAM ORDER:
	
	Z80 (0), RAM (3) = X POSITION
	Z80 (1), RAM (0) = Y POSITION
	Z80 (2), RAM (1) = ATTRIBUTES
	Z80 (3), RAM (2) = TILE CODE

RENDER ORDER:

	HPIX[2:0] = (0,1), RAM (2), TILE CODE
	HPIX[2:0] = (2,3), RAM (3), X POSITION
	HPIX[2:0] = (4,5), RAM (0), Y POSITION
	HPIX[2:0] = (6,7), RAM (1), ATTRIBUTES
*/

(* preserve *) reg [7:0] OD_PH1,OD_PH5,OD_PH7;

//capture OD in 'Phase 1' once per horizontal slice of sprite (everything else is captured every 8 pixels)
wire syncph1 = (syncbus_HN[3:0] == 4'b1010);

// Synchronous rising-edge detection at 48MHz — avoids using combinatorial
// or non-clock-network signals as clocks, which caused timing-dependent
// corruption of the 2nd half of sprites (OBJ_CINV / tile half select).
reg syncph1_d, ph3_d, ph5_d, ph7_d, hn3_d, line_clock_d, LNSL_CLK_d;

always @(posedge clkm_48MHZ) begin
   syncph1_d    <= syncph1;
   ph3_d        <= syncbus_PH[3];
   ph5_d        <= syncbus_PH[5];
   ph7_d        <= syncbus_PH[7];
   hn3_d        <= syncbus_HN[3];
   line_clock_d <= line_clock;
   LNSL_CLK_d       <= LNSL_CLK;
	 
   if (syncph1_rise) OD_PH1 <= OD;
   if (ph5_rise)     OD_PH5 <= OD + syncbus_V + 8'd1; // C0=1: 74LS83 carry-in unconnected, floats HIGH on hardware  + 1
   if (ph7_rise)     OD_PH7 <= OD;	 
	 
	if (ph3_rise) begin
		OMD<=OMD1;
		VINV<=VINVx;
		HINV<=HINVx;
	end

	if (line_clock_fall) LNSL <= syncbus_V[0]; 
	  
	if (LNSL_CLK_rise) begin
		LNSL1<= LNSL;
		LNSL2<=!LNSL;
	end	  

	if (syncbus_HN[8] | hn3_rise) line_clock <= syncbus_HN[8] | ~(&syncbus_HN[6:4]); 
	
end
	 
wire syncph1_rise    = syncph1       & ~syncph1_d;
wire ph3_rise        = syncbus_PH[3] & ~ph3_d;
wire ph5_rise        = syncbus_PH[5] & ~ph5_d;
wire ph7_rise        = syncbus_PH[7] & ~ph7_d;
wire hn3_rise        = syncbus_HN[3] & ~hn3_d;
wire line_clock_fall = ~line_clock   & line_clock_d;
wire LNSL_CLK_rise   = LNSL_CLK          & ~LNSL_CLK_d;

// Hardware: ~OBJRQ connects to ~MR (pin 1) of U83 74LS273, acting as
// asynchronous master reset.  When Z80 accesses $D1xx, register clears.
// CLK (pin 11) = ~PH5 — register latches on FALLING edge of PH5.
// D0-D7 = adder sum[0:7] (low adder S1-S4 → D0-D3, high adder S1-S4 → D4-D7).
assign	{OMD1,OD1_PH7,OBJ_CINV}      = OD_PH7[2:0];

//build VRAM address for sprite usage
//*OBJECT CHA/DATABUS - Creates object RAM addresses loaded into CHA during PH3
assign	OBJ_CHA={1'b0,OD_PH1[6:0],OD_PH5[3]^OD1_PH7,(syncbus_HN[3] ~^ OBJ_CINV),OD_PH5[2:0]^ {3{OD1_PH7}}};

wire	PHA348	=	!syncbus_HN[3]|(|syncbus_PH[4:3]); 	//PHA348 (U39D)
wire	LNCL 		=	PHA348|line_clock; 						//Line Clear (U39C)
wire	LNSL_CLK	=	LNCL|clkm_6MHZ;							//Line Select Clock (U19B)

wire 	LNCL1=!LNSL | LNCL; 		//Clear Line Buffer #1 Trigger
wire 	LNCL2= LNSL | LNCL; 		//Clear Line Buffer #2 Trigger

wire 	LNLD2=!LNSL | PHA348; 	//Load Data into Line Buffer #1 Trigger
wire  LNLD1= LNSL | PHA348; 	//Load Data into Line Buffer #2 Trigger

wire 	[7:0] nOD_L1=OD_L1+8'd1;//Line Buffer #1 Address Counter
wire 	[7:0] nOD_L2=OD_L2+8'd1;//Line Buffer #2 Address Counter

always @(posedge clkm_6MHZ)  begin
	OD_L1 <= (!LNCL1) ? 8'd0 : (!LNLD1) ? OD : nOD_L1;
	OD_L2 <= (!LNCL2) ? 8'd0 : (!LNLD2) ? OD : nOD_L2;
end

// Precompute cheap reductions once
wire 	qx_lo_zero   = ~|QX_bus[2:0];
wire 	qx_hi_zero   = ~|QX_bus[6:4];
wire 	qbus_lo_zero = ~|QBUS[2:0];

// Shared object-hit term
wire 	objh = LNSL1 ? qx_hi_zero : qx_lo_zero;

assign INRANG = !(&OD_PH5[7:4]); 			//sprite 'inrange' (render)
wire CRGBO_pe = |syncbus_PH[4:3]|INRANG; 	//load sprite data

ls166x3 CRGBO( //sprites / objects
	.clk(clkm_6MHZ),
	.pinA(VRAMR),
	.pinB(VRAMG),
	.pinC(VRAMB),	
	.PE(CRGBO_pe),//|OBJ_CHA[12]  PHA34 //syncbus_PH[3]|
	.clr(1'b1), //enabled sprites
	.QH(QBUS)
);

wire [2:0] QBUS; //= {QoutC[0], QoutB[0], QoutA[0]};
	 
// Common 4-bit bus
wire [3:0] bus_in = {OMD, QBUS[2:0]};

// Line Buffer Data Lines
wire [3:0] LBUF1_DATA_IN = LNSL1 ? 4'b0000 : (objh ? bus_in : QX_bus[3:0]);
wire [3:0] LBUF2_DATA_IN = LNSL2 ? 4'b0000 : (objh ? bus_in : QX_bus[7:4]);
wire [3:0] LBUF1_DATA_OUT,LBUF2_DATA_OUT;

//Line Buffer Address
wire [7:0] LBUF1_ADDR=(LNSL1&HINV) ? ~OD_L1:OD_L1;
wire [7:0] LBUF2_ADDR=(LNSL2&HINV) ? ~OD_L2:OD_L2;

//line #1 buffer
m5501_ram U69_RAM(
	.data(LBUF1_DATA_IN),
	.clk(clkm_48MHZ),//clkm_48MHZ
	.addr(LBUF1_ADDR),
	.nWE(clkb_6MHZ),
	.q(LBUF1_DATA_OUT)
);

//line #2 buffers
m5501_ram U41_RAM(
	.data(LBUF2_DATA_IN),
	.clk(clkm_48MHZ), //clkm_48MHZ
	.addr(LBUF2_ADDR),
	.nWE(clkb_6MHZ),
	.q(LBUF2_DATA_OUT)
);

always @(posedge clkb_6MHZ or negedge OBJOFF) begin
    if (!OBJOFF) QX_bus <= 8'b0;
    else         QX_bus <= {LBUF2_DATA_OUT,LBUF1_DATA_OUT};
end

always @(posedge clkm_6MHZ) OB <= (LNSL2)	? QX_bus[7:4] : QX_bus[3:0]; 

assign HITOB = qbus_lo_zero | objh;		//Hitbus OR
	
endmodule
