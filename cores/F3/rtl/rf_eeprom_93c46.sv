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

module rf_eeprom_93c46 #(parameter SYNC_STORAGE=0)
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
    // SYNC_STORAGE save reads have one clock latency. The live snapshot
    // sequencer waits for this read. During ld_wr the save port is occupied
    // by the download; upload and download are separate host transactions.
    wire [15:0] serial_data;
    logic read_pending;
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

    wire sk_rise = sk && !sk_d;
    wire cs_rise = cs && !cs_d;

    // The bit arriving on this clock is not in `sr` yet, so the completed
    // command / data word is the register plus that bit. Kept as wires, not
    // `automatic` locals: quartus_map 17.0 is unreliable with procedural
    // automatics in this design (see the note in rayforce_video.sv).
    wire [7:0]  cmd_w  = {sr[6:0],  di};
    wire [15:0] data_w = {sr[14:0], di};

    logic word_we, bulk_we;
    logic [5:0] word_addr;
    logic [15:0] word_data, bulk_data;
    // Derive storage events on the original commit edge. A simultaneous
    // host load overrides a game write to the same address; different
    // addresses retain both writes, as in the original array implementation.
    always_comb begin
        word_we=0;bulk_we=0;word_addr=cmd_addr;word_data=data_w;bulk_data=data_w;
        if(!reset && cs && sk_rise && !shifting_out && wen)begin
            if(!have_cmd && bitcnt==8)begin
                if(cmd_w[7:6]==2'b11)begin word_we=1;word_addr=cmd_w[5:0];word_data=16'hffff;end
                if(cmd_w[7:6]==2'b00 && cmd_w[5:4]==2'b10)begin bulk_we=1;bulk_data=16'hffff;end
            end else if(have_cmd && bitcnt==15)begin
                if(cmd_op==2'b01)word_we=1;
                if(cmd_op==2'b00 && cmd_addr[5:4]==2'b01)bulk_we=1;
            end
        end
    end
    generate if(SYNC_STORAGE)begin: native_storage
        // Bulk operations change the default and invalidate overrides in
        // one clock: no serial scrub and no change to command completion.
        logic [63:0] valid=0;
        logic [15:0] bulk=16'hffff;
        logic serial_valid,save_valid;
        logic [15:0] serial_bulk,save_bulk;
        wire [15:0] serial_q,save_q;
        wire game_we=word_we && !(ld_wr && ld_addr==word_addr);
        wire [5:0] port_a_addr=game_we?word_addr:cmd_w[5:0];
        rf_eeprom_storage storage(.clk(clk),.a_addr(port_a_addr),.a_data(word_data),.a_we(game_we),.a_q(serial_q),
            .b_addr(ld_wr?ld_addr:sv_addr),.b_data(ld_data),.b_we(ld_wr),.b_q(save_q));
        always_ff @(posedge clk)begin
            serial_valid<=valid[cmd_w[5:0]];serial_bulk<=bulk;
            save_valid<=valid[sv_addr];save_bulk<=bulk;
            if(bulk_we)begin valid<=0;bulk<=bulk_data;end
            if(word_we)valid[word_addr]<=1;
            if(ld_wr)valid[ld_addr]<=1;
        end
        assign serial_data=serial_valid?serial_q:serial_bulk;
        assign sv_data=save_valid?save_q:save_bulk;
    end else begin: legacy_storage
        logic [15:0] mem[0:63];
        initial begin for(integer n=0;n<64;n=n+1)mem[n]=16'hffff;end
        assign serial_data=mem[cmd_w[5:0]];
        assign sv_data=mem[sv_addr];
        always_ff @(posedge clk)begin
            if(bulk_we)for(integer n=0;n<64;n=n+1)mem[n]<=bulk_data;
            if(word_we)mem[word_addr]<=word_data;
            if(ld_wr)mem[ld_addr]<=ld_data;
        end
    end endgenerate

    // A READ answers with a dummy 0 on the clock after the last address bit,
    // THEN the 16 data bits MSB first (93C46 datasheet, and eepromser.cpp).
    // Without the dummy the whole word arrives one bit early and reads back
    // rotated -- which the boot code would treat as corrupt settings.
    assign do_out = shifting_out ? dout_sr[16] : 1'b1;

    always_ff @(posedge clk) begin
        cs_d  <= cs;
        sk_d  <= sk;
        wrote <= 1'b0;
        read_pending<=0;
        // A sampled SK rising edge necessarily has a sampled low cycle
        // before the next rise. Fill the word during that cycle, retaining
        // the original immediate dummy zero and first-data-bit timing.
        if(SYNC_STORAGE && read_pending)dout_sr<={1'b0,serial_data};

        if (reset) begin
            bitcnt       <= 6'd0;
            wen          <= 1'b0;
            have_cmd     <= 1'b0;
            shifting_out <= 1'b0;
        end else begin
            if (!cs) begin
                // deselect ends whatever was in flight
                bitcnt       <= 6'd0;
                have_cmd     <= 1'b0;
                shifting_out <= 1'b0;
            end else begin
                if (cs_rise) begin
                    bitcnt       <= 6'd0;
                    have_cmd     <= 1'b0;
                    shifting_out <= 1'b0;
                end

                if (sk_rise) begin
                    if (shifting_out) begin
                        // READ: one bit per clock, MSB first, then it wraps
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
                                        if(SYNC_STORAGE)begin dout_sr<=0;read_pending<=1;end
                                        else dout_sr <= {1'b0, serial_data};
                                        shifting_out <= 1'b1;
                                    end
                                    2'b11: begin                 // ERASE
                                        if (wen) begin
                                            wrote <= 1'b1;
                                        end
                                    end
                                    2'b00: case (cmd_w[5:4])     // control group
                                        2'b00: wen <= 1'b0;      // EWDS
                                        2'b11: wen <= 1'b1;      // EWEN
                                        2'b10: if (wen) begin    // ERAL
                                            wrote <= 1'b1;
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

    end

endmodule

// True dual-port, common-clock memory: independent game and host writes.
// Same-address writes are resolved before this primitive (host wins).
module rf_eeprom_storage(input wire clk,input wire [5:0] a_addr,b_addr,
    input wire [15:0] a_data,b_data,input wire a_we,b_we,output wire [15:0] a_q,b_q);
`ifdef VERILATOR
    reg [15:0] mem[0:63];reg [15:0] qa,qb;
    always @(posedge clk)begin
        if(a_we && b_we && a_addr==b_addr)$fatal(1,"EEPROM native same-address write collision");
        qa<=mem[a_addr];qb<=mem[b_addr];
        if(a_we)mem[a_addr]<=a_data;
        if(b_we)mem[b_addr]<=b_data;
    end
    assign a_q=qa;assign b_q=qb;
`else
    altsyncram #(.operation_mode("BIDIR_DUAL_PORT"),.width_a(16),.widthad_a(6),.numwords_a(64),
        .width_b(16),.widthad_b(6),.numwords_b(64),.address_reg_b("CLOCK0"),.indata_reg_b("CLOCK0"),
        .wrcontrol_wraddress_reg_b("CLOCK0"),.outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),.lpm_type("altsyncram"),
        .intended_device_family("Cyclone V")) r(
        .clock0(clk),.clock1(1'b1),.address_a(a_addr),.data_a(a_data),.wren_a(a_we),.q_a(a_q),
        .address_b(b_addr),.data_b(b_data),.wren_b(b_we),.q_b(b_q),.byteena_a(1'b1),.byteena_b(1'b1),
        .rden_a(1'b1),.rden_b(1'b1),.aclr0(1'b0),.aclr1(1'b0),.addressstall_a(1'b0),.addressstall_b(1'b0),
        .clocken0(1'b1),.clocken1(1'b1),.clocken2(1'b1),.clocken3(1'b1),.eccstatus());
`endif
endmodule
