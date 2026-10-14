// hardhea2/brickzn's separate PCM Z80 (suna8.cpp's brickzn_pcm_map/
// brickzn_pcm_io_map): "PCM Z80, 4 DACs (4 bits per sample), NO RAM !!"
// per suna8.cpp's own comment. A third, independent Z80 core -- not a
// variant of the main or sound CPU's memory map -- fed commands via
// soundlatch2 (the sound Z80's own f000 write, brickzn_sound_map,
// already captured as soundlatch2_q in suna8_sound_memory.sv but
// unconsumed until now), driving four DAC_4BIT_R2R chips (ldac/rdac/
// ldac2/rdac2) that all sum into the same single mono speaker output
// (SPEAKER(config,"speaker").front_center() in suna8.cpp -- the "l"/"r"
// naming reflects the PCB's DAC labeling, not a real stereo split).
//
// No RAM at all: brickzn_pcm_map maps the FULL 0x0000-0xFFFF as ROM, so
// every memory access (opcode fetch and data read alike) goes to the
// same PCM ROM region uniformly -- no address decode needed beyond
// "is this a memory read". A write to memory space has nowhere to go on
// real hardware either (no .ram()/.w() anywhere in the map); this module
// simply doesn't implement one.
//
// brickzn_pcm_io_map: port 0x00 read = soundlatch2 (from the sound Z80);
// ports 0x00/01/02/03 write = ldac/rdac/ldac2/rdac2 respectively, each a
// dac_byte_interface::data_w feeding a DAC_4BIT_R2R -- MAME's
// dac_device_base::set_value() masks the write to the device's declared
// bit width ("m_value_map[value & (m_value_map.size()-1)]", size=16 for
// a 4-bit DAC), i.e. only the LOW nibble of the written byte reaches the
// DAC. dac_mapper_unsigned's linear unsigned-to-bipolar mapping
// (input/2^bits scaled into the device's default -1..1 range) reduces to
// signed_nibble = nibble - 8 = nibble ^ 4'b1000 -- the identical
// offset-binary/excess-8 -> two's-complement conversion already used for
// suna8_sound_chips.sv's SAMPLES device, so both are expressed the same
// way here for consistency.
module suna8_pcm
(
    input  logic clk,
    input  logic reset,           // held for the whole run on profiles
                                   // without this CPU (see suna8_core.sv)

    // PCM Z80 bus (suna8_main_cpu's port convention)
    input  logic [15:0] cpu_addr,
    input  logic [7:0] cpu_dout,
    output logic [7:0] cpu_din,
    input  logic cpu_mreq_n,
    input  logic cpu_iorq,
    input  logic cpu_rd_n,
    input  logic cpu_wr_n,

    // PCM ROM window (MEDIA_PCM, already-provisioned media plumbing --
    // see suna8_core.sv/suna8_rom_loader.sv/verif/suna8_sim_media.sv --
    // previously stubbed to a constant-zero address since nothing read
    // it, same as the SAMPLES ROM window was before this pass)
    output logic [15:0] pcm_media_read_addr,
    input  logic [7:0] pcm_media_read_q,

    // From the sound Z80's own f000 write (brickzn_sound_map, "To PCM
    // CPU") -- suna8_sound_memory.sv's soundlatch2_reg, already latched
    // there; this module only reads it, matching brickzn_pcm_io_map's
    // plain unlatched read (no ready/interrupt flag in that map).
    input  logic [7:0] soundlatch2_q,

    output logic signed [15:0] pcm_snd    // pre-summed, pre-saturated;
                                           // added as one more term into
                                           // suna8_sound_chips.sv's mixer
);

    // Every memory access is a ROM read -- no decode needed.
    assign pcm_media_read_addr = cpu_addr;

    logic io_read, io_write;
    // Z80 I/O cycles leave MREQ_n high; requiring the inactive memory strobe
    // keeps DAC port accesses distinct from memory transactions.
    assign io_read   = cpu_iorq && cpu_mreq_n && !cpu_rd_n;
    assign io_write  = cpu_iorq && cpu_mreq_n && !cpu_wr_n;

    always_comb begin
        if (io_read)
            cpu_din = soundlatch2_q;
        else
            cpu_din = pcm_media_read_q;
    end

    // global_mask(0xff) in brickzn_pcm_io_map -- only the low 8 address
    // bits are decoded, matching a real Z80 IO bus.
    logic signed [3:0] ldac_val, rdac_val, ldac2_val, rdac2_val;

    always_ff @(posedge clk) begin
        if (reset) begin
            ldac_val  <= 4'sd0;
            rdac_val  <= 4'sd0;
            ldac2_val <= 4'sd0;
            rdac2_val <= 4'sd0;
        end else if (io_write) begin
            case (cpu_addr[1:0])
                2'd0: ldac_val  <= $signed(cpu_dout[3:0] ^ 4'b1000);
                2'd1: rdac_val  <= $signed(cpu_dout[3:0] ^ 4'b1000);
                2'd2: ldac2_val <= $signed(cpu_dout[3:0] ^ 4'b1000);
                2'd3: rdac2_val <= $signed(cpu_dout[3:0] ^ 4'b1000);
            endcase
        end
    end

    // Each DAC's 4-bit signed value scaled to the top 4 bits of a 16-bit
    // signed sample (same {signed_nibble,12'b0} convention as the
    // SAMPLES device), summed in a wide accumulator and saturated --
    // matching suna8_sound_chips.sv's mixer style rather than truncating.
    logic signed [17:0] pcm_wide;
    assign pcm_wide = $signed({{2{ldac_val[3]}},  ldac_val,  12'b0}) +
                       $signed({{2{rdac_val[3]}},  rdac_val,  12'b0}) +
                       $signed({{2{ldac2_val[3]}}, ldac2_val, 12'b0}) +
                       $signed({{2{rdac2_val[3]}}, rdac2_val, 12'b0});

    always_comb begin
        if (pcm_wide > 18'sd32767)
            pcm_snd = 16'sd32767;
        else if (pcm_wide < -18'sd32768)
            pcm_snd = 16'sh8000;  // -32768; see suna8_sound_chips.sv's
                                  // mix_sat for why this can't be written as
                                  // a decimal signed 16-bit literal.
        else
            pcm_snd = pcm_wide[15:0];
    end

endmodule
