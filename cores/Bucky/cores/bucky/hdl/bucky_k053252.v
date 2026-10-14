/*
 * Konami K053252 CCU register/status model for the GX173 Bucky board.
 *
 * The pixel generator remains the K056832/vtimer implementation used by the
 * existing family core.  This block supplies the CPU-visible CCU contract:
 * sixteen byte registers, the MAME-compatible reset value for VC, and VCT
 * readback on offsets $0e/$0f.  The real Bucky map connects only the low byte
 * lane, so the parent wrapper gates cs with LDSn.
 *
 * Register semantics follow MAME 0.289 src/devices/machine/k053252.cpp:
 * HC/HFP/HBP/VC/VFP/VBP/HSW/VSW and interrupt-control bytes are write/read
 * storage; offset $0e returns the high VCT bit and $0f the low byte.  Bucky's
 * main CPU interrupt lines are sourced by the board's VBlank/object-DMA
 * wiring, so this model deliberately does not duplicate those callbacks.
 */
module bucky_k053252(
    input             rst,
    input             clk,
    input             cs,
    input             we,
    input             rd,
    input      [ 3:0] addr,
    input      [ 7:0] din,
    output reg [ 7:0] dout,
    input      [ 8:0] vcount
);

reg [7:0] regs [0:15];
// MAME keeps the active VC counter separately from the byte readback array.
// It resets to zero even though register 8 reads back as one, then stores the
// programmed 9-bit value plus one on either VC byte write.
reg [9:0] vc_counter;
integer i;

// The status result is the low nine bits of (VCT); bit 8 is exposed at $0e.
wire [9:0] vct = {1'b0,vcount} - vc_counter;

always @(posedge clk, posedge rst) begin
    if (rst) begin
        for (i=0; i<16; i=i+1) regs[i] <= 8'd0;
        // MAME's device_reset() leaves this byte at one.
        regs[8] <= 8'd1;
        vc_counter <= 10'd0;
    end else begin
        if (cs && we) begin
            regs[addr] <= din;
            if (addr == 4'h8)
                vc_counter <= {1'b0,din[0],regs[9]} + 10'd1;
            else if (addr == 4'h9)
                vc_counter <= {1'b0,regs[8][0],din} + 10'd1;
        end
    end
end

// The CCU presents its readback combinationally during the active CPU bus
// cycle.  Keeping this out of the storage clocked process avoids sampling a
// one-cycle-old byte in the 68000 read mux.
always @* begin
    dout = 8'hff;
    if (cs && rd) begin
        case (addr)
            4'he: dout = {7'd0,vct[8]};
            4'hf: dout = vct[7:0];
            default: dout = regs[addr];
        endcase
    end
end

endmodule
