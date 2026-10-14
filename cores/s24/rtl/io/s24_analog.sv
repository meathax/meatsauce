// System 24 834-6510 analog daughterboard devices. Behaviour follows MAME's
// upd4701.cpp and msm6253.cpp; MiSTer spinner events provide signed deltas.

module s24_upd4701 (
    input  logic       clk,
    input  logic       reset,
    input  logic [8:0] spinner_x,
    input  logic [8:0] spinner_y,
    input  logic [1:0] addr,
    input  logic       read,
    output logic [7:0] dout
);
    logic [11:0] count_x,count_y;
    logic [11:0] latch_x,latch_y;
    logic toggle_x_d,toggle_y_d;

    always_comb begin
        case (addr)
            2'd0: dout=latch_x[7:0];
            2'd1: dout={4'h0,latch_x[11:8]};
            2'd2: dout=latch_y[7:0];
            default: dout={4'h0,latch_y[11:8]};
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            count_x<=12'd0;count_y<=12'd0;
            latch_x<=12'd0;latch_y<=12'd0;
            toggle_x_d<=spinner_x[8];toggle_y_d<=spinner_y[8];
        end else begin
            if (spinner_x[8]!=toggle_x_d)
                count_x<=count_x+{{4{spinner_x[7]}},spinner_x[7:0]};
            if (spinner_y[8]!=toggle_y_d)
                count_y<=count_y+{{4{spinner_y[7]}},spinner_y[7:0]};
            // The µPD4701A latches both axes on the active chip-select edge;
            // the CPU may then read either byte without seeing motion that
            // arrived between the two byte reads.
            if (read) begin
                latch_x<=count_x;
                latch_y<=count_y;
            end
            toggle_x_d<=spinner_x[8];
            toggle_y_d<=spinner_y[8];
        end
    end
endmodule

module s24_msm6253 (
    input  logic       clk,
    input  logic       reset,
    input  logic       select,
    input  logic       shift,
    input  logic [7:0] din,
    input  logic [7:0] an0,
    input  logic [7:0] an1,
    input  logic [7:0] an2,
    input  logic [7:0] an3,
    output logic [7:0] dout
);
    logic [7:0] shifter;

    // System 24 wires the serial result to D7.  Unlike Sega Y-board's map,
    // segas24.cpp does not select a high unmapped-bus value, so MAME's d7_r
    // supplies zero on D6:D0 for this board.
    assign dout={shifter[7],7'h00};

    always_ff @(posedge clk) begin
        if (reset) shifter<=8'h00;
        else if (select) begin
            case (din[1:0])
                2'd0: shifter<=an0;
                2'd1: shifter<=an1;
                2'd2: shifter<=an2;
                default: shifter<=an3;
            endcase
        end else if (shift) shifter<={shifter[6:0],1'b0};
    end
endmodule
