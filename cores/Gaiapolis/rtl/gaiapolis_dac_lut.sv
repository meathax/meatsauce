// Current Violent Storm Mild DAC table, copied from the read-only donor.
// Source: D:/Arcade/AI/aCORES/Violent storm/cores/viostorm/hdl/jtviostorm_dac_lut.v
// SHA256: a145ae8bae2465adcbbca828d526f5a6363e551af74612a0ad8d25a2b359c163
// Fixed curve: 255*clamp((x-24)/231,0,1)^1.30; current donor has no OSD toggle.
/*
 * Violent Storm video output transfer curve (054573 x3 + 054574 stage).
 *
 * o = 255 * clamp((x - 24) / 231, 0, 1) ^ 1.30. The capture of the PCB DAC is
 * steeper (floor 48, exponent 1.70) but over-saturates later stages, so this
 * curve sits between it and the linear output of MAME.
 */
module gaiapolis_dac_lut(
    input      [7:0] x,
    output reg [7:0] o
);
    always @(*) begin
        case (x)
            8'd0  : begin o = 8'd0  ; end 8'd1  : begin o = 8'd0  ; end 8'd2  : begin o = 8'd0  ; end 8'd3  : begin o = 8'd0  ; end
            8'd4  : begin o = 8'd0  ; end 8'd5  : begin o = 8'd0  ; end 8'd6  : begin o = 8'd0  ; end 8'd7  : begin o = 8'd0  ; end
            8'd8  : begin o = 8'd0  ; end 8'd9  : begin o = 8'd0  ; end 8'd10 : begin o = 8'd0  ; end 8'd11 : begin o = 8'd0  ; end
            8'd12 : begin o = 8'd0  ; end 8'd13 : begin o = 8'd0  ; end 8'd14 : begin o = 8'd0  ; end 8'd15 : begin o = 8'd0  ; end
            8'd16 : begin o = 8'd0  ; end 8'd17 : begin o = 8'd0  ; end 8'd18 : begin o = 8'd0  ; end 8'd19 : begin o = 8'd0  ; end
            8'd20 : begin o = 8'd0  ; end 8'd21 : begin o = 8'd0  ; end 8'd22 : begin o = 8'd0  ; end 8'd23 : begin o = 8'd0  ; end
            8'd24 : begin o = 8'd0  ; end 8'd25 : begin o = 8'd0  ; end 8'd26 : begin o = 8'd1  ; end 8'd27 : begin o = 8'd1  ; end
            8'd28 : begin o = 8'd1  ; end 8'd29 : begin o = 8'd2  ; end 8'd30 : begin o = 8'd2  ; end 8'd31 : begin o = 8'd3  ; end
            8'd32 : begin o = 8'd3  ; end 8'd33 : begin o = 8'd4  ; end 8'd34 : begin o = 8'd4  ; end 8'd35 : begin o = 8'd5  ; end
            8'd36 : begin o = 8'd5  ; end 8'd37 : begin o = 8'd6  ; end 8'd38 : begin o = 8'd7  ; end 8'd39 : begin o = 8'd7  ; end
            8'd40 : begin o = 8'd8  ; end 8'd41 : begin o = 8'd9  ; end 8'd42 : begin o = 8'd9  ; end 8'd43 : begin o = 8'd10 ; end
            8'd44 : begin o = 8'd11 ; end 8'd45 : begin o = 8'd11 ; end 8'd46 : begin o = 8'd12 ; end 8'd47 : begin o = 8'd13 ; end
            8'd48 : begin o = 8'd13 ; end 8'd49 : begin o = 8'd14 ; end 8'd50 : begin o = 8'd15 ; end 8'd51 : begin o = 8'd16 ; end
            8'd52 : begin o = 8'd16 ; end 8'd53 : begin o = 8'd17 ; end 8'd54 : begin o = 8'd18 ; end 8'd55 : begin o = 8'd19 ; end
            8'd56 : begin o = 8'd20 ; end 8'd57 : begin o = 8'd20 ; end 8'd58 : begin o = 8'd21 ; end 8'd59 : begin o = 8'd22 ; end
            8'd60 : begin o = 8'd23 ; end 8'd61 : begin o = 8'd24 ; end 8'd62 : begin o = 8'd24 ; end 8'd63 : begin o = 8'd25 ; end
            8'd64 : begin o = 8'd26 ; end 8'd65 : begin o = 8'd27 ; end 8'd66 : begin o = 8'd28 ; end 8'd67 : begin o = 8'd29 ; end
            8'd68 : begin o = 8'd30 ; end 8'd69 : begin o = 8'd30 ; end 8'd70 : begin o = 8'd31 ; end 8'd71 : begin o = 8'd32 ; end
            8'd72 : begin o = 8'd33 ; end 8'd73 : begin o = 8'd34 ; end 8'd74 : begin o = 8'd35 ; end 8'd75 : begin o = 8'd36 ; end
            8'd76 : begin o = 8'd37 ; end 8'd77 : begin o = 8'd38 ; end 8'd78 : begin o = 8'd39 ; end 8'd79 : begin o = 8'd39 ; end
            8'd80 : begin o = 8'd40 ; end 8'd81 : begin o = 8'd41 ; end 8'd82 : begin o = 8'd42 ; end 8'd83 : begin o = 8'd43 ; end
            8'd84 : begin o = 8'd44 ; end 8'd85 : begin o = 8'd45 ; end 8'd86 : begin o = 8'd46 ; end 8'd87 : begin o = 8'd47 ; end
            8'd88 : begin o = 8'd48 ; end 8'd89 : begin o = 8'd49 ; end 8'd90 : begin o = 8'd50 ; end 8'd91 : begin o = 8'd51 ; end
            8'd92 : begin o = 8'd52 ; end 8'd93 : begin o = 8'd53 ; end 8'd94 : begin o = 8'd54 ; end 8'd95 : begin o = 8'd55 ; end
            8'd96 : begin o = 8'd56 ; end 8'd97 : begin o = 8'd57 ; end 8'd98 : begin o = 8'd58 ; end 8'd99 : begin o = 8'd59 ; end
            8'd100: begin o = 8'd60 ; end 8'd101: begin o = 8'd61 ; end 8'd102: begin o = 8'd62 ; end 8'd103: begin o = 8'd63 ; end
            8'd104: begin o = 8'd64 ; end 8'd105: begin o = 8'd65 ; end 8'd106: begin o = 8'd66 ; end 8'd107: begin o = 8'd67 ; end
            8'd108: begin o = 8'd68 ; end 8'd109: begin o = 8'd70 ; end 8'd110: begin o = 8'd71 ; end 8'd111: begin o = 8'd72 ; end
            8'd112: begin o = 8'd73 ; end 8'd113: begin o = 8'd74 ; end 8'd114: begin o = 8'd75 ; end 8'd115: begin o = 8'd76 ; end
            8'd116: begin o = 8'd77 ; end 8'd117: begin o = 8'd78 ; end 8'd118: begin o = 8'd79 ; end 8'd119: begin o = 8'd80 ; end
            8'd120: begin o = 8'd81 ; end 8'd121: begin o = 8'd83 ; end 8'd122: begin o = 8'd84 ; end 8'd123: begin o = 8'd85 ; end
            8'd124: begin o = 8'd86 ; end 8'd125: begin o = 8'd87 ; end 8'd126: begin o = 8'd88 ; end 8'd127: begin o = 8'd89 ; end
            8'd128: begin o = 8'd90 ; end 8'd129: begin o = 8'd91 ; end 8'd130: begin o = 8'd93 ; end 8'd131: begin o = 8'd94 ; end
            8'd132: begin o = 8'd95 ; end 8'd133: begin o = 8'd96 ; end 8'd134: begin o = 8'd97 ; end 8'd135: begin o = 8'd98 ; end
            8'd136: begin o = 8'd100; end 8'd137: begin o = 8'd101; end 8'd138: begin o = 8'd102; end 8'd139: begin o = 8'd103; end
            8'd140: begin o = 8'd104; end 8'd141: begin o = 8'd105; end 8'd142: begin o = 8'd106; end 8'd143: begin o = 8'd108; end
            8'd144: begin o = 8'd109; end 8'd145: begin o = 8'd110; end 8'd146: begin o = 8'd111; end 8'd147: begin o = 8'd112; end
            8'd148: begin o = 8'd114; end 8'd149: begin o = 8'd115; end 8'd150: begin o = 8'd116; end 8'd151: begin o = 8'd117; end
            8'd152: begin o = 8'd118; end 8'd153: begin o = 8'd120; end 8'd154: begin o = 8'd121; end 8'd155: begin o = 8'd122; end
            8'd156: begin o = 8'd123; end 8'd157: begin o = 8'd124; end 8'd158: begin o = 8'd126; end 8'd159: begin o = 8'd127; end
            8'd160: begin o = 8'd128; end 8'd161: begin o = 8'd129; end 8'd162: begin o = 8'd131; end 8'd163: begin o = 8'd132; end
            8'd164: begin o = 8'd133; end 8'd165: begin o = 8'd134; end 8'd166: begin o = 8'd135; end 8'd167: begin o = 8'd137; end
            8'd168: begin o = 8'd138; end 8'd169: begin o = 8'd139; end 8'd170: begin o = 8'd140; end 8'd171: begin o = 8'd142; end
            8'd172: begin o = 8'd143; end 8'd173: begin o = 8'd144; end 8'd174: begin o = 8'd145; end 8'd175: begin o = 8'd147; end
            8'd176: begin o = 8'd148; end 8'd177: begin o = 8'd149; end 8'd178: begin o = 8'd151; end 8'd179: begin o = 8'd152; end
            8'd180: begin o = 8'd153; end 8'd181: begin o = 8'd154; end 8'd182: begin o = 8'd156; end 8'd183: begin o = 8'd157; end
            8'd184: begin o = 8'd158; end 8'd185: begin o = 8'd159; end 8'd186: begin o = 8'd161; end 8'd187: begin o = 8'd162; end
            8'd188: begin o = 8'd163; end 8'd189: begin o = 8'd165; end 8'd190: begin o = 8'd166; end 8'd191: begin o = 8'd167; end
            8'd192: begin o = 8'd169; end 8'd193: begin o = 8'd170; end 8'd194: begin o = 8'd171; end 8'd195: begin o = 8'd172; end
            8'd196: begin o = 8'd174; end 8'd197: begin o = 8'd175; end 8'd198: begin o = 8'd176; end 8'd199: begin o = 8'd178; end
            8'd200: begin o = 8'd179; end 8'd201: begin o = 8'd180; end 8'd202: begin o = 8'd182; end 8'd203: begin o = 8'd183; end
            8'd204: begin o = 8'd184; end 8'd205: begin o = 8'd186; end 8'd206: begin o = 8'd187; end 8'd207: begin o = 8'd188; end
            8'd208: begin o = 8'd190; end 8'd209: begin o = 8'd191; end 8'd210: begin o = 8'd192; end 8'd211: begin o = 8'd194; end
            8'd212: begin o = 8'd195; end 8'd213: begin o = 8'd196; end 8'd214: begin o = 8'd198; end 8'd215: begin o = 8'd199; end
            8'd216: begin o = 8'd201; end 8'd217: begin o = 8'd202; end 8'd218: begin o = 8'd203; end 8'd219: begin o = 8'd205; end
            8'd220: begin o = 8'd206; end 8'd221: begin o = 8'd207; end 8'd222: begin o = 8'd209; end 8'd223: begin o = 8'd210; end
            8'd224: begin o = 8'd211; end 8'd225: begin o = 8'd213; end 8'd226: begin o = 8'd214; end 8'd227: begin o = 8'd216; end
            8'd228: begin o = 8'd217; end 8'd229: begin o = 8'd218; end 8'd230: begin o = 8'd220; end 8'd231: begin o = 8'd221; end
            8'd232: begin o = 8'd222; end 8'd233: begin o = 8'd224; end 8'd234: begin o = 8'd225; end 8'd235: begin o = 8'd227; end
            8'd236: begin o = 8'd228; end 8'd237: begin o = 8'd229; end 8'd238: begin o = 8'd231; end 8'd239: begin o = 8'd232; end
            8'd240: begin o = 8'd234; end 8'd241: begin o = 8'd235; end 8'd242: begin o = 8'd237; end 8'd243: begin o = 8'd238; end
            8'd244: begin o = 8'd239; end 8'd245: begin o = 8'd241; end 8'd246: begin o = 8'd242; end 8'd247: begin o = 8'd244; end
            8'd248: begin o = 8'd245; end 8'd249: begin o = 8'd246; end 8'd250: begin o = 8'd248; end 8'd251: begin o = 8'd249; end
            8'd252: begin o = 8'd251; end 8'd253: begin o = 8'd252; end 8'd254: begin o = 8'd254; end 8'd255: begin o = 8'd255; end
            default: begin o = 8'd0; end
        endcase
    end
endmodule
