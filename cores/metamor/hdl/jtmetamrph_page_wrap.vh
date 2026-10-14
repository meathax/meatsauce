// Exact signed page wrapping without a wide signed division network.
// Base four digits can be summed modulo three because 4 == 1 (mod 3).
function [1:0] page_mod3_4(input [3:0] value);
    reg [2:0] folded;
    begin
        folded = {1'b0,value[1:0]} + {1'b0,value[3:2]};
        case (folded)
            3'd0,3'd3,3'd6: page_mod3_4 = 2'd0;
            3'd1,3'd4: page_mod3_4 = 2'd1;
            default: page_mod3_4 = 2'd2;
        endcase
    end
endfunction

function [1:0] wrap_page(input signed [18:0] coordinate, input [1:0] extent);
    reg [1:0] r0,r1,r2,r3,residue;
    begin
        r0 = page_mod3_4({2'b0,coordinate[1:0]} + {2'b0,coordinate[3:2]} + {2'b0,coordinate[5:4]});
        r1 = page_mod3_4({2'b0,coordinate[7:6]} + {2'b0,coordinate[9:8]} + {2'b0,coordinate[11:10]});
        r2 = page_mod3_4({2'b0,coordinate[13:12]} + {2'b0,coordinate[15:14]} + {2'b0,coordinate[17:16]});
        r3 = page_mod3_4({r2,1'b0,coordinate[18]});
        residue = page_mod3_4({page_mod3_4({r0,r1}),r3});
        // Signed value = unsigned bits - sign*2^19; 2^19 == 2 (mod 3).
        if (coordinate[18]) begin
            case (residue)
                2'd0: residue = 2'd1;
                2'd1: residue = 2'd2;
                default: residue = 2'd0;
            endcase
        end
        case (extent)
            2'd0: wrap_page = 2'd0;
            2'd1: wrap_page = {1'b0,coordinate[0]};
            2'd2: wrap_page = residue;
            default: wrap_page = coordinate[1:0];
        endcase
    end
endfunction
