//============================================================================
//  93C46 serial EEPROM, 16-bit organisation (64 words x 16 bits)
//
//  The F3 board wires one of these to the control port at 0x4a0010: the CPU
//  drives CS/CLK/DI through the low byte there and reads DO back in bit 0 of
//  every control-port longword (taito_f3.cpp EEPROMOUT / EEPROMIN).
//
//  Why a real implementation and not a stub: the boot code reads the EEPROM
//  before it draws anything. A stub that answers wrong can send the program
//  into its "bad settings" path, or into a retry loop, and the failure looks
//  exactly like a broken CPU or a broken video chip. Sixty lines here removes
//  a whole class of false leads later.
//
//  Protocol (Microchip 93C46, ORG=1):
//      CS high, then on each rising CLK the chip shifts DI in.
//      A command is a leading 1, two opcode bits, six address bits:
//        10 aaaaaa           READ   -> DO = 0 (dummy) then 16 data bits
//        01 aaaaaa dddd...   WRITE  (needs a prior EWEN)
//        11 aaaaaa           ERASE  (needs a prior EWEN)
//        00 00xxxx           EWDS   write disable
//        00 01xxxx           WRAL   write all
//        00 10xxxx           ERAL   erase all
//        00 11xxxx           EWEN   write enable
//      DO is high when idle/ready, which is what the ready poll after a
//      write looks for.
//
//  NVRAM (2026-08-28): the array is loaded from and saved to MiSTer's
//  config/nvram/<mra>.nvm through hps_io's ioctl channel on index 254 (the
//  MRA's <nvram index="254" size="128"/>). Two ports for that:
//
//    ld_wr / ld_addr / ld_data   the load, during the download
//    sv_addr -> sv_data          the save, read back word by word
//    wrote                       a pulse whenever the GAME changes a word,
//                                which is what asks MiSTer for a save
//
//  The array is NOT cleared on reset any more. It could not be: the load
//  arrives while the core is held in reset by the download, so a reset
//  clear would wipe exactly the data being loaded. It powers up erased
//  (the initial block) and MiSTer's default file is FF FF anyway.
//============================================================================

module rf_eeprom_93c46
#(
    parameter integer CLK_HZ = 32000000
)
(
    input  logic        clk,
    input  logic        reset,

    input  logic        cs,
    input  logic        sk,          // clock, sampled for a rising edge here
    input  logic        di,
    output logic        do_out,

    // ---- NVRAM (hps_io ioctl index 254) ---------------------------------
    input  logic        ld_wr,       // load: one word from the download
    input  logic  [5:0] ld_addr,
    input  logic [15:0] ld_data,
    input  logic  [5:0] sv_addr,     // save: read back for the upload
    output logic [15:0] sv_data,
    output logic        wrote        // the game changed a word (pulse)
);
    // WRAL/ERAL change a shared fill word and invalidate individual overrides.
    // This preserves their single-clock behavior without 64 parallel RAM writes.
    // Both state elements persist across reset, like the original EEPROM array.
    logic [15:0] fill_word = 16'hFFFF;
    logic [63:0] word_written = 64'b0;
    (* ramstyle="MLAB, no_rw_check" *) logic [15:0] mem [0:63];
    assign sv_data = word_written[sv_addr] ? mem[sv_addr] : fill_word;
    logic [15:0] sr;                 // shift register, command then data
    logic  [5:0] bitcnt;
    logic        wen;                // set by EWEN, cleared by EWDS
    logic        cs_d, sk_d;
    logic        shifting_out;
    logic [16:0] dout_sr;            // {dummy 0, data}: READ emits a 0 first
    logic  [4:0] out_cnt;
    logic  [5:0] cmd_addr;
    logic  [1:0] cmd_op;
    logic        have_cmd;
    logic        program_wait;

    // MAME 0.289 eeprom.cpp: ERASE 1 ms, WRITE 1.75 ms, ERAL/WRAL 8 ms.
    // Widen the constant arithmetic before multiplication (32 MHz * 8000
    // exceeds 32 bits). The physical EEPROM has no reset pin: programming
    // time, like its cells, continues across a board reset.
    localparam integer BUSY_BITS = $clog2((64'd8000 * CLK_HZ + 999999) / 1000000 + 1);
    localparam logic [BUSY_BITS-1:0] ERASE_TICKS =
        BUSY_BITS'((64'd1000 * CLK_HZ + 999999) / 1000000);
    localparam logic [BUSY_BITS-1:0] WRITE_TICKS =
        BUSY_BITS'((64'd1750 * CLK_HZ + 999999) / 1000000);
    localparam logic [BUSY_BITS-1:0] ALL_TICKS =
        BUSY_BITS'((64'd8000 * CLK_HZ + 999999) / 1000000);
    logic [BUSY_BITS-1:0] busy_ticks = '0;

    wire sk_rise = sk && !sk_d;
    wire cs_rise = cs && !cs_d;

    // The bit arriving on this clock is not in `sr` yet, so the completed
    // command / data word is the register plus that bit. Kept as wires, not
    // `automatic` locals: quartus_map 17.0 is unreliable with procedural
    // automatics in this design (see the note in rayforce_video.sv).
    wire [7:0]  cmd_w  = {sr[6:0],  di};
    wire [15:0] data_w = {sr[14:0], di};

    // A READ answers with a dummy 0 on the clock after the last address bit,
    // THEN the 16 data bits MSB first (93C46 datasheet, and eepromser.cpp).
    // Without the dummy the whole word arrives one bit early and reads back
    // rotated -- which the boot code would treat as corrupt settings.
    // The completing transaction remains tri-stated until CS falls. On
    // reselect, WAIT_FOR_START_BIT exposes BUSY (0), then READY (1), exactly
    // as eeprom_serial_93cxx_device::do_read(). Starting a command or a READ
    // leaves this status state; CS low always has the pull-up value.
    wire waiting_start = cs && !program_wait && !shifting_out &&
                         !have_cmd && bitcnt == 6'd0;
    assign do_out = shifting_out ? dout_sr[16] :
                    waiting_start ? (busy_ticks == 0) : 1'b1;

    wire command_edge = !reset && cs && sk_rise && !program_wait && !shifting_out &&
                        !have_cmd && bitcnt == 6'd8;
    wire data_edge = !reset && cs && sk_rise && !program_wait && !shifting_out &&
                     have_cmd && bitcnt == 6'd15;
    wire erase_word = wen && command_edge && cmd_w[7:6] == 2'b11;
    wire write_word = wen && data_edge && cmd_op == 2'b01;
    wire erase_all = wen && command_edge && cmd_w[7:6] == 2'b00 &&
                     cmd_w[5:4] == 2'b10;
    wire write_all = wen && data_edge && cmd_op == 2'b00 && cmd_addr[5:4] == 2'b01;
    wire word_write = ld_wr || erase_word || write_word;
    wire [5:0] word_address = ld_wr ? ld_addr : erase_word ? cmd_w[5:0] : cmd_addr;
    wire [15:0] word_data = ld_wr ? ld_data : erase_word ? 16'hFFFF : data_w;
    wire [15:0] serial_read = word_written[cmd_w[5:0]] ? mem[cmd_w[5:0]] : fill_word;

    always_ff @(posedge clk) begin
        if (erase_all || write_all) busy_ticks <= ALL_TICKS;
        else if (erase_word) busy_ticks <= ERASE_TICKS;
        else if (write_word) busy_ticks <= WRITE_TICKS;
        else if (busy_ticks != 0) busy_ticks <= busy_ticks - 1'b1;
    end

    // One shared write port; the load retains priority over game writes.
    always_ff @(posedge clk) begin
        if (word_write) mem[word_address] <= word_data;
        if (erase_all || write_all) begin
            fill_word <= erase_all ? 16'hFFFF : data_w;
            word_written <= 64'b0;
        end
        if (word_write) word_written[word_address] <= 1'b1;
    end

    always_ff @(posedge clk) begin
        cs_d  <= cs;
        sk_d  <= sk;
        wrote <= 1'b0;

        if (reset) begin
            bitcnt       <= 6'd0;
            wen          <= 1'b0;
            have_cmd     <= 1'b0;
            shifting_out <= 1'b0;
            program_wait <= 1'b0;
        end else begin
            if (!cs) begin
                // deselect ends whatever was in flight
                bitcnt       <= 6'd0;
                have_cmd     <= 1'b0;
                shifting_out <= 1'b0;
                program_wait <= 1'b0;
            end else begin
                if (cs_rise) begin
                    bitcnt       <= 6'd0;
                    have_cmd     <= 1'b0;
                    shifting_out <= 1'b0;
                    program_wait <= 1'b0;
                end

                if (sk_rise && !program_wait) begin
                    if (shifting_out) begin
                        // READ: one bit per clock, MSB first.
                        dout_sr <= {dout_sr[15:0], 1'b0};
                    end else if (!have_cmd) begin
                        // hunt for the leading 1, then take 8 more bits
                        if (bitcnt == 6'd0) begin
                            if (di) bitcnt <= 6'd1;
                        end else begin
                            sr     <= {sr[14:0], di};
                            bitcnt <= bitcnt + 6'd1;
                            if (bitcnt == 6'd8) begin
                                // sr now holds op[1:0], addr[5:0] in bits 7:0
                                cmd_op   <= cmd_w[7:6];
                                cmd_addr <= cmd_w[5:0];
                                have_cmd <= 1'b1;
                                bitcnt   <= 6'd0;
                                case (cmd_w[7:6])
                                    2'b10: begin                 // READ
                                        dout_sr      <= {1'b0, serial_read};
                                        shifting_out <= 1'b1;
                                    end
                                    2'b11: begin                 // ERASE
                                        program_wait <= 1'b1;
                                        if (wen) begin
                                            wrote <= 1'b1;
                                        end
                                    end
                                    2'b00: case (cmd_w[5:4])     // control group
                                        2'b00: wen <= 1'b0;      // EWDS
                                        2'b11: wen <= 1'b1;      // EWEN
                                        2'b10: begin             // ERAL
                                            program_wait <= 1'b1;
                                            if (wen) wrote <= 1'b1;
                                        end
                                        default: ;               // WRAL handled on data
                                    endcase
                                    default: ;                   // WRITE: data follows
                                endcase
                            end
                        end
                    end else begin
                        // command taken; WRITE/WRAL clock in 16 data bits
                        sr     <= {sr[14:0], di};
                        bitcnt <= bitcnt + 6'd1;
                        if (bitcnt == 6'd15) begin
                            program_wait <= 1'b1;
                            if (wen) begin
                                if (cmd_op == 2'b01) begin
                                    wrote <= 1'b1;
                                end else if (cmd_op == 2'b00 && cmd_addr[5:4] == 2'b01) begin
                                    wrote <= 1'b1;
                                end
                            end
                            bitcnt   <= 6'd0;
                            have_cmd <= 1'b0;
                        end
                    end
                end
            end
        end

        // NVRAM load priority is implemented in the shared memory write port.
    end

endmodule
