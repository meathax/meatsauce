//------------------------------------------------------------------------------
// MiSTer addition (not in the donor): shares the shared RAM's H8 port (B) with the
// high-score unit. Both sides use level request / one-cycle ack; ownership only
// changes while the current owner has no request up, so every request/ack pair
// stays with one source. The H8 simply waits for its ack while the high-score
// unit owns the port.
//------------------------------------------------------------------------------
`default_nettype none

module sh_port_arb (
    input  logic        clk,
    input  logic        reset,
    // H8 side
    input  logic [15:1] h8_addr,  input logic h8_req,  input logic [1:0] h8_we,  input logic [15:0] h8_wdata,
    output logic [15:0] h8_q,     output logic h8_ack,
    // high-score side
    input  logic [15:1] hs_addr,  input logic hs_req,  input logic [1:0] hs_we,  input logic [15:0] hs_wdata,
    output logic [15:0] hs_q,     output logic hs_ack,
    // to shared_ram port B
    output logic [15:1] pb_addr,  output logic pb_req, output logic [1:0] pb_we, output logic [15:0] pb_wdata,
    input  logic [15:0] pb_q,     input  logic pb_ack
);
    logic hs_own;
    always_ff @(posedge clk) begin
        if (reset) hs_own <= 1'b0;
        else if (!hs_own && hs_req && !h8_req) hs_own <= 1'b1;
        else if ( hs_own && !hs_req)           hs_own <= 1'b0;
    end
    assign pb_addr  = hs_own ? hs_addr  : h8_addr;
    assign pb_req   = hs_own ? hs_req   : h8_req;
    assign pb_we    = hs_own ? hs_we    : h8_we;
    assign pb_wdata = hs_own ? hs_wdata : h8_wdata;
    assign h8_q     = pb_q;
    assign hs_q     = pb_q;
    assign h8_ack   = pb_ack & ~hs_own;
    assign hs_ack   = pb_ack &  hs_own;
endmodule
