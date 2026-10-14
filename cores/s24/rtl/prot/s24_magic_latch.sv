import s24_pkg::*;

module s24_magic_latch (
    input  logic       clk,
    input  logic       reset,
    input  logic       wr,
    input  logic [7:0] din,
    input  magic_sel_t selector,
    output logic [7:0] dout
);
    function automatic [2:0] perm(input magic_sel_t sel, input [2:0] bitno);
        case (sel)
            MAGIC_MAHMAJN:  case(bitno) 0:perm=5;1:perm=1;2:perm=6;3:perm=2;4:perm=3;5:perm=7;6:perm=4;default:perm=0; endcase
            MAGIC_MAHMAJN2: case(bitno) 0:perm=6;1:perm=0;2:perm=5;3:perm=3;4:perm=1;5:perm=4;6:perm=2;default:perm=7; endcase
            MAGIC_BNZABROS: case(bitno) 0:perm=2;1:perm=4;2:perm=0;3:perm=5;4:perm=7;5:perm=3;6:perm=1;default:perm=6; endcase
            MAGIC_QROUKA:   case(bitno) 0:perm=1;1:perm=6;2:perm=4;3:perm=7;4:perm=0;5:perm=5;6:perm=3;default:perm=2; endcase
            MAGIC_QUIZMEKU: case(bitno) 0:perm=0;1:perm=3;2:perm=2;3:perm=4;4:perm=6;5:perm=1;6:perm=7;default:perm=5; endcase
            MAGIC_DCCLUB:   case(bitno) 0:perm=4;1:perm=7;2:perm=3;3:perm=0;4:perm=2;5:perm=6;6:perm=5;default:perm=1; endcase
            default: perm = bitno;
        endcase
    endfunction

    logic [7:0] feedback;
    always_comb begin
        feedback = 8'h00;
        for (int i = 0; i < 8; i++)
            if (dout[i]) feedback[perm(selector, 3'(i))] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (reset) dout <= 8'h00;
        // A null table represents an unpopulated protection daughterboard.
        // MAME ignores all writes in that profile, including the otherwise
        // special 0xff reset command.
        else if (wr && selector != MAGIC_NONE) begin
            if (din == 8'hff) dout <= 8'h00;
            else dout <= din ^ feedback;
        end
    end
endmodule
