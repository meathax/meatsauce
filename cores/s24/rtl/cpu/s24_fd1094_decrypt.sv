// Combinational portion of MAME's fd1094_device::decrypt_one(). The caller
// supplies the address-selected key byte and performs the final opcode-mask
// ROM lookup using mask_address/mask_bit.
module s24_fd1094_decrypt (
    input  logic [23:1] word_address,
    input  logic [15:0] encrypted,
    input  logic [7:0]  mainkey,
    input  logic [7:0]  global_key1,
    input  logic [7:0]  global_key2,
    input  logic [7:0]  global_key3,
    input  logic [7:0]  state,
    input  logic        vector_fetch,
    output logic [15:0] value_unmasked,
    output logic [12:0] mask_address,
    output logic [2:0]  mask_bit
);
    logic [15:0] value;
    logic [7:0] gkey1,gkey2,gkey3;
    logic key_f;
    logic global_xor0,global_xor1,global_swap0a,global_swap0b;
    logic global_swap1,global_swap2,global_swap3,global_swap4;
    logic key_0a,key_0b,key_0c,key_1a,key_1b,key_2a,key_2b;
    logic key_3a,key_3b,key_4a,key_4b,key_5a,key_5b,key_6a,key_6b,key_7a;

    always_comb begin
        gkey1 = global_key1;
        gkey2 = global_key2;
        gkey3 = global_key3;
        if (state[0]) begin gkey1^=8'h04; gkey2^=8'h80; gkey3^=8'h80; end
        if (state[1]) begin gkey1^=8'h01; gkey2^=8'h10; gkey3^=8'h01; end
        if (state[2]) begin gkey1^=8'h80; gkey2^=8'h40; gkey3^=8'h04; end
        if (state[3]) begin gkey1^=8'h20; gkey2^=8'h02; gkey3^=8'h20; end
        if (state[4]) begin gkey1^=8'h42; gkey2^=8'h08; end
        if (state[5]) begin gkey1^=8'h08; gkey3^=8'h18; end
        if (state[6]) begin gkey1^=8'h10; gkey2^=8'h24; end
        if (state[7]) begin gkey2^=8'h01; gkey3^=8'h42; end

        // word_address is [23:1], so packed bit 13 is numeric word-address
        // bit 12, matching MAME's (address & 0x1000) test.
        key_f = word_address[13] ? mainkey[7] : mainkey[6];
        if (vector_fetch) begin
            if (word_address <= 3) gkey3 = 0;
            if (word_address <= 2) gkey2 = 0;
            if (word_address <= 1) begin gkey1=0; key_f=0; end
        end

        global_xor0   = !gkey1[5];
        global_xor1   = !gkey1[2];
        global_swap2  = !gkey1[0];
        global_swap0a = !gkey2[5];
        global_swap0b = !gkey2[2];
        global_swap3  = !gkey3[6];
        global_swap1  = !gkey3[4];
        global_swap4  = !gkey3[2];
        key_0a=mainkey[0]^gkey3[1]; key_0b=mainkey[0]^gkey1[7];
        key_0c=mainkey[0]^gkey1[1]; key_1a=mainkey[1]^gkey2[7];
        key_1b=mainkey[1]^gkey1[3]; key_2a=mainkey[2]^gkey3[7];
        key_2b=mainkey[2]^gkey1[4]; key_3a=mainkey[3]^gkey2[0];
        key_3b=mainkey[3]^gkey3[3]; key_4a=mainkey[4]^gkey2[3];
        key_4b=mainkey[4]^gkey3[0]; key_5a=mainkey[5]^gkey3[5];
        key_5b=mainkey[5]^gkey1[6]; key_6a=mainkey[6]^gkey2[1];
        key_6b=mainkey[6]^gkey2[6]; key_7a=mainkey[7]^gkey2[4];

        value = encrypted;
        if (value[15]) begin
            value={value[15],value[9],value[10],value[13],value[3],value[12],value[0],value[14],value[6],value[5],value[2],value[11],value[8],value[1],value[4],value[7]};
            if (!global_xor1 && !value[11]) value^=16'h3002;
            if (!value[5]) value^=16'h0044;
            if (!key_1b && !value[10]) value^=16'h0890;
            if (!global_swap2 && !key_0c) value^=16'h0308;
            value^=16'h6561;
            if (!key_2b) value={value[15],value[10],value[13],value[12],value[11],value[14],value[9],value[8],value[7],value[6],value[0],value[4],value[3],value[2],value[1],value[5]};
        end
        if (value[14]) begin
            value={value[13],value[14],value[7],value[0],value[8],value[6],value[4],value[2],value[1],value[15],value[3],value[11],value[12],value[10],value[5],value[9]};
            if (!global_xor0 && value[4]) value^=16'h0468;
            if (!key_3a && value[8]) value^=16'h0081;
            if (!key_6a && value[2]) value^=16'h0100;
            if (!key_5b && !key_0b) value^=16'h3012;
            value^=16'h3523;
            if (!global_swap0b) value={value[2],value[14],value[13],value[12],value[9],value[10],value[11],value[8],value[7],value[6],value[5],value[4],value[3],value[15],value[1],value[0]};
        end
        if (value[13]) begin
            value={value[10],value[2],value[13],value[7],value[8],value[0],value[3],value[14],value[6],value[15],value[1],value[11],value[9],value[4],value[5],value[12]};
            if (!key_4a && value[11]) value^=16'h010c;
            if (!key_1a && value[7]) value^=16'h1000;
            if (!key_7a && value[10]) value^=16'h0a21;
            if (!key_4b && !key_0a) value^=16'h0080;
            if (!global_swap0a && !key_6b) value^=16'hc000;
            value^=16'h99a5;
            if (!key_5b) value={value[15],value[14],value[13],value[12],value[11],value[1],value[9],value[8],value[7],value[10],value[5],value[6],value[3],value[2],value[4],value[0]};
        end
        if (|value[15:13]) begin
            value={value[15],value[13],value[14],value[5],value[6],value[0],value[9],value[10],value[4],value[11],value[1],value[2],value[12],value[3],value[7],value[8]};
            value^=16'h17ff;
            if (!global_swap4) value={value[15],value[14],value[13],value[6],value[11],value[10],value[9],value[5],value[7],value[12],value[8],value[4],value[3],value[2],value[1],value[0]};
            if (!global_swap3) value={value[13],value[15],value[14],value[12],value[11],value[10],value[9],value[8],value[7],value[6],value[5],value[4],value[3],value[2],value[1],value[0]};
            if (!global_swap2) value={value[15],value[14],value[13],value[12],value[11],value[2],value[9],value[8],value[10],value[6],value[5],value[4],value[3],value[0],value[1],value[7]};
            if (!key_3b) value={value[15],value[14],value[13],value[12],value[11],value[10],value[4],value[8],value[7],value[6],value[5],value[9],value[1],value[2],value[3],value[0]};
            if (!key_2a) value={value[13],value[14],value[15],value[12],value[11],value[10],value[9],value[8],value[7],value[6],value[5],value[4],value[3],value[2],value[1],value[0]};
            if (!global_swap1) value={value[15],value[14],value[13],value[12],value[9],value[8],value[11],value[10],value[7],value[6],value[5],value[4],value[3],value[2],value[1],value[0]};
            if (!key_5a) value={value[15],value[14],value[13],value[12],value[11],value[10],value[9],value[8],value[4],value[5],value[7],value[6],value[3],value[2],value[1],value[0]};
            if (!global_swap0a) value={value[15],value[14],value[13],value[12],value[11],value[10],value[9],value[8],value[7],value[6],value[5],value[4],value[0],value[3],value[2],value[1]};
        end

        value={value[12],value[15],value[14],value[13],value[11],value[10],value[9],value[8],value[7],value[6],value[5],value[4],value[3],value[2],value[1],value[0]};
        if ((value&16'hb080)==16'h8000) value^=16'h4000;
        if ((value&16'hf000)==16'hc000) value^=16'h0080;
        if ((value&16'hb100)==16'h0000) value^=16'h4000;
        value_unmasked=value;
        mask_address={key_f,value[15:4]};
        mask_bit=value[3:1];
    end
endmodule
