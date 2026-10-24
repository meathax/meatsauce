reg jsr_en;
reg [11:0] jsr_ua, jsr_ret, uaddr;

// wire [1:0] bcd_sel;
// wire [3:0] alu_sel;
// wire [1:0] carry_sel;
// wire [3:0] cc_sel;
// wire [1:0] ea_sel;
// wire [4:0] jsr_sel;
// wire [3:0] ld_sel;
// wire [1:0] opnd_sel;
// wire [3:0] rmux_sel;

// wire       halt;
// wire       brcy;
// wire       branch;
// wire       brlatch;
// wire       fetch;
// wire       nobr;
// wire       wr;
// wire       wait4cy;
// wire       ni;
// wire       swi;
// wire       stcy;
// wire       branch_lo;
// wire       inc_pc;

reg  [41:0] ucode_rom[0:2**12-1];
wire [41:0] ucode_data;

initial begin
    $readmemb("65c02.uc",ucode_rom);
end

assign ucode_data = ucode_rom[uaddr];

assign halt       = ucode_data[ 0+:1];
assign brcy       = ucode_data[ 7+:1];
assign branch     = ucode_data[ 8+:1];
assign brlatch    = ucode_data[ 9+:1];
assign fetch      = ucode_data[10+:1];
assign nobr       = ucode_data[24+:1];
assign wr         = ucode_data[25+:1];
assign wait4cy    = ucode_data[30+:1];
assign ni         = ucode_data[31+:1];
assign swi        = ucode_data[32+:1];
assign stcy       = ucode_data[33+:1];
assign branch_lo  = ucode_data[34+:1];
assign inc_pc     = ucode_data[37+:1];
assign bcd_sel    = ucode_data[ 1+:2];
assign alu_sel    = ucode_data[ 3+:4];
assign carry_sel  = ucode_data[11+:2];
assign cc_sel     = ucode_data[13+:4];
assign ea_sel     = ucode_data[17+:2];
assign jsr_sel    = ucode_data[19+:5];
assign ld_sel     = ucode_data[26+:4];
assign opnd_sel   = ucode_data[35+:2];
assign rmux_sel   = ucode_data[38+:4];


always @* begin
    case( jsr_sel )
        IVRD_JSR:    begin jsr_en=1; jsr_ua = 12'h03*12'd16; end 
        IMM_JSR:     begin jsr_en=1; jsr_ua = 12'hAB*12'd16; end 
        ZPA_JSR:     begin jsr_en=1; jsr_ua = 12'h1B*12'd16; end 
        ZP_JSR:      begin jsr_en=1; jsr_ua = 12'h13*12'd16; end 
        ZPYA_JSR:    begin jsr_en=1; jsr_ua = 12'hCB*12'd16; end 
        ZPY_JSR:     begin jsr_en=1; jsr_ua = 12'hA3*12'd16; end 
        ZPXA_JSR:    begin jsr_en=1; jsr_ua = 12'hB3*12'd16; end 
        ZPX_JSR:     begin jsr_en=1; jsr_ua = 12'h23*12'd16; end 
        ABSA_JSR:    begin jsr_en=1; jsr_ua = 12'h93*12'd16; end 
        ABS_JSR:     begin jsr_en=1; jsr_ua = 12'h33*12'd16; end 
        ABSXA_JSR:   begin jsr_en=1; jsr_ua = 12'h4B*12'd16; end 
        ABSX_JSR:    begin jsr_en=1; jsr_ua = 12'h43*12'd16; end 
        ABSYA_JSR:   begin jsr_en=1; jsr_ua = 12'h5B*12'd16; end 
        ABSY_JSR:    begin jsr_en=1; jsr_ua = 12'h53*12'd16; end 
        INDXA_JSR:   begin jsr_en=1; jsr_ua = 12'h6B*12'd16; end 
        INDX_JSR:    begin jsr_en=1; jsr_ua = 12'h63*12'd16; end 
        INDYA_JSR:   begin jsr_en=1; jsr_ua = 12'h7B*12'd16; end 
        INDY_JSR:    begin jsr_en=1; jsr_ua = 12'h73*12'd16; end 
        INDA_JSR:    begin jsr_en=1; jsr_ua = 12'h9B*12'd16; end 
        IND_JSR:     begin jsr_en=1; jsr_ua = 12'h83*12'd16; end 
        WAIT4_JSR:   begin jsr_en=1; jsr_ua = 12'hBB*12'd16; end 
        PSH8_JSR:    begin jsr_en=1; jsr_ua = 12'h0B*12'd16; end 
        PUL8_JSR:    begin jsr_en=1; jsr_ua = 12'h2B*12'd16; end 
        RET_JSR:     begin jsr_en=1; jsr_ua = jsr_ret; end
        default:     begin jsr_en=0; jsr_ua = 'h00; end
    endcase
end
