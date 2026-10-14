//============================================================================
//  Sega System 32 — ioctl ROM loader  (DESIGN.md §9.3)
//  Legacy stream layout (ioctl index 0):
//    [0x00..0x3f]  board descriptor (64 bytes)
//    [maincpu 2MB][soundcpu 4MB][tiles 4MB][multipcm 4MB][sprites up to 16MB]
//  OutRunners has no V25/MCU region, so the reserved MCU aperture is not
//  accepted and the stream jumps directly from MultiPCM to sprites. The MRA
//  pads each region to its fixed stream offset. Optimized MRAs use index 4
//  main, 5 sound, 6 tiles, 7 PCM and 9 sprites. A descriptor-only index-0
//  transfer is emitted last so reset is released after all regions complete.
//  ioctl index 2 = 93C46 default image (128 bytes).
//============================================================================

import s32_pkg::*;

module s32_rom_loader #(
    parameter WIDE=0,
    // System 32 has RF5C68 wave RAM but no MultiPCM ROM. Clear that unused
    // 64 KiB SDRAM aperture before releasing reset so inverted external wave
    // storage has deterministic logical 0xff power-up contents.
    parameter CLEAR_RF_WAVE=0
) (
    input             clk,
    input             rst,
    input             mem_ready,

    input             ioctl_download,
    input       [7:0] ioctl_index,
    input             ioctl_wr,
    input      [26:0] ioctl_addr,
    input      [15:0] ioctl_dout,
    output            ioctl_wait,

    // board descriptor out
    output board_desc_t board_desc,

    // SDRAM write port
    output reg        sdr_wr_req,
    output reg [24:1] sdr_wr_addr,
    output reg [15:0] sdr_wr_din,
    output reg  [1:0] sdr_wr_be,
    input             sdr_wr_ack,

    // V25 program BRAM write port (64KB)
    output reg        v25_wr,
    output reg [15:0] v25_waddr,
    output reg  [7:0] v25_wdata,

    // EEPROM default image write port (64 x 16)
    output reg        eep_wr,
    output reg  [5:0] eep_waddr,
    output reg [15:0] eep_wdata,
    output reg        eep_loaded,

    output reg        rom_loaded
);

// stream region boundaries (byte offsets within index-0 stream)
localparam [26:0] OFF_DESC     = 27'h000_0000;
localparam [26:0] OFF_MAINCPU  = 27'h000_0040;
localparam [26:0] OFF_SOUNDCPU = OFF_MAINCPU  + 27'h20_0000;
localparam [26:0] OFF_TILES    = OFF_SOUNDCPU + 27'h40_0000;
localparam [26:0] OFF_MULTIPCM = OFF_TILES    + 27'h40_0000;
localparam [26:0] OFF_MCU      = OFF_MULTIPCM + 27'h40_0000;
localparam [26:0] OFF_SPRITES  = OFF_MCU      + 27'h1_0000;
localparam [26:0] OFF_END      = OFF_SPRITES  + 27'h100_0000;

reg [7:0]  desc_bytes [0:15];
reg [7:0]  byte_lo;
reg        busy;
`ifdef SIMULATION
reg [26:0] dl_addr_last;   // last accepted index-0 stream address (see below)
`endif
reg        index0_seen;
reg        wave_clear_active;
reg [14:0] wave_clear_word;
integer    desc_i;

// Hold the MiSTer host off until the SDRAM controller has completed its JEDEC
// power-up sequence. Accepting descriptor or ROM bytes earlier desynchronises
// the fixed stream because those writes cannot yet be serviced.
assign ioctl_wait = busy | wave_clear_active | ~mem_ready;

// map stream offset -> sdram byte address
function automatic [24:0] map_addr(input [26:0] a);
    if      (a < OFF_SOUNDCPU) map_addr = SDR_MAINCPU_BASE  + (a[24:0] - OFF_MAINCPU[24:0]);
    else if (a < OFF_TILES)    map_addr = SDR_SOUNDCPU_BASE + (a[24:0] - OFF_SOUNDCPU[24:0]);
    else if (a < OFF_MULTIPCM) map_addr = SDR_TILES_BASE    + (a[24:0] - OFF_TILES[24:0]);
    else if (a < OFF_MCU)      map_addr = SDR_MULTIPCM_BASE + (a[24:0] - OFF_MULTIPCM[24:0]);
    else                       map_addr = SDR_SPRITES_BASE + (a[24:0] - OFF_SPRITES[24:0]);
endfunction

function automatic is_rom_index(input [7:0] index);
    is_rom_index = (index == 8'd0) ||
                   (index == 8'd4) || (index == 8'd5) ||
                   (index == 8'd6) || (index == 8'd7) || (index == 8'd9);
endfunction

function automatic [26:0] stream_addr(input [7:0] index, input [26:0] a);
    case (index)
        8'd4: stream_addr = OFF_MAINCPU  + a;
        8'd5: stream_addr = OFF_SOUNDCPU + a;
        8'd6: stream_addr = OFF_TILES    + a;
        8'd7: stream_addr = OFF_MULTIPCM + a;
        8'd9: stream_addr = OFF_SPRITES  + a;
        default: stream_addr = a;
    endcase
endfunction

board_desc_t desc_r;
assign board_desc = desc_r;

always @(posedge clk) begin
    if (rst) begin
        sdr_wr_req <= 1'b0; sdr_wr_addr <= '0; sdr_wr_din <= '0; sdr_wr_be <= '0;
        v25_wr <= 1'b0; v25_waddr <= '0; v25_wdata <= '0;
        eep_wr <= 1'b0; eep_waddr <= '0; eep_wdata <= '0;
        eep_loaded <= 1'b0; rom_loaded <= 1'b0;
        byte_lo <= 8'd0; busy <= 1'b0; index0_seen <= 1'b0;
        wave_clear_active <= 1'b0; wave_clear_word <= 15'd0;
        desc_r <= '0;
        for (desc_i = 0; desc_i < 16; desc_i = desc_i + 1)
            desc_bytes[desc_i] <= 8'd0;
    end
    else begin
        v25_wr <= 1'b0;
        eep_wr <= 1'b0;

        if (sdr_wr_ack) begin
            sdr_wr_req <= 1'b0;
            busy       <= 1'b0;
            if (wave_clear_active) begin
                if (wave_clear_word == 15'h7fff) begin
                    wave_clear_active <= 1'b0;
                    rom_loaded <= 1'b1;
                    index0_seen <= 1'b0;
                end
                else
                    wave_clear_word <= wave_clear_word + 1'b1;
            end
        end

        // One full-word zero write per RF wave word. The RF interface stores
        // bytes inverted, so cleared SDRAM reads as logical 0xff. Re-arm only
        // after the controller's stretched ACK has returned low.
        if (wave_clear_active && !sdr_wr_req && !sdr_wr_ack) begin
            sdr_wr_req  <= 1'b1;
            sdr_wr_addr <= SDR_MULTIPCM_BASE[24:1] +
                           {9'b000000000, wave_clear_word};
            sdr_wr_din  <= 16'h0000;
            sdr_wr_be   <= 2'b11;
            busy        <= 1'b1;
        end

        // audit R20 PF-3: accept a new ioctl word only when the SDRAM write
        // mailbox is free (!busy); ioctl_wait (=busy) backpressures the HPS to
        // hold and re-present the word after sdr_wr_ack, so none is dropped.
        if (mem_ready && ioctl_download && ioctl_wr && !busy) begin
            if (is_rom_index(ioctl_index)) begin
                logic [26:0] a;
                a = stream_addr(ioctl_index, ioctl_addr);
`ifdef SIMULATION
                if (ioctl_index == 8'd0) dl_addr_last <= ioctl_addr;
`endif
                if (WIDE) begin
                    // WIDE=1 presents one little-endian 16-bit stream word at
                    // each even ioctl_addr. Preserve the exact fixed stream
                    // offsets and emit one full SDRAM word per transfer.
                    if (ioctl_index == 8'd0 && a < OFF_MAINCPU) begin
                        if (ioctl_addr[26:4] == 0) begin
                            desc_bytes[ioctl_addr[3:0]] <= ioctl_dout[7:0];
                            desc_bytes[ioctl_addr[3:0] + 1'b1] <= ioctl_dout[15:8];
                        end
                        if (ioctl_addr == OFF_MAINCPU-27'd2) begin
                            desc_r.multi32     <= desc_bytes[0][0];
                            // bit 1 was has_v25 (V25 MCU) -- OutRunners has none, byte kept reserved
                            // bit 2 was v25_table -- unused now
                            desc_r.has_adc     <= desc_bytes[0][3];
                            desc_r.has_ppi     <= desc_bytes[0][5];
                            desc_r.has_motor_hle <= desc_bytes[0][6];
                            desc_r.dual_pcb    <= desc_bytes[1][0];
                            // byte 2 bits 6:0 were prot_sel -- OutRunners is unprotected
                            desc_r.sprite_bank_valid <= desc_bytes[3][7];
                            desc_r.sprite_bank_mask  <= desc_bytes[3][1:0];
                            desc_r.flip_y            <= desc_bytes[1][1];
                            desc_r.gun_aim           <= desc_bytes[1][2];
                            desc_r.coin_swap         <= desc_bytes[1][3];
                            desc_r.analog_profile    <= desc_bytes[1][5:4];
                            desc_r.dual_comm_ff      <= desc_bytes[1][6];
                            desc_r.gear_toggle       <= desc_bytes[1][7];
                            desc_r.digital_profile   <= desc_bytes[4][1:0];
                            desc_r.game_profile      <= desc_bytes[4][4:2];
                            desc_r.comm_link_hle     <= desc_bytes[2][7];
                        end
                    end
                    else begin
                        sdr_wr_req <= 1'b1;
                        busy       <= 1'b1;
                        begin
                            logic [24:0] ma;
                            ma = map_addr(a);
                            sdr_wr_addr <= ma[24:1];
                        end
                        sdr_wr_din <= ioctl_dout;
                        sdr_wr_be  <= 2'b11;
                    end
                end
                else begin
                    // Byte-mode fallback retained for simulation and older
                    // host integrations. The live MiSTer top selects WIDE=1.
                    if (ioctl_index == 8'd0 && a < OFF_MAINCPU) begin
                        if (ioctl_addr[26:4] == 0) desc_bytes[ioctl_addr[3:0]] <= ioctl_dout[7:0];
                        if (ioctl_addr == OFF_MAINCPU-1) begin
                            desc_r.multi32     <= desc_bytes[0][0];
                            // bit 1 was has_v25 (V25 MCU) -- OutRunners has none, byte kept reserved
                            // bit 2 was v25_table -- unused now
                            desc_r.has_adc     <= desc_bytes[0][3];
                            desc_r.has_ppi     <= desc_bytes[0][5];
                            desc_r.has_motor_hle <= desc_bytes[0][6];
                            desc_r.dual_pcb    <= desc_bytes[1][0];
                            // byte 2 bits 6:0 were prot_sel -- OutRunners is unprotected
                            desc_r.sprite_bank_valid <= desc_bytes[3][7];
                            desc_r.sprite_bank_mask  <= desc_bytes[3][1:0];
                            desc_r.flip_y            <= desc_bytes[1][1];
                            desc_r.gun_aim           <= desc_bytes[1][2];
                            desc_r.coin_swap         <= desc_bytes[1][3];
                            desc_r.analog_profile    <= desc_bytes[1][5:4];
                            desc_r.dual_comm_ff      <= desc_bytes[1][6];
                            desc_r.gear_toggle       <= desc_bytes[1][7];
                            desc_r.digital_profile   <= desc_bytes[4][1:0];
                            desc_r.game_profile      <= desc_bytes[4][4:2];
                            desc_r.comm_link_hle     <= desc_bytes[2][7];
                        end
                    end
                    else begin
                        if (!ioctl_addr[0]) byte_lo <= ioctl_dout[7:0];
                        else begin
                            sdr_wr_req <= 1'b1;
                            busy       <= 1'b1;
                            begin
                                logic [24:0] ma;
                                ma = map_addr(a);
                                sdr_wr_addr <= ma[24:1];
                            end
                            sdr_wr_din <= {ioctl_dout[7:0], byte_lo};
                            sdr_wr_be  <= 2'b11;
                        end
                    end
                end
            end
            else if (ioctl_index == 8'd2 || ioctl_index == 8'd3) begin
                // The factory ROM image (2) stores each 93C46 x16 cell
                // big-endian. Persisted NVRAM (3) is our internal-word stream
                // and must round-trip unchanged.
                if (WIDE) begin
                    eep_wr     <= 1'b1;
                    eep_waddr  <= ioctl_addr[6:1];
                    eep_wdata  <= (ioctl_index == 8'd2)
                                ? {ioctl_dout[7:0], ioctl_dout[15:8]}
                                : ioctl_dout;
                    eep_loaded <= 1'b1;
                end
                else begin
                    if (!ioctl_addr[0]) byte_lo <= ioctl_dout[7:0];
                    else begin
                        eep_wr     <= 1'b1;
                        eep_waddr  <= ioctl_addr[6:1];
                        eep_wdata  <= (ioctl_index == 8'd2)
                                    ? {byte_lo, ioctl_dout[7:0]}
                                    : {ioctl_dout[7:0], byte_lo};
                        eep_loaded <= 1'b1;
                    end
                end
            end
        end

        // Only an actual index-0 transaction can change the boot gate. Wait
        // for its final SDRAM request to acknowledge before releasing reset.
        if (mem_ready && ioctl_download && ioctl_wr && ioctl_index == 8'd0 && ioctl_addr == 0) begin
            rom_loaded  <= 1'b0;
            eep_loaded  <= 1'b0;
            index0_seen <= 1'b1;
        end
        if (mem_ready && !ioctl_download && index0_seen &&
            !wave_clear_active && !busy && !sdr_wr_req) begin
            if (CLEAR_RF_WAVE) begin
                wave_clear_active <= 1'b1;
                wave_clear_word <= 15'd0;
            end
            else begin
                rom_loaded  <= 1'b1;
                index0_seen <= 1'b0;
            end
`ifdef SIMULATION
            // The byte-pairing above assumes every region is even-length (the
            // fixed MRA layout guarantees it).  An odd-length stream would
            // silently drop its parked final byte — make that loud in sim.
            if (!WIDE && dl_addr_last[0] == 1'b0)
                $display("LOADER WARNING: index-0 stream ended on an even address (odd length) — final parked byte was dropped");
`endif
        end
    end
end

endmodule
