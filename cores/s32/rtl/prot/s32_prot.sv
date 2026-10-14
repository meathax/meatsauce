
//============================================================================
//  System 32 protection hardware retained by the production profile.
//============================================================================

import s32_pkg::*;

module s32_prot_darkedge #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             vblank,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input      [15:0] wram_rdata,
    input             wram_ack
);

typedef enum logic [2:0] { DKE_IDLE, DKE_W0, DKE_R0, DKE_W1, DKE_W2 } dke_state_t;
dke_state_t state;
reg [7:0] tmp;

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= DKE_IDLE;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
        tmp        <= 8'h00;
    end
    else begin
        case (state)
        DKE_IDLE: begin
            wram_req <= 1'b0;
            if (vblank) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hF072 >> 1;
                wram_wdata <= 16'h0000;
                wram_be    <= 2'b11;
                state      <= DKE_W0;
            end
        end
        DKE_W0: if (wram_ack) begin
            wram_req   <= 1'b1;
            wram_we    <= 1'b1;
            wram_addr  <= 16'hF082 >> 1;
            wram_wdata <= 16'h0000;
            wram_be    <= 2'b11;
            state      <= DKE_R0;
        end
        DKE_R0: if (wram_ack) begin
            wram_req  <= 1'b1;
            wram_we   <= 1'b0;
            wram_addr <= 16'hA12C >> 1;
            state     <= DKE_W1;
        end
        DKE_W1: if (wram_ack) begin
            tmp <= wram_rdata[7:0];
            if (wram_rdata[7:0] != 0) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hA12C >> 1;
                wram_wdata <= {8'h00, wram_rdata[7:0] - 8'h01};
                wram_be    <= 2'b01;
                state      <= DKE_W2;
            end
            else begin
                wram_req <= 1'b0;
                state    <= DKE_IDLE;
            end
        end
        DKE_W2: if (wram_ack) begin
            if (tmp == 8'h01) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hA12E >> 1;
                wram_wdata <= 16'h0001;
                wram_be    <= 2'b01;
            end
            else begin
                wram_req <= 1'b0;
            end
            state <= DKE_IDLE;
        end
        default: begin
            wram_req <= 1'b0;
            state    <= DKE_IDLE;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// Burning Rival ROM-string protection copy (MAME init_brival).
// ---------------------------------------------------------------------------
module s32_prot_brival (
    input             clk,
    input             rst,
    input             enable,

    input             cpu_wr,
    input      [23:0] cpu_addr,
    input      [15:0] cpu_wdata,

    // Read trap: the MAME handler is installed for word reads at 0x20BA00-07.
    input             cpu_rd,
    input       [1:0] cpu_be,
    output reg        trap_active,
    output reg [15:0] trap_data,

    // Protection RAM bytes are overlaid onto the work-RAM second port.
    output reg        pram_we,
    output reg  [7:0] pram_addr,
    output reg  [7:0] pram_wdata,

    // Main-ROM read client.
    output reg        rom_req,
    output reg [23:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack
);

function automatic [23:0] slot_rom(input [2:0] s);
    case (s)
        3'd0: slot_rom = 24'h109517;
        3'd5: slot_rom = 24'h109617;
        default: slot_rom = 24'h109597;
    endcase
endfunction

reg [2:0] slot;
reg [3:0] cnt;
typedef enum logic [2:0] { B_IDLE, B_RD, B_GAP, B_WR } brival_state_t;
brival_state_t state;

always @(posedge clk) begin
    if (rst) begin
        state       <= B_IDLE;
        rom_req     <= 1'b0;
        pram_we     <= 1'b0;
        trap_active <= 1'b0;
        trap_data   <= 16'h0000;
    end
    else begin
        pram_we <= 1'b0;
        // Byte reads fall through to work RAM; only full-word accesses are
        // handled by the protection device.
        trap_active <= enable && cpu_rd && (cpu_be == 2'b11) &&
                       (cpu_addr[23:4] == 20'h20BA0) &&
                       (cpu_addr[3:1] == 3'd0 ||
                        cpu_addr[3:1] == 3'd2 ||
                        cpu_addr[3:1] == 3'd3);
        trap_data <= 16'h0000;

        case (state)
        B_IDLE: begin
            rom_req <= 1'b0;
            if (enable && cpu_wr && cpu_addr[23:12] == 12'hA00 &&
                cpu_addr[11:4] == 8'h80 && cpu_addr[3:1] <= 3'd5) begin
                slot     <= cpu_addr[3:1];
                cnt      <= 4'd0;
                rom_req  <= 1'b1;
                rom_addr <= slot_rom(cpu_addr[3:1]);
                state    <= B_RD;
            end
        end
        B_RD: if (rom_ack) begin
            rom_req    <= 1'b0;
            pram_we    <= 1'b1;
            pram_addr  <= {slot, 4'b0} + {3'b0, cnt};
            // The cache returns a word containing the requested byte.  The
            // odd source address selects its upper lane.
            pram_wdata <= rom_addr[0] ? rom_data[15:8] : rom_data[7:0];
            if (cnt == 4'd15) begin
                state <= B_IDLE;
            end
            else begin
                cnt   <= cnt + 1'b1;
                state <= B_GAP;
            end
        end
        B_GAP: begin
            // The ROM client is edge-triggered.  Keep one complete low cycle
            // between consecutive byte requests.
            rom_req  <= 1'b1;
            rom_addr <= slot_rom(slot) + {19'b0, cnt};
            state    <= B_RD;
        end
        default: begin
            state   <= B_IDLE;
            rom_req <= 1'b0;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// The J.League 1994 protection write handler.
//
// MAME's init_jleague installs a write16 handler at 0x20f700-0x20f705:
// offset 0 indexes the main-ROM table at 0x07bbc0 and publishes its low byte
// at work RAM 0x20f708; offset 2 (0x20f704) publishes the selected team byte at
// 0x200016.  svf/svfo/svs do not install this handler and therefore never
// enable this responder.
// ---------------------------------------------------------------------------
module s32_prot_jleague #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             cpu_write,
    input      [23:0] cpu_addr,
    input      [15:0] cpu_wdata,
    output reg        rom_req,
    output reg  [20:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input             wram_ack
);

typedef enum logic [1:0] { JL_IDLE, JL_ROM, JL_WR } jl_state_t;
jl_state_t state;

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= JL_IDLE;
        rom_req    <= 1'b0;
        rom_addr   <= 21'h000000;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
    end
    else begin
        case (state)
        JL_IDLE: begin
            rom_req  <= 1'b0;
            wram_req <= 1'b0;
            if (cpu_write && cpu_addr == 24'h20f700) begin
                // 0x07bbc0 + data * 2, the same word-aligned main-ROM read
                // used by segas32_state::jleague_protection_w.
                rom_addr <= 21'h07bbc0 + {4'd0, cpu_wdata, 1'b0};
                rom_req  <= 1'b1;
                state    <= JL_ROM;
            end
            else if (cpu_write && cpu_addr == 24'h20f704) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'h0016 >> 1;
                wram_wdata <= {8'h00, cpu_wdata[7:0]};
                wram_be    <= 2'b01;
                state      <= JL_WR;
            end
        end
        JL_ROM: begin
            if (rom_ack) begin
                rom_req    <= 1'b0;
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hf708 >> 1;
                wram_wdata <= {8'h00, rom_data[7:0]};
                wram_be    <= 2'b01;
                state      <= JL_WR;
            end
        end
        JL_WR: begin
            if (wram_ack) begin
                wram_req <= 1'b0;
                state    <= JL_IDLE;
            end
        end
        default: begin
            state    <= JL_IDLE;
            rom_req  <= 1'b0;
            wram_req <= 1'b0;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// Dragon Ball Z V.R. V.S. FD1149 protection handler (MAME init_dbzvrvs).
// A write in 0xa00000-0xa7ffff copies work RAM 0x200044 to 0x2080c8.
// ---------------------------------------------------------------------------
module s32_prot_dbzvrvs #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             cpu_write,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input      [15:0] wram_rdata,
    input             wram_ack
);

typedef enum logic [1:0] { DBZ_IDLE, DBZ_READ, DBZ_WRITE } dbz_state_t;
dbz_state_t state;

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= DBZ_IDLE;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
    end
    else begin
        case (state)
        DBZ_IDLE: begin
            wram_req <= 1'b0;
            if (cpu_write) begin
                wram_req  <= 1'b1;
                wram_we   <= 1'b0;
                wram_addr <= 16'h0022; // 0x200044 >> 1
                wram_be   <= 2'b00;
                state     <= DBZ_READ;
            end
        end
        DBZ_READ: if (wram_ack) begin
            wram_req   <= 1'b1;
            wram_we    <= 1'b1;
            wram_addr  <= 16'h4064; // 0x2080c8 >> 1
            wram_wdata <= wram_rdata;
            wram_be    <= 2'b11;
            state      <= DBZ_WRITE;
        end
        DBZ_WRITE: if (wram_ack) begin
            wram_req <= 1'b0;
            state    <= DBZ_IDLE;
        end
        default: begin
            wram_req <= 1'b0;
            state    <= DBZ_IDLE;
        end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
// SegaSonic level-load protection device (final set, FD1149 317-0213 board).
//
// The game keeps a cleared-level counter at work RAM 0x20e5c4. Every time it
// stores that counter the protection device selects the next stage from the
// level-order table the main ROM carries at 0x2638, publishes the stage id at
// work RAM 0x20f06e and clears the two status words at 0x20f0bc/0x20f0be.
//
// Table entries are big-endian words at 0x2638 + 2*cleared. Entry 0 overlaps
// the preceding data word (0xff07), so a counter of zero yields the constant
// 0x0007 instead of a table fetch. Stage 0x0007 is the trackball/button
// tutorial the game runs first; the counter reaching 1 at the end of that
// tutorial is what selects 0x0006, the first real stage. Reading the order
// from ROM rather than carrying a transcribed copy keeps the progression
// identical to the board's own data for every entry.
//
// Keep this responder profile-gated: the prototype does not install it.
// ---------------------------------------------------------------------------
module s32_prot_sonic #(
    parameter ENABLE = 1'b1
) (
    input             clk,
    input             rst,
    input             enable,
    input             cpu_write,
    input      [23:0] cpu_addr,
    output reg        rom_req,
    output reg [20:0] rom_addr,
    input      [15:0] rom_data,
    input             rom_ack,
    output reg        wram_req,
    output reg        wram_we,
    output reg [15:0] wram_addr,
    output reg [15:0] wram_wdata,
    output reg  [1:0] wram_be,
    input      [15:0] wram_rdata,
    input             wram_ack
);

localparam [20:0] LEVEL_ORDER_BASE = 21'h002638;

typedef enum logic [2:0] {
    SONIC_IDLE, SONIC_COUNT, SONIC_ROM, SONIC_LEVEL, SONIC_STATUS0, SONIC_STATUS1
} sonic_state_t;
sonic_state_t state;

always @(posedge clk) begin
    if (rst || !ENABLE || !enable) begin
        state      <= SONIC_IDLE;
        rom_req    <= 1'b0;
        rom_addr   <= 21'h000000;
        wram_req   <= 1'b0;
        wram_we    <= 1'b0;
        wram_addr  <= 16'h0000;
        wram_wdata <= 16'h0000;
        wram_be    <= 2'b00;
    end
    else begin
        case (state)
            SONIC_IDLE: begin
                rom_req  <= 1'b0;
                wram_req <= 1'b0;
                if (cpu_write && cpu_addr == 24'h20e5c4) begin
                    // Read back the counter the CPU just stored: the device
                    // acts on the completed 16-bit word, not on the byte lanes
                    // of one access.
                    wram_req  <= 1'b1;
                    wram_we   <= 1'b0;
                    wram_addr <= 16'he5c4 >> 1;
                    state     <= SONIC_COUNT;
                end
            end
            SONIC_COUNT: if (wram_ack) begin
                if (wram_rdata == 16'h0000) begin
                    wram_req   <= 1'b1;
                    wram_we    <= 1'b1;
                    wram_addr  <= 16'hf06e >> 1;
                    wram_wdata <= 16'h0007;
                    wram_be    <= 2'b11;
                    state      <= SONIC_LEVEL;
                end
                else begin
                    wram_req <= 1'b0;
                    rom_req  <= 1'b1;
                    rom_addr <= LEVEL_ORDER_BASE + {4'd0, wram_rdata, 1'b0};
                    state    <= SONIC_ROM;
                end
            end
            SONIC_ROM: if (rom_ack) begin
                rom_req    <= 1'b0;
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hf06e >> 1;
                // The cache returns the word holding the requested byte with
                // the even address in the low lane; table entries are stored
                // high byte first.
                wram_wdata <= {rom_data[7:0], rom_data[15:8]};
                wram_be    <= 2'b11;
                state      <= SONIC_LEVEL;
            end
            SONIC_LEVEL: if (wram_ack) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hf0bc >> 1;
                wram_wdata <= 16'h0000;
                wram_be    <= 2'b11;
                state      <= SONIC_STATUS0;
            end
            SONIC_STATUS0: if (wram_ack) begin
                wram_req   <= 1'b1;
                wram_we    <= 1'b1;
                wram_addr  <= 16'hf0be >> 1;
                wram_wdata <= 16'h0000;
                wram_be    <= 2'b11;
                state      <= SONIC_STATUS1;
            end
            SONIC_STATUS1: if (wram_ack) begin
                wram_req <= 1'b0;
                wram_we  <= 1'b0;
                state    <= SONIC_IDLE;
            end
            default: begin
                state    <= SONIC_IDLE;
                rom_req  <= 1'b0;
                wram_req <= 1'b0;
            end
        endcase
    end
end

endmodule

// ---------------------------------------------------------------------------
//  s32_v25: protection MCU subsystem (§8.1) — ga2 / arabfgt
//  v1 strategy per DESIGN.md: HLE responder implementing the documented
//  wakeup/command protocol through the MB8421 dual-port RAM at 0xA00000,
//  carrying the real opcode-decrypt tables for the future full-core swap.
//  The 64KB descrambled program is loaded to BRAM by the ROM loader; a
//  full V30-family core drops in behind this interface (M-next).
// ---------------------------------------------------------------------------
module s32_v25 (
    input             clk,
    input             rst,
    input             enable,
    input             table_sel,    // 0 = ga2, 1 = arabfgt

    // program BRAM load port (from loader, descrambled)
    input             prg_wr,
    input      [15:0] prg_waddr,
    input       [7:0] prg_wdata,

    // V60-side DPRAM access (0xA00000-0xA00FFF, low byte lanes)
    input             cs,
    input             we,
    input      [11:1] addr,
    input       [7:0] wdata,
    output      [7:0] rdata
);

// The mailbox HLE does not model V25 program memory: prg_wr/prg_waddr/prg_wdata
// are accepted for interface symmetry with the real s32_v25_cpu core (which uses
// them to invalidate its decode cache) but carry no storage here.  A prior
// write-only 64 KiB array was never read anywhere in the RTL and has been
// removed so it can no longer be misread as a live program store (audit hygiene).

// MB8421 mailbox RAM.  The HLE currently owns only the V60-side port, but an
// explicit true-dual-port block preserves the physical interface for a future
// MCU core without paying 16K flip-flops in the GA2 build.
wire [7:0] dpram_q;
s32_byte_spram #(.ADDR_WIDTH(11), .NUM_WORDS(2048), .POWER_UP_UNINITIALIZED("FALSE")) dpram_mem ( // audit R20 PF-8: deterministic zero power-up
    .clock(clk),
    .address_a(addr), .data_a(wdata), .rden_a(enable && cs),
    .wren_a(enable && cs && we), .q_a(dpram_q)
);

// HLE: wakeup string + echo protocol (MAME simulation fallback)
//   ga2:  "wake up! GOLDEN AXE The Revenge of Death-Adder! "
//   arf:  "wake up! ARF!                                   "
// The V25 firmware fills DPRAM offset 0 with the string, then serves
// command/response tables. v1 provides the string + the ga2 sprite
// expansion results table (prot[16] from MAME).
function automatic [7:0] wake_ga2(input [5:0] i);
    case (i)
        6'd0:  wake_ga2 = "w"; 6'd1:  wake_ga2 = "a"; 6'd2:  wake_ga2 = "k";
        6'd3:  wake_ga2 = "e"; 6'd4:  wake_ga2 = " "; 6'd5:  wake_ga2 = "u";
        6'd6:  wake_ga2 = "p"; 6'd7:  wake_ga2 = "!"; 6'd8:  wake_ga2 = " ";
        6'd9:  wake_ga2 = "G"; 6'd10: wake_ga2 = "O"; 6'd11: wake_ga2 = "L";
        6'd12: wake_ga2 = "D"; 6'd13: wake_ga2 = "E"; 6'd14: wake_ga2 = "N";
        6'd15: wake_ga2 = " "; 6'd16: wake_ga2 = "A"; 6'd17: wake_ga2 = "X";
        6'd18: wake_ga2 = "E"; 6'd19: wake_ga2 = " "; 6'd20: wake_ga2 = "T";
        6'd21: wake_ga2 = "h"; 6'd22: wake_ga2 = "e"; 6'd23: wake_ga2 = " ";
        6'd24: wake_ga2 = "R"; 6'd25: wake_ga2 = "e"; 6'd26: wake_ga2 = "v";
        6'd27: wake_ga2 = "e"; 6'd28: wake_ga2 = "n"; 6'd29: wake_ga2 = "g";
        6'd30: wake_ga2 = "e"; 6'd31: wake_ga2 = " "; 6'd32: wake_ga2 = "o";
        6'd33: wake_ga2 = "f"; 6'd34: wake_ga2 = " "; 6'd35: wake_ga2 = "D";
        6'd36: wake_ga2 = "e"; 6'd37: wake_ga2 = "a"; 6'd38: wake_ga2 = "t";
        6'd39: wake_ga2 = "h"; 6'd40: wake_ga2 = "-"; 6'd41: wake_ga2 = "A";
        6'd42: wake_ga2 = "d"; 6'd43: wake_ga2 = "d"; 6'd44: wake_ga2 = "e";
        6'd45: wake_ga2 = "r"; 6'd46: wake_ga2 = "!"; 6'd47: wake_ga2 = " ";
        default: wake_ga2 = " ";
    endcase
endfunction
function automatic [7:0] wake_arf(input [5:0] i);
    case (i)
        6'd0: wake_arf = "w"; 6'd1: wake_arf = "a"; 6'd2: wake_arf = "k";
        6'd3: wake_arf = "e"; 6'd4: wake_arf = " "; 6'd5: wake_arf = "u";
        6'd6: wake_arf = "p"; 6'd7: wake_arf = "!"; 6'd8: wake_arf = " ";
        6'd9: wake_arf = "A"; 6'd10: wake_arf = "R"; 6'd11: wake_arf = "F";
        6'd12: wake_arf = "!";
        default: wake_arf = " ";
    endcase
endfunction

// ga2 sprite-expansion result table (MAME prot[16])
function automatic [7:0] ga2_prot(input [3:0] i);
    case (i)
        4'd0:  ga2_prot = 8'h0a; 4'd2:  ga2_prot = 8'hc5;
        4'd4:  ga2_prot = 8'h11; 4'd6:  ga2_prot = 8'h11;
        4'd8:  ga2_prot = 8'h18; 4'd10: ga2_prot = 8'h18;
        4'd12: ga2_prot = 8'h1f; 4'd14: ga2_prot = 8'hc6;
        default: ga2_prot = 8'h00;
    endcase
endfunction

// Capture the address on the same edge as the RAM read.  The wrapper q and
// this selector then become visible together, preserving the original single
// synchronous-read cycle without adding a second output register.
reg [11:1] rd_addr;
reg        rd_table_sel;
always @(posedge clk) begin
    if (enable && cs) begin
        rd_addr      <= addr;
        rd_table_sel <= table_sel;
    end
end

// Window layout proven from the ga2 V60 boot code (loop at 0x1009ce):
// the game polls byte 0xA00100 for 'w' then string-compares 0x30 bytes
// against its ROM copy at 0x1009FF, so the wakeup string is byte window
// 0x100-0x15F (word index 0x80-0xAF); the sprite-expansion results table is
// byte window 0x000-0x01F.  rd_addr retains the input's [11:1] naming, so
// rd_addr[6:1] is the six-bit character offset.
assign rdata = (rd_addr >= 11'h80 && rd_addr < 11'hB0)
             ? (rd_table_sel ? wake_arf(rd_addr[6:1])
                             : wake_ga2(rd_addr[6:1]))
             : (!rd_table_sel && rd_addr < 11'h10)
             ? ga2_prot(rd_addr[4:1])
             : dpram_q;

endmodule


// ---------------------------------------------------------------------------
//  Air Rescue DSP register HLE (single-board reduction)
//  MAME segas32_m.cpp maps the uPD7725-facing register block at
//  0xa00000-0xa00007. The production RTL retains the documented register
//  protocol while the external DSP program/second PCB remain outside this
//  reduced one-screen profile.
// ---------------------------------------------------------------------------
module s32_prot_arescue_dsp (
    input             clk,
    input             rst,
    input             enable,
    input             cpu_rd,
    input             cpu_wr,
    input       [1:0] addr,
    input      [15:0] wdata,
    input       [1:0] be,
    output reg [15:0] rdata
);

reg [15:0] io0;
reg [15:0] io1;
reg [15:0] io2;
reg [15:0] io3;

// MAME arescue_dsp_w uses COMBINE_DATA, so each CPU byte lane is retained.
// arescue_dsp_r(offset=2) performs the command side effects before returning
// the offset-2 word: command 3 publishes io0=0x8000 and io1=1, command 6
// publishes io0=4*io1, and all other commands leave the registers unchanged.
always @(posedge clk) begin
    if (rst || !enable) begin
        io0 <= 16'h0000;
        io1 <= 16'h0000;
        io2 <= 16'h0000;
        io3 <= 16'h0000;
    end
    else begin
        if (cpu_wr) begin
            case (addr)
                2'd0: begin
                    if (be[0]) io0[7:0]  <= wdata[7:0];
                    if (be[1]) io0[15:8] <= wdata[15:8];
                end
                2'd1: begin
                    if (be[0]) io1[7:0]  <= wdata[7:0];
                    if (be[1]) io1[15:8] <= wdata[15:8];
                end
                2'd2: begin
                    if (be[0]) io2[7:0]  <= wdata[7:0];
                    if (be[1]) io2[15:8] <= wdata[15:8];
                end
                default: begin
                    if (be[0]) io3[7:0]  <= wdata[7:0];
                    if (be[1]) io3[15:8] <= wdata[15:8];
                end
            endcase
        end

        if (cpu_rd && (addr == 2'd2)) begin
            case (io0)
                16'h0003: begin
                    io0 <= 16'h8000;
                    io1 <= 16'h0001;
                end
                16'h0006: io0 <= {io1[13:0], 2'b00};
                default: ;
            endcase
        end
    end
end

always @(*) begin
    rdata = 16'h0000;
    if (enable) begin
        case (addr)
            2'd0: rdata = io0;
            2'd1: rdata = io1;
            2'd2: rdata = io2;
            default: rdata = io3;
        endcase
    end
end

endmodule
