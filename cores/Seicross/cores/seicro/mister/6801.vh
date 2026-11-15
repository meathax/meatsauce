reg jsr_en;
reg [12:0] jsr_ua, jsr_ret, uaddr;

// wire [3:0] alu_sel;
// wire [1:0] carry_sel;
// wire [3:0] cc_sel;
// wire [2:0] ea_sel;
// wire [4:0] jsr_sel;
// wire [3:0] ld_sel;
// wire [1:0] opnd_sel;
// wire [3:0] rmux_sel;

// wire       alt;
// wire       brlatch;
// wire       branch;
// wire       alu16;
// wire       halt;
// wire       invalid;
// wire       fetch;
// wire       ni;
// wire       op0inv;
// wire       inc_pc;
// wire       md_shift;
// wire       swi;
// wire       wr;

reg  [40:0] ucode_rom[0:2**13-1];
wire [40:0] ucode_data;

initial begin
    $readmemb("6801.uc",ucode_rom);
end

assign ucode_data = ucode_rom[uaddr];

assign alt        = ucode_data[ 0+:1];
assign brlatch    = ucode_data[ 5+:1];
assign branch     = ucode_data[ 6+:1];
assign alu16      = ucode_data[ 7+:1];
assign halt       = ucode_data[17+:1];
assign invalid    = ucode_data[18+:1];
assign fetch      = ucode_data[19+:1];
assign ni         = ucode_data[29+:1];
assign op0inv     = ucode_data[30+:1];
assign inc_pc     = ucode_data[33+:1];
assign md_shift   = ucode_data[38+:1];
assign swi        = ucode_data[39+:1];
assign wr         = ucode_data[40+:1];
assign alu_sel    = ucode_data[ 1+:4];
assign carry_sel  = ucode_data[ 8+:2];
assign cc_sel     = ucode_data[10+:4];
assign ea_sel     = ucode_data[14+:3];
assign jsr_sel    = ucode_data[20+:5];
assign ld_sel     = ucode_data[25+:4];
assign opnd_sel   = ucode_data[31+:2];
assign rmux_sel   = ucode_data[34+:4];


always @* begin
    case( jsr_sel )
        IVRD_JSR:    begin jsr_en=1; jsr_ua = 13'h00*13'd32; end 
        FRAME_JSR:   begin jsr_en=1; jsr_ua = 13'h12*13'd32; end 
        WAIFRAME_JSR: begin jsr_en=1; jsr_ua = 13'h18*13'd32; end 
        IMM_JSR:     begin jsr_en=1; jsr_ua = 13'h8F*13'd32; end 
        IMM16_JSR:   begin jsr_en=1; jsr_ua = 13'hCF*13'd32; end 
        DIRA_JSR:    begin jsr_en=1; jsr_ua = 13'h45*13'd32; end 
        DIR_JSR:     begin jsr_en=1; jsr_ua = 13'h14*13'd32; end 
        DIR16_JSR:   begin jsr_en=1; jsr_ua = 13'h15*13'd32; end 
        EXTA_JSR:    begin jsr_en=1; jsr_ua = 13'h55*13'd32; end 
        EXT_JSR:     begin jsr_en=1; jsr_ua = 13'h1C*13'd32; end 
        EXT16_JSR:   begin jsr_en=1; jsr_ua = 13'h1D*13'd32; end 
        IDXA_JSR:    begin jsr_en=1; jsr_ua = 13'h4B*13'd32; end 
        IDX_JSR:     begin jsr_en=1; jsr_ua = 13'h1E*13'd32; end 
        IDX16_JSR:   begin jsr_en=1; jsr_ua = 13'h1F*13'd32; end 
        PSH8_JSR:    begin jsr_en=1; jsr_ua = 13'h4E*13'd32; end 
        PSH16_JSR:   begin jsr_en=1; jsr_ua = 13'h02*13'd32; end 
        PUL8_JSR:    begin jsr_en=1; jsr_ua = 13'h03*13'd32; end 
        PUL16_JSR:   begin jsr_en=1; jsr_ua = 13'h41*13'd32; end 
        RTI8_JSR:    begin jsr_en=1; jsr_ua = 13'h51*13'd32; end 
        RTI16_JSR:   begin jsr_en=1; jsr_ua = 13'h52*13'd32; end 
        JSRIDX_JSR:  begin jsr_en=1; jsr_ua = 13'h1A*13'd32; end 
        RET_JSR:     begin jsr_en=1; jsr_ua = jsr_ret; end
        default:     begin jsr_en=0; jsr_ua = 'h00; end
    endcase
end
