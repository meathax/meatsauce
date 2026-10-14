// 68000 bus and clocking block shared by the Tumble hardware maps.
// Memory decode and board devices are owned by tumble_game.
module tumble_main(
    input             rst,
    input             clk,
    input             haltn,
    input             bus_req,
    output            bus_grant,
    input      [ 6:0] cpu_num,
    input      [ 7:0] cpu_den,
    input      [15:0] din,
    input             bus_cs,
    input             bus_busy,
    input      [ 2:0] IPLn,
    output     [23:1] addr,
    output     [15:0] dout,
    output            rnw,
    output            UDSn,
    output            LDSn,
    output            ASn,
    output     [ 2:0] FC
);

reg  [15:0] cpu_din;
wire        cpu_cen, cpu_cenb;
wire        DTACKn;
wire        BGn;
wire        VPAn;
wire        busn;

assign busn = ASn | (UDSn & LDSn) | (&FC);
assign VPAn = ~&{FC, ~ASn};
// BG may be asserted while the current cycle is still finishing. The RAM
// owner can change only after the address and both byte strobes are idle.
assign bus_grant = !rst && !BGn && ASn && UDSn && LDSn;

always @(posedge clk) cpu_din <= din;

jtframe_68kdtack_cen #(.W(8)) u_dtack(
    .rst       ( rst       ),
    .clk       ( clk       ),
    .cpu_cen   ( cpu_cen   ),
    .cpu_cenb  ( cpu_cenb  ),
    .bus_cs    ( bus_cs    ),
    .bus_busy  ( bus_busy  ),
    .bus_legit ( 1'b0      ),
    .bus_ack   ( 1'b0      ),
    .ASn       ( ASn       ),
    .DSn       ( {UDSn,LDSn} ),
    .num       ( cpu_num   ),
    .den       ( cpu_den   ),
    .DTACKn    ( DTACKn    ),
    .wait2     ( 1'b0      ),
    .wait3     ( 1'b0      ),
    .fave      (           ),
    .fworst    (           )
);

jtframe_m68k u_cpu(
    .clk       ( clk       ),
    .rst       ( rst       ),
    .cpu_cen   ( cpu_cen   ),
    .cpu_cenb  ( cpu_cenb  ),
    .BERRn     ( 1'b1      ),
    .VPAn      ( VPAn      ),
    .BGACKn    ( 1'b1      ),
    .HALTn     ( haltn     ),
    .RESETn    (           ),
    .eab       ( addr      ),
    .ASn       ( ASn       ),
    .LDSn      ( LDSn      ),
    .UDSn      ( UDSn      ),
    .eRWn      ( rnw       ),
    .DTACKn    ( DTACKn    ),
    .iEdb      ( cpu_din   ),
    .oEdb      ( dout      ),
    .BRn       ( ~bus_req  ),
    .BGn       ( BGn       ),
    .IPLn      ( IPLn      ),
    .FC        ( FC        )
);

endmodule
