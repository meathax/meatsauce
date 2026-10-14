module zero_crypt_top (
    input wire clk,
    input wire [21:0] word_index,
    input wire [31:0] cipher_data,
    output wire [31:0] plain_data
);
    zeroteam_sprite_decrypt cipher (.clk(clk),.widx(word_index),.din(cipher_data),.dout(plain_data));
endmodule
