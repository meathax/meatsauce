/*
 * Konami 054539 sample arithmetic reconstructed from furrtek/SiliconRE
 * c926ce92fdebd7613c8712b42c45a059d63548e0, Konami/054539/hdl/054539.v:
 *   1170-1174: STEP precision selected by DTYPE[2:1]
 *   1558-1563: 16-bit ADDC and PCM/DPCM sample mux
 *
 * Physical AOI22 wiring in k054539.SDF:18624-18710,31325-31634 proves
 * the coefficient LUT below. The public HDL reverses its two branches
 * and truncates the forced decoder input to three bits; neither error
 * is reproduced here. Nibble 8 is the reserved negative-128 end tag.
 *
 * The caller assembles the PCM word and selects the DPCM nibble. Address
 * sequencing, reverse nibble selection and inactive gating stay there.
 * Advance is the native OLD/NEW phase-bit16 XOR, not a count of crossed
 * nibbles. A suppressed step cannot terminate or change the accumulator.
 */
module jtviostorm_k054539_decode(
    input      [ 2:0] dtype,
    input      [ 3:0] nibble,
    input signed [15:0] pcm_word,
    input signed [15:0] previous,
    input              advance,
    output reg signed [15:0] step,
    output signed [15:0] sample,
    output reg         eof,
    output             valid
);

function signed [15:0] full_step;
    input [3:0] n;
    begin
        case (n)
            4'h0: full_step =  16'sd0;
            4'h1: full_step =  16'sd256;
            4'h2: full_step =  16'sd512;
            4'h3: full_step =  16'sd1024;
            4'h4: full_step =  16'sd2048;
            4'h5: full_step =  16'sd4096;
            4'h6: full_step =  16'sd8192;
            4'h7: full_step =  16'sd16384;
            4'h8: full_step =  16'sh8000;
            4'h9: full_step = -16'sd16384;
            4'ha: full_step = -16'sd8192;
            4'hb: full_step = -16'sd4096;
            4'hc: full_step = -16'sd2048;
            4'hd: full_step = -16'sd1024;
            4'he: full_step = -16'sd512;
            4'hf: full_step = -16'sd256;
        endcase
    end
endfunction

always @* begin
    case (dtype[2:1])
        2'd0: step = pcm_word;
        2'd1: step = advance ? full_step(nibble) : 16'sd0;
        2'd2: step = advance ? full_step(nibble) >>> 4 : 16'sd0;
        2'd3: step = advance ? full_step(nibble) >>> 8 : 16'sd0;
    endcase

    // SDF V34B/V38A compares the scaled STEP. Reduced precision ignores
    // replicated sign bits; all three DPCM precisions reserve nibble 8.
    // These masks also distinguish PCM's actual 0x8000 word sentinel.
    case (dtype[2:1])
        2'd0,2'd1: eof = (step == 16'h8000);
        2'd2:     eof = ((step & 16'h85ff) == 16'h8000);
        2'd3:     eof = ((step & 16'h807f) == 16'h8000);
    endcase
end

// ADDC discards its carry. The end tag is not accumulated: CH_SAMPLE is
// zero while V38A is low. Without advance, DPCM instead preserves previous.
assign valid = ~eof;
assign sample = eof ? 16'sd0 :
                (dtype[2:1] == 2'd0) ? pcm_word : previous + step;

endmodule
