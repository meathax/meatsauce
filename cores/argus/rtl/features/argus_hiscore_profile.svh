// Generated from pinned MAME 0.289 hiscore.dat. Do not hand-edit.
function automatic [9:0] hs_dump_bytes(input logic [1:0] g);
case(g)
2'd0: hs_dump_bytes = 10'd72;
2'd1: hs_dump_bytes = 10'd44;
2'd2: hs_dump_bytes = 10'd278;
default: hs_dump_bytes = 0;
endcase
endfunction
function automatic [5:0] hs_config_bytes(input logic [1:0] g);
case(g)
2'd0: hs_config_bytes = 6'd40;
2'd1: hs_config_bytes = 6'd32;
2'd2: hs_config_bytes = 6'd40;
default: hs_config_bytes = 0;
endcase
endfunction
function automatic [2:0] hs_signature_count(input logic [1:0] g);
case(g)
2'd0: hs_signature_count = 3'd6;
2'd1: hs_signature_count = 3'd4;
2'd2: hs_signature_count = 3'd6;
default: hs_signature_count = 0;
endcase
endfunction
function automatic [7:0] hs_config_byte(input logic [1:0] g, input logic [5:0] i);
case(g)
2'd0: case(i)
0: hs_config_byte = 8'h0;
1: hs_config_byte = 8'h0;
2: hs_config_byte = 8'h0;
3: hs_config_byte = 8'h0;
4: hs_config_byte = 8'h4;
5: hs_config_byte = 8'h0;
6: hs_config_byte = 8'h0;
7: hs_config_byte = 8'h2;
8: hs_config_byte = 8'h0;
9: hs_config_byte = 8'h2;
10: hs_config_byte = 8'h0;
11: hs_config_byte = 8'h1;
12: hs_config_byte = 8'h0;
13: hs_config_byte = 8'h0;
14: hs_config_byte = 8'h4;
15: hs_config_byte = 8'h0;
16: hs_config_byte = 8'h0;
17: hs_config_byte = 8'h0;
18: hs_config_byte = 8'hfb;
19: hs_config_byte = 8'h80;
20: hs_config_byte = 8'h0;
21: hs_config_byte = 8'h40;
22: hs_config_byte = 8'h0;
23: hs_config_byte = 8'h0;
24: hs_config_byte = 8'h0;
25: hs_config_byte = 8'h0;
26: hs_config_byte = 8'he0;
27: hs_config_byte = 8'h39;
28: hs_config_byte = 8'h0;
29: hs_config_byte = 8'h7;
30: hs_config_byte = 8'h0;
31: hs_config_byte = 8'h0;
32: hs_config_byte = 8'h0;
33: hs_config_byte = 8'h0;
34: hs_config_byte = 8'he0;
35: hs_config_byte = 8'h3d;
36: hs_config_byte = 8'h0;
37: hs_config_byte = 8'h1;
38: hs_config_byte = 8'h7;
39: hs_config_byte = 8'h7;
default: hs_config_byte = 0;
endcase
2'd1: case(i)
0: hs_config_byte = 8'h0;
1: hs_config_byte = 8'h0;
2: hs_config_byte = 8'h0;
3: hs_config_byte = 8'h0;
4: hs_config_byte = 8'h4;
5: hs_config_byte = 8'h0;
6: hs_config_byte = 8'h0;
7: hs_config_byte = 8'h2;
8: hs_config_byte = 8'h0;
9: hs_config_byte = 8'h2;
10: hs_config_byte = 8'h0;
11: hs_config_byte = 8'h1;
12: hs_config_byte = 8'h0;
13: hs_config_byte = 8'h0;
14: hs_config_byte = 8'h4;
15: hs_config_byte = 8'h0;
16: hs_config_byte = 8'h0;
17: hs_config_byte = 8'h0;
18: hs_config_byte = 8'hfc;
19: hs_config_byte = 8'ha0;
20: hs_config_byte = 8'h0;
21: hs_config_byte = 8'h28;
22: hs_config_byte = 8'h0;
23: hs_config_byte = 8'h53;
24: hs_config_byte = 8'h0;
25: hs_config_byte = 8'h0;
26: hs_config_byte = 8'hfc;
27: hs_config_byte = 8'h38;
28: hs_config_byte = 8'h0;
29: hs_config_byte = 8'h4;
30: hs_config_byte = 8'h0;
31: hs_config_byte = 8'h0;
default: hs_config_byte = 0;
endcase
2'd2: case(i)
0: hs_config_byte = 8'h0;
1: hs_config_byte = 8'h0;
2: hs_config_byte = 8'h0;
3: hs_config_byte = 8'h0;
4: hs_config_byte = 8'h4;
5: hs_config_byte = 8'h0;
6: hs_config_byte = 8'h0;
7: hs_config_byte = 8'h2;
8: hs_config_byte = 8'h0;
9: hs_config_byte = 8'h2;
10: hs_config_byte = 8'h0;
11: hs_config_byte = 8'h1;
12: hs_config_byte = 8'h0;
13: hs_config_byte = 8'h0;
14: hs_config_byte = 8'h4;
15: hs_config_byte = 8'h0;
16: hs_config_byte = 8'h0;
17: hs_config_byte = 8'h0;
18: hs_config_byte = 8'hfa;
19: hs_config_byte = 8'hb0;
20: hs_config_byte = 8'h1;
21: hs_config_byte = 8'h10;
22: hs_config_byte = 8'h0;
23: hs_config_byte = 8'h7;
24: hs_config_byte = 8'h0;
25: hs_config_byte = 8'h0;
26: hs_config_byte = 8'hfc;
27: hs_config_byte = 8'ha0;
28: hs_config_byte = 8'h0;
29: hs_config_byte = 8'h5;
30: hs_config_byte = 8'h0;
31: hs_config_byte = 8'h0;
32: hs_config_byte = 8'h0;
33: hs_config_byte = 8'h0;
34: hs_config_byte = 8'hfc;
35: hs_config_byte = 8'ha2;
36: hs_config_byte = 8'h0;
37: hs_config_byte = 8'h1;
38: hs_config_byte = 8'h2;
39: hs_config_byte = 8'h2;
default: hs_config_byte = 0;
endcase
default: hs_config_byte = 0;
endcase
endfunction
function automatic [15:0] hs_signature_address(input logic [1:0] g, input logic [2:0] i);
case(g)
2'd0: case(i)
0: hs_signature_address = 16'hfb80;
1: hs_signature_address = 16'hfbbf;
2: hs_signature_address = 16'he039;
3: hs_signature_address = 16'he03f;
4: hs_signature_address = 16'he03d;
5: hs_signature_address = 16'he03d;
default: hs_signature_address = 0;
endcase
2'd1: case(i)
0: hs_signature_address = 16'hfca0;
1: hs_signature_address = 16'hfcc7;
2: hs_signature_address = 16'hfc38;
3: hs_signature_address = 16'hfc3b;
default: hs_signature_address = 0;
endcase
2'd2: case(i)
0: hs_signature_address = 16'hfab0;
1: hs_signature_address = 16'hfbbf;
2: hs_signature_address = 16'hfca0;
3: hs_signature_address = 16'hfca4;
4: hs_signature_address = 16'hfca2;
5: hs_signature_address = 16'hfca2;
default: hs_signature_address = 0;
endcase
default: hs_signature_address = 0;
endcase
endfunction
function automatic [7:0] hs_signature_value(input logic [1:0] g, input logic [2:0] i);
case(g)
2'd0: case(i)
0: hs_signature_value = 8'h0;
1: hs_signature_value = 8'h0;
2: hs_signature_value = 8'h0;
3: hs_signature_value = 8'h0;
4: hs_signature_value = 8'h7;
5: hs_signature_value = 8'h7;
default: hs_signature_value = 0;
endcase
2'd1: case(i)
0: hs_signature_value = 8'h0;
1: hs_signature_value = 8'h53;
2: hs_signature_value = 8'h0;
3: hs_signature_value = 8'h0;
default: hs_signature_value = 0;
endcase
2'd2: case(i)
0: hs_signature_value = 8'h0;
1: hs_signature_value = 8'h7;
2: hs_signature_value = 8'h0;
3: hs_signature_value = 8'h0;
4: hs_signature_value = 8'h2;
5: hs_signature_value = 8'h2;
default: hs_signature_value = 0;
endcase
default: hs_signature_value = 0;
endcase
endfunction
function automatic [15:0] hs_dump_address(input logic [1:0] g, input logic [8:0] i);
case(g)
2'd0: begin
if ({1'b0,i} < 10'd64) hs_dump_address = 16'hfb80 + {7'd0,i} - 16'd0;
else if ({1'b0,i} < 10'd71) hs_dump_address = 16'he039 + {7'd0,i} - 16'd64;
else if ({1'b0,i} < 10'd72) hs_dump_address = 16'he03d + {7'd0,i} - 16'd71;
else hs_dump_address = 0;
end
2'd1: begin
if ({1'b0,i} < 10'd40) hs_dump_address = 16'hfca0 + {7'd0,i} - 16'd0;
else if ({1'b0,i} < 10'd44) hs_dump_address = 16'hfc38 + {7'd0,i} - 16'd40;
else hs_dump_address = 0;
end
2'd2: begin
if ({1'b0,i} < 10'd272) hs_dump_address = 16'hfab0 + {7'd0,i} - 16'd0;
else if ({1'b0,i} < 10'd277) hs_dump_address = 16'hfca0 + {7'd0,i} - 16'd272;
else if ({1'b0,i} < 10'd278) hs_dump_address = 16'hfca2 + {7'd0,i} - 16'd277;
else hs_dump_address = 0;
end
default: hs_dump_address = 0;
endcase
endfunction
