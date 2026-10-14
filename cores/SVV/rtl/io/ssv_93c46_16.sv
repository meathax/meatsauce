// SPDX-License-Identifier: GPL-3.0-or-later
// 93C46/S2914-compatible 64x16 serial EEPROM command/data path.  Organization
// is fixed to the 16-bit mode selected by EEPROM_93C46_16BIT in MAME.
//
// ---------------------------------------------------------------------------
// Storage structure (2026-08-13): why two 32x16 banks instead of one 64x16
// array.
//
// The previous single `logic [15:0] mem [0:63]` had three *conditional* write
// sites (reset erase, ERASE command, WRITE command) and a *conditional* read
// nested inside a case inside an if, reading the array twice with different
// slices.  Quartus 17 will not infer memory from that shape: it built the array
// out of registers plus a 64:1 read mux, measured at 509.7 ALMs in the retained
// fit report for 1024 bits of storage.  See CLAUDE.md, "Diagnosing a design
// that does not fit" / "M10K RAM inference".
//
// The array is now split by address bit 0 into two independent 32x16 arrays,
// each written through ONE muxed write port and read through ONE unconditional
// registered read -- Altera's simple-dual-port template, nothing else in the
// always_ff.  The split exists for a functional reason, not just tidiness: it
// removes the read latency that a registered-read memory would otherwise add
// (see the timing note below).
//
// MLAB, not M10K.  32 words deep x 16 bits is exactly one MLAB (32x20), so the
// two banks cost two MLABs (~20 memory ALMs) and zero M10K.  M10K is the wrong
// choice here on both counts: the design is already at ~93% M10K occupancy, and
// a 32-word array is far below an M10K's useful depth (CLAUDE.md flags
// "inappropriate RAM size" for exactly this case).  ALM pressure is what this
// change is meant to relieve, and MLAB relieves it without touching the M10K
// budget.
//
// `no_rw_check` is safe here and is proven, not assumed: see (3) below.
//
// ---------------------------------------------------------------------------
// Serial timing is bit-identical to the register-built version.
//
// The externally observable requirement is that a READ command presents D15 on
// `dout` on the SAME clk edge that clocks in the last address bit (the ninth sk
// rising edge), which the focused bench verif/tb_ssv_gdfs_devices.sv asserts
// explicitly.  A naive registered-read memory would add one clk of latency and
// break that.  It does not here, because:
//
// (1) The read address is {command[4:0], di}.  `command[4:0]` (A5..A1) is a
//     register that last changed on the EIGHTH sk rising edge; `di` (A0) is a
//     combinational input that is only guaranteed valid at the ninth edge
//     itself (the bench drives di and sk together on the same negedge, so di
//     has no full-cycle setup).  Therefore the address cannot be registered a
//     cycle early -- but its low bit is the ONLY late term.
//
// (2) So both banks are read unconditionally and continuously at index
//     `command[4:0]`, and `di` selects between the two already-registered
//     results combinationally at the edge.  Bank read latency is hidden behind
//     the sk period; the di-dependent part costs a 2:1 mux, not a cycle.
//
//     The captured value is correct provided `command` did not change on the
//     immediately preceding clk edge.  It cannot: two detected sk rising edges
//     are always >= 2 clk apart (an edge needs sk_d==0, i.e. sk low for at
//     least one sampled cycle, and sk high on the edge cycle), so the cycle
//     before a rising edge is never itself a rising edge, and `command` only
//     changes on rising edges.  The other writer of `command` is the `!cs`
//     idle branch, which also forces bit_count to 0, so no bit_count==8
//     completion -- and hence no use of the read data -- can follow it.
//
// (3) Same-cycle read/write of one address never feeds a consumed read, for the
//     same reason: every array write happens either on an sk rising edge or
//     during the reset erase, the consumed capture happens on the non-edge
//     cycle immediately before a rising edge, and the reset erase holds the
//     serial FSM idle for its whole duration.  `no_rw_check` is therefore free.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
module ssv_93c46_16 (
    input logic clk, input logic rst,
    input logic cs, input logic sk, input logic di,
    output logic dout
);
logic cs_d, sk_d, write_enable;
logic [5:0] address;
logic [8:0] command;
logic [1:0] opcode;
logic [4:0] bit_count;
logic [15:0] shift;
logic [5:0] init_addr;
logic init_busy;

// --- storage: two 32x16 simple-dual-port banks, split on address bit 0 ------
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] mem0 [0:31];
(* ramstyle = "MLAB, no_rw_check" *) logic [15:0] mem1 [0:31];
logic [15:0] mem_q0, mem_q1;

// Single muxed write port, computed combinationally from exactly the same
// conditions the FSM below used at its three original write sites.
logic        mem_we;
logic [5:0]  mem_waddr;
logic [15:0] mem_wdata;
wire  [4:0]  mem_raddr = command[4:0];
wire         sk_rise   = sk && !sk_d;

always_comb begin
    mem_we    = 1'b0;
    mem_waddr = init_addr;
    mem_wdata = 16'hffff;
    if (rst) begin
        mem_we = 1'b0;
    end else if (init_busy) begin
        // Reset erase: one word per clk, 64 clks, serial interface held idle.
        mem_we    = 1'b1;
        mem_waddr = init_addr;
        mem_wdata = 16'hffff;
    end else if (cs && sk_rise) begin
        if (bit_count == 5'd8) begin
            // ERASE (opcode 11) completes with the command word itself.
            if ((command[6:5] == 2'b11) && write_enable) begin
                mem_we    = 1'b1;
                mem_waddr = {command[4:0], di};
                mem_wdata = 16'hffff;
            end
        end else if ((bit_count == 5'd24) && (opcode == 2'b01) && write_enable) begin
            // WRITE (opcode 01) commits on its sixteenth data bit.
            mem_we    = 1'b1;
            mem_waddr = address;
            mem_wdata = {shift[14:0], di};
        end
    end
end

// Altera simple-dual-port template: one write, one unconditional registered
// read, nothing else in the block.  Do not add a reset or a bypass here -- both
// break MLAB inference and push 1024 bits back into flops.
always_ff @(posedge clk) begin
    if (mem_we && !mem_waddr[0])
        mem0[mem_waddr[5:1]] <= mem_wdata;
    mem_q0 <= mem0[mem_raddr];
end

always_ff @(posedge clk) begin
    if (mem_we && mem_waddr[0])
        mem1[mem_waddr[5:1]] <= mem_wdata;
    mem_q1 <= mem1[mem_raddr];
end

// A0 selects the bank at the edge; see timing note (2).
wire [15:0] mem_rdata = di ? mem_q1 : mem_q0;

always_ff @(posedge clk) begin
    if (rst) begin
        cs_d<=0; sk_d<=0; dout<=1; write_enable<=0; address<=0;
        command<=0; opcode<=0; bit_count<=0; shift<=0;
        init_addr<=0; init_busy<=1;
    end else if (init_busy) begin
        // Hold the serial interface idle until reset has restored the erased
        // image.  The erase itself is driven by the write mux above.
        cs_d<=0; sk_d<=0; dout<=1; write_enable<=0;
        address<=0; command<=0; opcode<=0; bit_count<=0; shift<=0;
        if (init_addr == 6'd63)
            init_busy <= 1'b0;
        else
            init_addr <= init_addr + 1'd1;
    end else begin
        cs_d <= cs; sk_d <= sk;
        if (!cs) begin bit_count<=0; command<=0; dout<=1; end
        else if (sk_rise) begin
            if (bit_count < 9) begin
                command <= {command[7:0],di};
                bit_count <= bit_count + 1'd1;
                if (bit_count == 8) begin
                    address <= {command[4:0],di};
                    opcode <= command[6:5];
                    case (command[6:5])
                        2'b10: begin // READ: start bit + opcode 10 + A5:A0
                            shift <= mem_rdata;
                            dout <= mem_rdata[15];
                        end
                        2'b00: begin // EWEN/EWDS: top two address bits
                            write_enable <= command[4] && command[3];
                        end
                        // 2'b11 ERASE commits through the write mux above.
                        default: ;
                    endcase
                end
            end else if (opcode == 2'b10) begin
                shift <= {shift[14:0],1'b1};
                dout <= shift[14];
            end else if (opcode == 2'b01) begin
                shift <= {shift[14:0],di};
                bit_count <= bit_count + 1'd1;
                // The commit itself is driven by the write mux above.
            end
        end
    end
end
endmodule
