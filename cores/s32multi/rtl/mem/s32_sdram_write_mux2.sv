//============================================================================
// Two-client serializer for the SDRAM controller's single word-write port.
// Client 0 is the HPS ROM loader and has priority; client 1 is the RF5C68
// runtime wave-RAM port. Payload and ownership stay latched through a stretched
// downstream ACK, and neither client can consume the other's completion.
//============================================================================

module s32_sdram_write_mux2 (
    input             clk,
    input             rst,

    input             c0_req,
    input      [24:1] c0_addr,
    input      [15:0] c0_data,
    input       [1:0] c0_be,
    output            c0_ack,

    input             c1_req,
    input      [24:1] c1_addr,
    input      [15:0] c1_data,
    input       [1:0] c1_be,
    output            c1_ack,

    output reg        d_req,
    output reg [24:1] d_addr,
    output reg [15:0] d_data,
    output reg  [1:0] d_be,
    input             d_ack
);

reg owner;
reg active;
reg cooldown;

assign c0_ack = active && !owner && d_ack;
assign c1_ack = active &&  owner && d_ack;

always @(posedge clk) begin
    if (rst) begin
        d_req <= 1'b0;
        d_addr <= '0;
        d_data <= '0;
        d_be <= 2'b00;
        owner <= 1'b0;
        active <= 1'b0;
        cooldown <= 1'b0;
    end
    else begin
        if (active && d_ack) begin
            d_req <= 1'b0;
            active <= 1'b0;
            cooldown <= 1'b1;
        end

        if (cooldown && !d_ack && (owner ? !c1_req : !c0_req))
            cooldown <= 1'b0;

        if (!active && !cooldown && !d_ack) begin
            if (c0_req) begin
                owner <= 1'b0;
                d_addr <= c0_addr;
                d_data <= c0_data;
                d_be <= c0_be;
                d_req <= 1'b1;
                active <= 1'b1;
            end
            else if (c1_req) begin
                owner <= 1'b1;
                d_addr <= c1_addr;
                d_data <= c1_data;
                d_be <= c1_be;
                d_req <= 1'b1;
                active <= 1'b1;
            end
        end
    end
end

`ifdef SIMULATION
always @(posedge clk) begin
    if (!rst) begin
        if (c0_ack && c1_ack) $fatal(1, "SDRAM write ACK crossed owners");
        if (d_ack && !active) $fatal(1, "SDRAM write ACK without owner");
    end
end
`endif

endmodule
