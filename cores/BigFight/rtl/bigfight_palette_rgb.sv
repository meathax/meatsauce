// Palette xRGB555, MAME pal5bit expansion then optional eight-bit halving.
module bigfight_palette_rgb (
    input logic [15:0] palette_word,
    input logic shadow,
    output logic [7:0] red,green,blue
);
    logic [7:0] r,g,b;
    always_comb begin
        r={palette_word[14:10],palette_word[14:12]};
        g={palette_word[9:5],palette_word[9:7]};
        b={palette_word[4:0],palette_word[4:2]};
        red=shadow ? {1'b0,r[7:1]} : r;
        green=shadow ? {1'b0,g[7:1]} : g;
        blue=shadow ? {1'b0,b[7:1]} : b;
    end
endmodule
