module psychos_y8950(
    input                rst,
    input                clk,
    input                cen,
    input                addr,
    input                cs_n,
    input                wr_n,
    input        [ 7:0]  din,
    output       [ 7:0]  dout,
    output               irq_n,

    output       [20:0]  rom_addr,
    output               rom_cs,
    input        [ 7:0]  rom_data,
    input                rom_ok,
    output reg signed [15:0] snd,
    output               sample,
    output signed [15:0] pcm_raw,
    output pcm_valid,
    output [2:0] adpcm_status
);

reg  [7:0] selreg, reg04;
wire       write = !cs_n && !wr_n;
reg        write_l;
wire       wstb  = write && !write_l;

always @(posedge clk) begin
    if( rst ) begin
        selreg <= 0; reg04 <= 0; write_l <= 0;
    end else begin
        write_l <= write;
        if( wstb && !addr ) selreg <= din;
        if( wstb && addr && selreg == 8'h04 && !din[7] ) reg04 <= din;
    end
end

wire is_adpcm = (selreg == 8'h07) || (selreg >= 8'h09 && selreg <= 8'h12) ||
                (selreg >= 8'h15 && selreg <= 8'h17);
wire is_nofm  = is_adpcm || selreg == 8'h05 || selreg == 8'h06 || selreg == 8'h18 || selreg == 8'h19;

wire [7:0] fm_dout;
wire fm_irq_n;
wire signed [15:0] fm_snd;
wire       fm_cs_n = cs_n | (addr & is_nofm);
wire [7:0] fm_din  = (addr && selreg == 8'h08) ? (din & 8'hC0) : din;

psychos_jtopl u_fm(
    .rst    ( rst      ),
    .clk    ( clk      ),
    .cen    ( cen      ),
    .din    ( fm_din   ),
    .addr   ( addr     ),
    .cs_n   ( fm_cs_n  ),
    .wr_n   ( wr_n     ),
    .dout   ( fm_dout  ),
    .irq_n  ( fm_irq_n ),
    .snd    ( fm_snd   ),
    .sample ( sample   )
);

reg [6:0] tcnt;
reg       tick;
always @(posedge clk) begin
    tick <= 0;
    if( rst ) tcnt <= 0;
    else if( cen ) begin
        if( tcnt == 7'd71 ) begin tcnt <= 0; tick <= 1; end
        else tcnt <= tcnt + 7'd1;
    end
end

wire [2:0] astat;
wire signed [15:0] pcm;
wire       awr   = wstb && addr && (is_adpcm || selreg == 8'h08);
wire [4:0] areg  = selreg[4:0] - 5'd7;
wire [7:0] adata = selreg == 8'h08 ? ((din & 8'h0F) | 8'h80) : din;

psychos_adpcmb u_adpcm(
    .rst      ( rst       ),
    .clk      ( clk       ),
    .tick     ( tick      ),
    .wr       ( awr       ),
    .wreg     ( areg      ),
    .wdata    ( adata     ),
    .status   ( astat     ),
    .clr_eos  ( wstb && addr && selreg == 8'h04 && din[4] ),
    .rom_addr ( rom_addr  ),
    .rom_cs   ( rom_cs    ),
    .rom_data ( rom_data  ),
    .rom_ok   ( rom_ok    ),
    .snd      ( pcm       ),
    .pcm_valid( pcm_valid )
);

assign pcm_raw = pcm;
assign adpcm_status = astat;

assign irq_n = fm_irq_n;
wire [7:0] st_raw = { ~irq_n, fm_dout[6:5], astat[0], astat[1], 2'b00, astat[2] };
assign dout = st_raw & ~(reg04 & 8'h78);

function signed [15:0] fp_dac( input signed [16:0] v );
    reg signed [15:0] c;
    reg [14:0] m;
    reg [3:0]  drop;
    integer k;
    begin
        c = v > 17'sd32767 ? 16'sd32767 : v < -17'sd32768 ? 16'sh8000 : v[15:0];
        m = c[14:0] ^ {15{c[15]}};
        drop = 0;
        for( k=9; k<15; k=k+1 ) if( m[k] ) drop = k[3:0]-4'd8;
        fp_dac = c & ~((16'd1 << drop) - 16'd1);
    end
endfunction

always @(posedge clk) snd <= fp_dac( {fm_snd[15], fm_snd} + {pcm[15], pcm} );

endmodule
