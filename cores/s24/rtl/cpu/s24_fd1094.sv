// The FD1094 key table has one synchronous CPU read port and one HPS download
// write port. Keep the byte banks as explicit true dual-port M10Ks so Quartus
// does not infer a same-clock RAM with an implicit pass-through path.
module s24_fd1094_key_ram (
    input  logic        clk,
    input  logic [11:0] read_addr,
    output logic [7:0]  even_q,
    output logic [7:0]  odd_q,
    input  logic        write_enable,
    input  logic [11:0] write_addr,
    input  logic [15:0] write_data
);
`ifdef VERILATOR
    // LATENCY CONTRACT: this model must be cycle-identical to the altsyncram
    // pair below.  altsyncram always registers address_a on clock0 -- the
    // input registers are mandatory -- so outdata_reg_a="UNREGISTERED" gives
    // a 1-clock read, not a 0-clock one.  Modelling the read as a
    // combinational `assign` here made every FD1094 fetch sample a stale key
    // byte on hardware while simulation passed (same failure previously fixed
    // in s24_sprite.sv / s24_tile.sv).  Keep this read registered.
    logic [7:0] even_mem [0:4095];
    logic [7:0] odd_mem [0:4095];
    always_ff @(posedge clk) begin
        // Read before the write below matches read_during_write_mode_mixed
        // _ports = "OLD_DATA" on the synthesized banks.
        even_q <= even_mem[read_addr];
        odd_q <= odd_mem[read_addr];
        if(write_enable) begin
            even_mem[write_addr] <= write_data[7:0];
            odd_mem[write_addr] <= write_data[15:8];
        end
    end
`else
    altsyncram ram_even (
        .clock0(clk), .address_a(read_addr), .data_a(8'h00),
        .wren_a(1'b0), .q_a(even_q),
        .clock1(clk), .address_b(write_addr), .data_b(write_data[7:0]),
        .wren_b(write_enable), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b0)
    );
    altsyncram ram_odd (
        .clock0(clk), .address_a(read_addr), .data_a(8'h00),
        .wren_a(1'b0), .q_a(odd_q),
        .clock1(clk), .address_b(write_addr), .data_b(write_data[15:8]),
        .wren_b(write_enable), .q_b(),
        .aclr0(1'b0), .aclr1(1'b0), .addressstall_a(1'b0),
        .addressstall_b(1'b0), .byteena_a(1'b1), .byteena_b(1'b1),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1),
        .clocken3(1'b1), .eccstatus(), .rden_a(1'b1), .rden_b(1'b0)
    );
    defparam
        ram_even.operation_mode = "BIDIR_DUAL_PORT",
        ram_odd.operation_mode = "BIDIR_DUAL_PORT",
        ram_even.width_a = 8, ram_odd.width_a = 8,
        ram_even.width_b = 8, ram_odd.width_b = 8,
        ram_even.widthad_a = 12, ram_odd.widthad_a = 12,
        ram_even.widthad_b = 12, ram_odd.widthad_b = 12,
        ram_even.numwords_a = 4096, ram_odd.numwords_a = 4096,
        ram_even.numwords_b = 4096, ram_odd.numwords_b = 4096,
        ram_even.ram_block_type = "M10K", ram_odd.ram_block_type = "M10K",
        ram_even.intended_device_family = "Cyclone V",
        ram_odd.intended_device_family = "Cyclone V",
        ram_even.lpm_type = "altsyncram", ram_odd.lpm_type = "altsyncram",
        ram_even.outdata_reg_a = "UNREGISTERED",
        ram_odd.outdata_reg_a = "UNREGISTERED",
        ram_even.read_during_write_mode_mixed_ports = "OLD_DATA",
        ram_odd.read_during_write_mode_mixed_ports = "OLD_DATA",
        ram_even.width_byteena_a = 1, ram_odd.width_byteena_a = 1,
        ram_even.width_byteena_b = 1, ram_odd.width_byteena_b = 1,
        ram_even.power_up_uninitialized = "FALSE",
        ram_odd.power_up_uninitialized = "FALSE";
`endif
endmodule

module s24_fd1094 #(
    parameter MASK_FILE="rtl/cpu/fd1094_masked.mem"
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        key_wr,
    input  logic [11:0] key_word_addr,
    input  logic [15:0] key_wdata,
    input  logic        start,
    // Asserted one cycle when the SDRAM read for this opcode fetch is
    // ISSUED, well before `start` (which waits for the data to return).
    // The key-RAM lookup depends only on the address, which s24_cpu_bus
    // holds stable for the whole transaction, so it is started here and
    // completes behind the SDRAM round trip instead of serializing after
    // it.  On real hardware the FD1094's decryption sits inside the CPU
    // package and adds no bus-cycle latency at all, so removing this
    // artificial serialization moves the core toward the hardware, not
    // away from it.
    input  logic        key_start,
    input  logic [23:1] word_address,
    input  logic [15:0] encrypted,
    input  logic        irq_enter,
    input  logic        instruction_start,
    input  logic [15:0] instruction_opcode,
    input  logic [23:1] instruction_address,
    output logic        busy,
    output logic        done,
    output logic [15:0] plaintext,
    output logic [7:0]  current_state,
    // The state byte the most recent decrypt actually consumed (registered
    // at F_ARMED, held until the next F_ARMED).  The opcode cache tags its
    // fill with this, not current_state, so a CMP-driven state change that
    // lands mid-flight can never tag a line with a state the decrypt did
    // not use.
    output logic [7:0]  state_used,
    // Opcode-cache hit notification.  A cache hit returns a plaintext word
    // without running the decrypt pipeline, but the CMP/RTE state machine
    // below observes program fetches in two ways that must not go blind:
    // the fetch_history scan (a CMPI.L whose operand words were prefetched
    // before the opcode reached the IR->IRD boundary) and the cmp_phase
    // walk (operand words fetched after it).  hit_record replays exactly
    // the F_DONE bookkeeping for a word the cache served, and is never
    // asserted while a decrypt is in flight -- the CPU-B bus front-end
    // serialises fetches, and a hit issues no key_start, so fstate is
    // F_IDLE for the whole transaction.
    input  logic        hit_record,
    input  logic [23:1] hit_address,
    input  logic [15:0] hit_data
);
    logic [7:0] key_ram_even_q,key_ram_odd_q;
    s24_fd1094_key_ram key_ram (
        .clk(clk), .read_addr(key_address[12:1]),
        .even_q(key_ram_even_q), .odd_q(key_ram_odd_q),
        .write_enable(key_wr), .write_addr(key_word_addr),
        .write_data(key_wdata));
`ifdef SYNTHESIS
    logic [7:0] mask_q;
    altsyncram mask_ram (
        .clock0(clk),
        .address_a(mask_address_l), .q_a(mask_q),
        .aclr0(1'b0), .addressstall_a(1'b0), .clocken0(1'b1),
        .eccstatus(), .rden_a(1'b1)
    );
    defparam
        mask_ram.operation_mode = "ROM",
        mask_ram.width_a = 8,
        mask_ram.widthad_a = 13,
        mask_ram.numwords_a = 8192,
        mask_ram.ram_block_type = "M10K",
        mask_ram.intended_device_family = "Cyclone V",
        mask_ram.lpm_type = "altsyncram",
        // UNREGISTERED keeps this ROM at the 1-clock read latency that the
        // simulation model below implements. address_a is registered on
        // clock0 either way, so the read can never be combinational.
        mask_ram.outdata_reg_a = "UNREGISTERED",
        mask_ram.init_file = "rtl/cpu/fd1094_masked.mif",
        mask_ram.power_up_uninitialized = "FALSE";
`else
    logic [7:0] mask_q;
    logic [7:0] mask_rom [0:8191];
    initial $readmemh(MASK_FILE,mask_rom);
    // The registered read is declared after mask_address_l below.
`endif

    logic [7:0] irq_key=0,global_key1=0,global_key2=0,global_key3=0;
    logic [7:0] normal_state,decrypt_state,mainkey;
    logic irq_mode;
    logic [12:0] key_address,dec_mask_address,mask_address_l;
    logic [2:0] dec_mask_bit,mask_bit_l;
    logic [15:0] encrypted_l,preliminary,dec_preliminary;
    logic [23:1] address_l;
    logic vector_l;
    logic [7:0] mask_byte;
    logic [15:0] result_next;
    logic [1:0] cmp_phase;
    logic [23:1] cmp_expected;
    logic [15:0] cmp_high;
    logic [3:0] fetch_history_valid;
    logic [23:1] fetch_history_addr [0:3];
    logic [15:0] fetch_history_data [0:3];
    logic [15:0] cmp_history_high,cmp_history_low;

`ifndef SYNTHESIS
    // LATENCY CONTRACT: mirrors the altsyncram ROM above, whose address_a is
    // registered on clk (1-clock read).  Declared here so mask_address_l is
    // already in scope.
    always_ff @(posedge clk) mask_q <= mask_rom[mask_address_l];
`endif

    // F_KEY_Q and F_MASK_Q are the wait cycles that pay for the 1-clock read
    // latency of the key RAM and the mask ROM.  The address is registered at
    // the edge that enters F_KEY / F_MASK, the memory registers that address
    // at the edge that leaves it, and the data is only valid -- and only
    // sampled -- during the following *_Q state.  Do not collapse these.
    typedef enum logic [2:0] {
        F_IDLE,F_KEY,F_KEY_Q,F_ARMED,F_DECRYPT,F_MASK,F_MASK_Q,F_DONE
    } fstate_t;
    fstate_t fstate;
    // Safety net only: the SDRAM round trip is an order of magnitude longer
    // than the three cycles the key lookup needs, so `start` realistically
    // cannot arrive before F_ARMED.  If it ever does, latch it -- together
    // with the state it was raised in, so the sampled decrypt state stays
    // bit-identical to the pre-overlap behaviour.
    logic start_pending;
    logic [7:0] pending_state;

    function automatic logic history_has(input logic [23:1] sought);
        // hit_record can coincide with fx68k's IR->IRD boundary. Include
        // that architecturally-earlier fetch combinationally; its registered
        // history push below is not visible until after this clock edge.
        history_has = (hit_record && hit_address==sought) ||
                      ((fstate==F_DONE) && address_l==sought) ||
                      (fetch_history_valid[0] && fetch_history_addr[0]==sought) ||
                      (fetch_history_valid[1] && fetch_history_addr[1]==sought) ||
                      (fetch_history_valid[2] && fetch_history_addr[2]==sought) ||
                      (fetch_history_valid[3] && fetch_history_addr[3]==sought);
    endfunction

    function automatic logic [15:0] history_word(input logic [23:1] sought);
        if(hit_record && hit_address==sought) history_word=hit_data;
        else if((fstate==F_DONE) && address_l==sought) history_word=result_next;
        else if(fetch_history_valid[0] && fetch_history_addr[0]==sought)
            history_word=fetch_history_data[0];
        else if(fetch_history_valid[1] && fetch_history_addr[1]==sought)
            history_word=fetch_history_data[1];
        else if(fetch_history_valid[2] && fetch_history_addr[2]==sought)
            history_word=fetch_history_data[2];
        else history_word=fetch_history_data[3];
    endfunction

    assign busy=(fstate!=F_IDLE);
    assign current_state=irq_mode?irq_key:normal_state;
    assign state_used=decrypt_state;
    assign result_next=mask_byte[mask_bit_l]?16'hffff:preliminary;
    assign cmp_history_high=history_word(instruction_address+23'd1);
    assign cmp_history_low=history_word(instruction_address+23'd2);

    s24_fd1094_decrypt decryptor(
        .word_address(address_l),.encrypted(encrypted_l),.mainkey(mainkey),
        .global_key1(global_key1),.global_key2(global_key2),
        .global_key3(global_key3),.state(decrypt_state),.vector_fetch(vector_l),
        .value_unmasked(dec_preliminary),.mask_address(dec_mask_address),
        .mask_bit(dec_mask_bit));

    always_ff @(posedge clk) begin
        done<=0;
        if(reset) begin
            fstate<=F_IDLE;done<=0;plaintext<=0;normal_state<=0;irq_mode<=0;
            key_address<=0;mainkey<=0;decrypt_state<=0;encrypted_l<=0;
            address_l<=0;vector_l<=0;mask_address_l<=0;mask_bit_l<=0;
            mask_byte<=0;preliminary<=0;cmp_phase<=0;cmp_expected<=0;
            cmp_high<=0;
            start_pending<=0;pending_state<=0;
            fetch_history_valid<=0;
            fetch_history_addr[0]<=0;fetch_history_addr[1]<=0;
            fetch_history_addr[2]<=0;fetch_history_addr[3]<=0;
            fetch_history_data[0]<=0;fetch_history_data[1]<=0;
            fetch_history_data[2]<=0;fetch_history_data[3]<=0;
        end else begin
            if(irq_enter) irq_mode<=1'b1;
            // See start_pending's declaration: this only fires if a fetch
            // ever completes faster than the three-cycle key lookup.
            if(start && (fstate==F_KEY || fstate==F_KEY_Q)) begin
                start_pending<=1'b1;
                pending_state<=current_state;
            end
            case(fstate)
                // Entered when the SDRAM read is issued, not when it
                // returns: only the address is needed to pick the key.
                F_IDLE: if(key_start) begin
                    // word_address is a packed [23:1] bus address, so
                    // [13:1] is the numeric low 13-bit MAME word address.
                    // This matches decrypt_one()'s address & 0x1fff and its
                    // (address & 0x0ffc) == 0 special-key window.
                    if((word_address[12:3]==0)&&(word_address>=4))
                        key_address<=word_address[13:1]|13'h1000;
                    else key_address<=word_address[13:1];
                    start_pending<=1'b0;
                    fstate<=F_KEY;
                end
                // key_address was registered on entry to F_KEY; the key RAM
                // registers it at the end of F_KEY, so its output is only
                // valid during F_KEY_Q.
                F_KEY: fstate<=F_KEY_Q;
                F_KEY_Q: begin
                    mainkey <= key_address[0]
                               ? key_ram_odd_q
                               : key_ram_even_q;
                    fstate<=F_ARMED;
                end
                // The key is ready; wait here for the SDRAM data.  Sampling
                // address/ciphertext/state at this point -- the moment the
                // fetched word actually arrives -- keeps every value that
                // feeds the decrypt identical to the pre-overlap ordering.
                F_ARMED: if(start || start_pending) begin
                    address_l<=word_address;
                    encrypted_l<=encrypted;
                    vector_l<=(word_address<=3);
                    decrypt_state<=start_pending ? pending_state
                                                 : current_state;
                    start_pending<=1'b0;
                    fstate<=F_DECRYPT;
                end
                F_DECRYPT: begin
                    preliminary<=dec_preliminary;
                    mask_address_l<=dec_mask_address;
                    mask_bit_l<=dec_mask_bit;
                    fstate<=F_MASK;
                end
                // mask_address_l was registered on entry to F_MASK; the mask
                // ROM registers it at the end of F_MASK, so mask_q is only
                // valid during F_MASK_Q.  Both build paths now read mask_q,
                // so no `ifdef can reintroduce a latency difference here.
                F_MASK: fstate<=F_MASK_Q;
                F_MASK_Q: begin
                    mask_byte<=mask_q;
                    fstate<=F_DONE;
                end
                F_DONE: begin
                    plaintext<=result_next;
                    done<=1'b1;
                    fstate<=F_IDLE;
                    fetch_history_valid<={fetch_history_valid[2:0],1'b1};
                    fetch_history_addr[3]<=fetch_history_addr[2];
                    fetch_history_addr[2]<=fetch_history_addr[1];
                    fetch_history_addr[1]<=fetch_history_addr[0];
                    fetch_history_addr[0]<=address_l;
                    fetch_history_data[3]<=fetch_history_data[2];
                    fetch_history_data[2]<=fetch_history_data[1];
                    fetch_history_data[1]<=fetch_history_data[0];
                    fetch_history_data[0]<=result_next;
                    if(cmp_phase==1 && address_l==cmp_expected) begin
                        cmp_high<=result_next;cmp_expected<=address_l+23'd1;cmp_phase<=2;
                    end else if(cmp_phase==2 && address_l==cmp_expected) begin
                        cmp_phase<=0;
                        if(result_next==16'hffff) begin
                            case(cmp_high[9:8])
                                2'b00: normal_state<=cmp_high[7:0];
                                2'b01: begin normal_state<=cmp_high[7:0];irq_mode<=0;end
                                2'b10: irq_mode<=1;
                                default: irq_mode<=0;
                            endcase
                        end
                    end else begin
                        cmp_phase<=0;
                    end
                end
                default: fstate<=F_IDLE;
            endcase
            // A cache-served fetch is still a program fetch: replay F_DONE's
            // history push and cmp_phase walk for it, in the same program-
            // order slot (after the case, before instruction_start) so any
            // same-cycle instruction_start keeps the identical last-write
            // priority it has against F_DONE.  hit_record and F_DONE are
            // mutually exclusive by construction (see the port comment).
            if(hit_record) begin
                fetch_history_valid<={fetch_history_valid[2:0],1'b1};
                fetch_history_addr[3]<=fetch_history_addr[2];
                fetch_history_addr[2]<=fetch_history_addr[1];
                fetch_history_addr[1]<=fetch_history_addr[0];
                fetch_history_addr[0]<=hit_address;
                fetch_history_data[3]<=fetch_history_data[2];
                fetch_history_data[2]<=fetch_history_data[1];
                fetch_history_data[1]<=fetch_history_data[0];
                fetch_history_data[0]<=hit_data;
                if(cmp_phase==1 && hit_address==cmp_expected) begin
                    cmp_high<=hit_data;cmp_expected<=hit_address+23'd1;cmp_phase<=2;
                end else if(cmp_phase==2 && hit_address==cmp_expected) begin
                    cmp_phase<=0;
                    if(hit_data==16'hffff) begin
                        case(cmp_high[9:8])
                            2'b00: normal_state<=cmp_high[7:0];
                            2'b01: begin normal_state<=cmp_high[7:0];irq_mode<=0;end
                            2'b10: irq_mode<=1;
                            default: irq_mode<=0;
                        endcase
                    end
                end else begin
                    cmp_phase<=0;
                end
            end
            // MAME changes FD1094 state when the 68000 executes these
            // instructions. Qualifying with fx68k's IR->IRD boundary avoids
            // treating a discarded prefetch as an executed RTE or CMPI.L.
            // The fetch history also covers fx68k prefetching one or both long
            // immediate words before the opcode reaches that boundary.
            if(instruction_start) begin
                cmp_phase<=0;
                if(instruction_opcode==16'h0c80) begin
                    if(history_has(instruction_address+23'd1)) begin
                        cmp_high<=cmp_history_high;
                        if(history_has(instruction_address+23'd2)) begin
                            if(cmp_history_low==16'hffff) begin
                                case(cmp_history_high[9:8])
                                    2'b00: normal_state<=cmp_history_high[7:0];
                                    2'b01: begin
                                        normal_state<=cmp_history_high[7:0];
                                        irq_mode<=0;
                                    end
                                    2'b10: irq_mode<=1;
                                    default: irq_mode<=0;
                                endcase
                            end
                        end else begin
                            cmp_phase<=2;
                            cmp_expected<=instruction_address+23'd2;
                        end
                    end else begin
                        cmp_phase<=1;
                        cmp_expected<=instruction_address+23'd1;
                    end
                end
                if(instruction_opcode==16'h4e73) irq_mode<=0;
            end
        end
        // Key download deliberately remains writable while the emulated CPU
        // is held in reset by ioctl_download. The explicit key RAM module
        // owns the byte writes; these state bytes mirror the first words.
        if(key_wr) begin
            case({key_word_addr,1'b0})
                13'd0: begin irq_key<=key_wdata[7:0];global_key1<=key_wdata[15:8];end
                13'd2: begin global_key2<=key_wdata[7:0];global_key3<=key_wdata[15:8];end
                default: ;
            endcase
        end
    end
endmodule
