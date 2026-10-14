import s24_pkg::*;

module s24_inputs (
    input  logic [31:0] joy0,
    input  logic [31:0] joy1,
    input  logic [31:0] joy2,
    input  logic [31:0] joy3,
    input  logic [7:0]  dsw,
    input  logic [7:0]  coinage,
    input  logic [7:0]  paddle,
    input  logic        test_mode,
    input  logic        golf_io,
    input  logic        hotrod_io,
    input  logic        golf_angle,
    input  logic [7:0]  input_profile,
    input  logic [2:0]  mahjong_line,
    // Eight active-low matrix rows.  MAME defines rows 0..5 and returns ff
    // for the two unpopulated rows.
    input  logic [63:0] mahjong_matrix,
    output logic [63:0] ports
);
    function automatic [7:0] player(input [31:0] j);
        // MAME system24_generic: L,R,U,D,service,B2,B1,B3.
        // Each player port has its own cabinet service switch on bit 3
        // (SERVICE2 for P1 and SERVICE3 for P2).
        // MiSTer directions are {left,right,up,down} at j[1:0,3:2].
        player = {~j[1], ~j[0], ~j[3], ~j[2], ~j[12],
                  ~j[5], ~j[4], ~j[6]};
    endfunction

    function automatic [3:0] golf_swing_hi(input [3:0] p);
        logic [3:0] pos;
        begin
            // segas24_state::dcclub_p1_r()
            case (p)
                4'h0: pos=4'd0; 4'h1: pos=4'd1;
                4'h2: pos=4'd3; 4'h3: pos=4'd2;
                4'h4: pos=4'd6; 4'h5: pos=4'd4;
                4'h6: pos=4'd12;4'h7: pos=4'd8;
                4'h8: pos=4'd9;
                default: pos=4'd0;
            endcase
            golf_swing_hi=~pos;
        end
    endfunction

    function automatic [1:0] golf_swing_lo(input [3:0] p);
        logic [1:0] pos;
        begin
            // segas24_state::dcclub_p3_r()
            case (p)
                4'h9: pos=2'd1;
                4'ha: pos=2'd3;
                4'hb: pos=2'd2;
                default: pos=2'd0;
            endcase
            golf_swing_lo=~pos;
        end
    endfunction

    function automatic [3:0] golf_swing_index(input [7:0] p);
        // MAME constrains the swing pedal to 0x00..0xbf.
        golf_swing_index=(p>8'hbf)?4'hb:p[7:4];
    endfunction

    always_comb begin
        ports = 64'hffff_ffff_ffff_ffff;
        ports[7:0]   = player(joy0);
        ports[15:8]  = player(joy1);
        // Generic System 24 P3 is unpopulated and port D has no input
        // callback in MAME. Games with real P3/4 wiring repack those players
        // through their global cabinet profile below.
        ports[23:16] = 8'hff;
        ports[31:24] = 8'hff;
        // MAME SERVICE: coin4,coin3,start2,start1,service1,test,coin2,coin1.
        ports[39:32] = {~joy3[11],~joy2[11],~joy1[10],~joy0[10],
                        ~joy0[12],~(joy0[13]|test_mode),~joy1[11],~joy0[11]};
        ports[47:40] = coinage;
        ports[55:48] = dsw;

        case (input_profile)
            INPUT_GGROUND: begin
                // Gain Ground makes port C a real third-player port. Bit 0
                // is Coin 3 rather than the generic Button 3 input.
                ports[23:16] = {~joy2[1],~joy2[0],~joy2[3],~joy2[2],
                                ~joy2[12],~joy2[5],~joy2[4],~joy2[11]};
            end

            INPUT_QUIZ4, INPUT_QROUKA: begin
                // Quiz Mekurumeku Story and Quiz Rouka use the same four-
                // player packing: players 3/4 contribute start/button bits
                // to A/B and both direction nibbles share port C.
                ports[7:0] = {~joy0[1],~joy0[0],~joy0[3],~joy0[2],
                              ~joy2[4],1'b1,~joy0[4],~joy2[10]};
                ports[15:8] = {~joy1[1],~joy1[0],~joy1[3],~joy1[2],
                               ~joy3[4],1'b1,~joy1[4],~joy3[10]};
                ports[23:16] = {~joy2[1],~joy2[0],~joy2[3],~joy2[2],
                                ~joy3[1],~joy3[0],~joy3[3],~joy3[2]};

                if (input_profile == INPUT_QROUKA) begin
                    if (dsw[3]) begin
                        // Common chute: only coin 1/2 remain on bits 0/1.
                        ports[39:32] = {2'b11,~joy1[10],~joy0[10],
                                        ~joy0[12],~(joy0[13]|test_mode),
                                        ~joy1[11],~joy0[11]};
                    end else begin
                        // Separate chutes: coin 4,3,2,1 occupy bits 0,1,6,7.
                        ports[39:32] = {~joy0[11],~joy1[11],
                                        ~joy1[10],~joy0[10],~joy0[12],
                                        ~(joy0[13]|test_mode),
                                        ~joy2[11],~joy3[11]};
                    end
                end
            end

            INPUT_MAHJONG: begin
                // Port A identifies the selected scan line; port C returns
                // that active-low key row.  Port D advances the mux through
                // the separate s24_mahjong_mux output-callback model below.
                ports[7:0] = ~(8'b1 << mahjong_line);
                ports[15:8] = 8'hff;
                ports[23:16] = mahjong_matrix[mahjong_line*8 +: 8];
            end

            default: ;
        endcase

        if (golf_io) begin
            // Dynamic Country Club replaces the P1 direction
            // nibble with the encoded swing position and leave P2 unused.
            ports[7:0] = {golf_swing_hi(golf_swing_index(paddle)),
                          ~joy0[5],~joy0[7],~joy0[4],~joy0[6]};
            if (golf_angle) begin
                // Japanese cabinets use the uPD4701 angle dial instead of
                // the two discrete angle buttons.
                ports[0]=1'b1;
                ports[2]=1'b1;
            end
            ports[15:8] = 8'hff;
            ports[23:16] = {6'h3f,golf_swing_lo(golf_swing_index(paddle))};
        end

        if (hotrod_io) begin
            // Hot Rod dedicates PA to eight coin chutes and PB bits 3..6 to
            // four service switches. Four MiSTer player slots are exposed.
            ports[7:0] = {4'hf,~joy3[11],~joy2[11],~joy1[11],~joy0[11]};
            ports[15:8] = {1'b1,~joy3[12],~joy2[12],~joy1[12],
                           ~joy0[12],3'b111};
            ports[23:16] = 8'hff;
        end

    end
endmodule
