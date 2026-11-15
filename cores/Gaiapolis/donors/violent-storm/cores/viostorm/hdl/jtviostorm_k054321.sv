// K054321 main-CPU / sound-CPU communication latch.
//
// The register contract is pinned to MAME 0.289's devices/sound/k054321.cpp
// and is kept behind a title-local wrapper so the later Z80/K054539 work can
// change without touching the main-bus decoder.  The state is intentionally
// digital: the analog speaker gain is a separate, not-yet-implemented path.
module jtviostorm_k054321(
    input        clk,
    input        rst,

    input        main_we,
    input  [3:0] main_addr,       // 68000 word offset in 0x268000..0x26801f
    input  [7:0] main_din,
    output reg [7:0] main_dout,

    input        sound_we,
    input  [1:0] sound_addr,      // Z80 offsets 0, 2, and 3
    input  [7:0] sound_din,
    output reg [7:0] sound_dout,

    input        irq_set,
    input        sound_iack,
    output reg   irq_n,

    output reg [7:0] active,
    output reg [6:0] volume
);

    reg [7:0] snd_latch0;
    reg [7:0] snd_latch1;
    reg [7:0] snd_latch2;

    always @* begin
        case (main_addr)
            4'h8: main_dout = 8'h00; // busy_r: bit 0 is not busy
            4'ha: main_dout = snd_latch2; // offset A in the MAME word map
            default: main_dout = 8'h00;
        endcase
    end

    always @* begin
        case (sound_addr)
            2'd2: sound_dout = snd_latch0;
            2'd3: sound_dout = snd_latch1;
            default: sound_dout = 8'h00;
        endcase
    end

    // main_we and irq_set are 68000 bus-cycle levels that span several clk
    // periods. volume_up_w and the IRQ request are once-per-write events, so
    // both act on the rising edge (as jt054321 does for snd_on).
    reg main_we_l, irq_set_l;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active    <= 8'h00;
            volume    <= 7'd0;
            snd_latch0 <= 8'h00;
            snd_latch1 <= 8'h00;
            snd_latch2 <= 8'h00;
            irq_n     <= 1'b1;
            main_we_l <= 1'b0;
            irq_set_l <= 1'b0;
        end else begin
            main_we_l <= main_we;
            irq_set_l <= irq_set;

            if (irq_set && !irq_set_l)
                irq_n <= 1'b0;
            else if (sound_iack)
                irq_n <= 1'b1;

            if (main_we && !main_we_l) begin
                case (main_addr)
                    4'h0: active     <= main_din;
                    4'h2: volume     <= 7'd0;
                    4'h3: if (main_din != 8'h00 && volume < 7'd64)
                               volume <= volume + 7'd1;
                    4'h6: snd_latch0 <= main_din;
                    4'h7: snd_latch1 <= main_din;
                    default: ; // dummy/unknown offsets have no state effect
                endcase
            end
            if (sound_we && sound_addr == 2'd0)
                snd_latch2 <= sound_din;
        end
    end
endmodule
