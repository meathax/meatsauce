// SPDX-License-Identifier: BSD-3-Clause
// Galactic Storm MC68681 timer/interrupt/output-port frontend.
// Semantics: MAME 0.289 mc68681.cpp (Phil Stroffolino, Aaron Giles).
// Serial channels are not yet implemented; this block does not qualify a full DUART.
module gs_duart #(
    parameter integer SYS_HZ=32000000,
    parameter integer X1_HZ=4000000
)(
    input logic clk, reset, pause,
    input logic req, write,
    input logic [3:0] reg_a,
    input logic [7:0] wdata,
    output logic ack,
    output logic [7:0] rdata,
    output logic irq,
    output logic [7:0] vector,
    output logic [7:0] outport
);
    logic [7:0] acr, imr, isr, ct_hi, ct_lo, opr, opcr;
    logic [15:0] count;
    logic half_period, running, seen;
    logic [31:0] phase;
    logic [3:0] div16;
    wire [32:0] phase_next={1'b0,phase}+33'(X1_HZ);
    wire tick_x1=phase_next>=33'(SYS_HZ);
    wire tick=tick_x1 && ((acr[5:4]!=2'b11) || div16==4'd15);
    wire [15:0] reload_value={ct_hi,ct_lo}==0 ? 16'd1 : {ct_hi,ct_lo};
    assign irq=|(isr & imr);
    assign outport=~opr;
    always_ff @(posedge clk) begin
        ack<=0;
        if (reset) begin
            acr<=0; imr<=0; isr<=0; ct_hi<=0; ct_lo<=0;
            vector<=8'h0f; opr<=0; opcr<=0; count<=0;
            half_period<=0; running<=0; seen<=0;
            phase<=0; div16<=0; rdata<=0;
        end else begin
            if (!req) seen<=0;
            if (!pause) begin
                phase<=tick_x1 ? 32'(phase_next-33'(SYS_HZ)) : phase_next[31:0];
                if (tick_x1) div16<=div16+1'b1;
                if (running && tick) begin
                    if (count<=1) begin
                        if (acr[6]) begin
                            count<=reload_value; half_period<=~half_period;
                            if (half_period) isr[3]<=1;
                            if (opcr[3:2]==2'b01) opr[3]<=~opr[3];
                        end else begin
                            count<=16'hffff; isr[3]<=1;
                            if (opcr[3:2]==2'b01) opr[3]<=1;
                        end
                    end else count<=count-1'b1;
                end
            end
            if (req && !seen) begin
                seen<=1; ack<=1;
                if (write) begin
                    case(reg_a)
                        4'h4: begin
                            acr<=wdata;
                            // MAME mc68681.cpp:967: transition into timer mode
                            // starts counting even without a START-command read.
                            if(acr[6]!=wdata[6]) begin
                                running<=wdata[6];
                                if(wdata[6]) begin
                                    count<=reload_value;half_period<=0;phase<=0;div16<=0;
                                end
                            end
                        end
                        4'h5: imr<=wdata;
                        4'h6: ct_hi<=wdata;
                        4'h7: ct_lo<=wdata;
                        4'hc: vector<=wdata;
                        4'hd: opcr<=wdata;
                        4'he: opr<=opr|wdata;
                        4'hf: opr<=opr&~wdata;
                        default: ;
                    endcase
                end else begin
                    rdata<=0;
                    case(reg_a)
                        4'h1,4'h9: rdata<=8'h0c; // Tx ready/empty; RX disconnected.
                        4'h5: rdata<=isr;
                        4'h6: rdata<=count[15:8];
                        4'h7: rdata<=count[7:0];
                        4'hc: rdata<=vector;
                        4'hd: rdata<=8'hff; // unbound input port.
                        4'he: begin
                            count<=reload_value; running<=1;
                            div16<=0; phase<=0;
                            if(acr[6]) half_period<=0;
                        end
                        4'hf: begin
                            isr[3]<=0;
                            if (!acr[6]) begin
                                running<=0;
                                if(opcr[3:2]==2'b01) opr[3]<=0;
                            end
                        end
                        default: ;
                    endcase
                end
            end
        end
    end
endmodule
