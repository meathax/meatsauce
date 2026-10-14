// SPDX-License-Identifier: BSD-3-Clause
// VRender0 32-voice register bank, serial voice scheduler and stereo mixer.
// BANK_SHIFT=16 follows register comments; 4 reproduces the conflicting MAME
// global-halfword implementation for diagnostics. Physical behavior unresolved.
module vr0_spu #(
    parameter integer SAMPLE_CLOCKS=1944,
    parameter integer BANK_SHIFT=16
) (
    input logic clk, reset,
    input logic reg_valid, reg_write,
    input logic [11:0] reg_address,
    input logic [31:0] reg_data,
    input logic [3:0] reg_strobe,
    output logic reg_ready,
    output logic [31:0] reg_read_data,
    output logic irq, irq_event, sample_valid,
    output logic signed [15:0] sample_left, sample_right,
    output logic underrun, memory_fault,
    output logic [6:0] unsupported_modes,
    output logic unsupported_reverb,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error
);
    // Only fields the voice engine writes back stay in flip-flops. The MMIO-only
    // halfwords (frequency, modes, loops, volumes, envelope rates/targets) live in
    // two block-RAM copies (MMIO read port and engine read port), cutting ~5k flops.
    typedef struct packed {
        logic [31:0] address;
        logic signed [31:0] envelope;
        logic [7:0] stage;
        logic ld;
    } channel_t;
    channel_t channels [0:31];
    channel_t selected;
    logic [11:0][15:0] mmio_row, engine_row; // halfword offsets 4..15 of one channel
    logic init_active;
    logic [4:0] init_channel;
    logic valid_seen;
    logic [31:0] status, note_on, int_mask, int_pending;
    logic [15:0] control;
    logic [7:0] channel_clock, reverb_factor;
    logic [4:0] maximum, channel;
    logic [6:0] buffer_start;
    logic [11:0] buffer_size [0:3];
    logic [19:0] divisor;
    logic [$clog2(SAMPLE_CLOCKS)-1:0] counter;
    typedef enum logic [2:0] {IDLE, SELECT, START, WAIT_VOICE, DONE} state_t;
    state_t state;
    logic tick, completed, job_ready, result_valid, voice_ended, voice_fault;
    logic [31:0] next_address, next_envelope;
    logic [7:0] next_stage;
    logic signed [31:0] contribution_left, contribution_right, mix_left, mix_right;
    logic signed [15:0] completed_left, completed_right;
    logic [6:0] voice_unsupported;

    function automatic logic [15:0] channel_read(input channel_t c, input logic [3:0] offset);
        integer n;
        case(offset)
            0: return c.address[15:0];
            1: return c.address[31:16];
            2: return c.envelope[15:0];
            3: return {1'b0,2'b11,c.ld,c.stage[3:0],c.envelope[23:16]};
            default: return 0;
        endcase
    endfunction

    function automatic channel_t channel_write(input channel_t old, input logic [3:0] offset,
        input logic [15:0] data, mask);
        channel_t c;
        logic [15:0] merged;
        integer n;
        c=old; merged=(channel_read(old,offset)&~mask)|(data&mask);
        case(offset)
            0: c.address[15:0]=merged;
            1: c.address[31:16]=merged;
            2: c.envelope[15:0]=merged;
            3: begin c.ld=merged[12]; c.stage={4'b0,merged[11:8]};
                c.envelope={{8{merged[7]}},merged[7:0],c.envelope[15:0]}; end
            default: begin end
        endcase
        return c;
    endfunction

    function automatic logic signed [15:0] clip(input logic signed [31:0] value);
        if(value>32767) return 16'sh7fff;
        if(value < -32768) return 16'sh8000;
        return value[15:0];
    endfunction

    function automatic logic [15:0] register_read(input logic [11:0] address);
        logic [15:0] value;
        // Select each channel's halfword before the channel mux. The original
        // channel-first mux routed the full packed voice through word decode.
        if(address<12'h400) begin
            value=0;
            for(integer c=0;c<32;c=c+1)
                value |= channel_read(channels[c],address[4:1]) & {16{address[9:5]==5'(c)}};
            // Offsets 4..15 come from the block-RAM row read for this channel; fields that
            // were not stored in the original register image read as zero.
            if(address[4:1]>=4) begin
                value=mmio_row[address[4:1]-4'd4];
                case(address[4:1])
                    5: value=value & 16'h7f00;
                    7,9: value=value & 16'h7f3f;
                    default: begin end
                endcase
            end
            return value;
        end
        case(address)
            12'h404: return status[15:0];
            12'h406: return 16'(status>>BANK_SHIFT);
            12'h408: return note_on[15:0];
            12'h40a: return 16'(note_on>>BANK_SHIFT);
            12'h410: return {8'b0,reverb_factor};
            12'h412: return {9'b0,buffer_start};
            12'h420: return {4'b0,buffer_size[0]};
            12'h422: return {4'b0,buffer_size[1]};
            12'h440: return {4'b0,buffer_size[2]};
            12'h442: return {4'b0,buffer_size[3]};
            12'h480: return int_mask[15:0];
            12'h482: return 16'(int_mask>>BANK_SHIFT);
            12'h500: return int_pending[15:0];
            12'h502: return 16'(int_pending>>BANK_SHIFT);
            12'h600: return {3'b0,maximum,channel_clock};
            12'h602: return control;
            default: return 16'hffff;
        endcase
    endfunction

    // Constant numerator division; infer an indexed constant ROM, generated below.
    function automatic logic [19:0] clock_divide(input logic [7:0] value);
        case(value)
            8'd0: return 20'd65536;
            8'd1: return 20'd999424;
            8'd2: return 20'd666282;
            8'd3: return 20'd499712;
            8'd4: return 20'd399769;
            8'd5: return 20'd333141;
            8'd6: return 20'd285549;
            8'd7: return 20'd249856;
            8'd8: return 20'd222094;
            8'd9: return 20'd199884;
            8'd10: return 20'd181713;
            8'd11: return 20'd166570;
            8'd12: return 20'd153757;
            8'd13: return 20'd142774;
            8'd14: return 20'd133256;
            8'd15: return 20'd124928;
            8'd16: return 20'd117579;
            8'd17: return 20'd111047;
            8'd18: return 20'd105202;
            8'd19: return 20'd99942;
            8'd20: return 20'd95183;
            8'd21: return 20'd90856;
            8'd22: return 20'd86906;
            8'd23: return 20'd83285;
            8'd24: return 20'd79953;
            8'd25: return 20'd76878;
            8'd26: return 20'd74031;
            8'd27: return 20'd71387;
            8'd28: return 20'd68925;
            8'd29: return 20'd66628;
            8'd30: return 20'd64478;
            8'd31: return 20'd62464;
            8'd32: return 20'd60571;
            8'd33: return 20'd58789;
            8'd34: return 20'd57109;
            8'd35: return 20'd55523;
            8'd36: return 20'd54022;
            8'd37: return 20'd52601;
            8'd38: return 20'd51252;
            8'd39: return 20'd49971;
            8'd40: return 20'd48752;
            8'd41: return 20'd47591;
            8'd42: return 20'd46484;
            8'd43: return 20'd45428;
            8'd44: return 20'd44418;
            8'd45: return 20'd43453;
            8'd46: return 20'd42528;
            8'd47: return 20'd41642;
            8'd48: return 20'd40792;
            8'd49: return 20'd39976;
            8'd50: return 20'd39193;
            8'd51: return 20'd38439;
            8'd52: return 20'd37714;
            8'd53: return 20'd37015;
            8'd54: return 20'd36342;
            8'd55: return 20'd35693;
            8'd56: return 20'd35067;
            8'd57: return 20'd34462;
            8'd58: return 20'd33878;
            8'd59: return 20'd33314;
            8'd60: return 20'd32768;
            8'd61: return 20'd32239;
            8'd62: return 20'd31727;
            8'd63: return 20'd31232;
            8'd64: return 20'd30751;
            8'd65: return 20'd30285;
            8'd66: return 20'd29833;
            8'd67: return 20'd29394;
            8'd68: return 20'd28968;
            8'd69: return 20'd28554;
            8'd70: return 20'd28152;
            8'd71: return 20'd27761;
            8'd72: return 20'd27381;
            8'd73: return 20'd27011;
            8'd74: return 20'd26651;
            8'd75: return 20'd26300;
            8'd76: return 20'd25959;
            8'd77: return 20'd25626;
            8'd78: return 20'd25301;
            8'd79: return 20'd24985;
            8'd80: return 20'd24677;
            8'd81: return 20'd24376;
            8'd82: return 20'd24082;
            8'd83: return 20'd23795;
            8'd84: return 20'd23515;
            8'd85: return 20'd23242;
            8'd86: return 20'd22975;
            8'd87: return 20'd22714;
            8'd88: return 20'd22458;
            8'd89: return 20'd22209;
            8'd90: return 20'd21965;
            8'd91: return 20'd21726;
            8'd92: return 20'd21492;
            8'd93: return 20'd21264;
            8'd94: return 20'd21040;
            8'd95: return 20'd20821;
            8'd96: return 20'd20606;
            8'd97: return 20'd20396;
            8'd98: return 20'd20190;
            8'd99: return 20'd19988;
            8'd100: return 20'd19790;
            8'd101: return 20'd19596;
            8'd102: return 20'd19406;
            8'd103: return 20'd19219;
            8'd104: return 20'd19036;
            8'd105: return 20'd18857;
            8'd106: return 20'd18680;
            8'd107: return 20'd18507;
            8'd108: return 20'd18338;
            8'd109: return 20'd18171;
            8'd110: return 20'd18007;
            8'd111: return 20'd17846;
            8'd112: return 20'd17688;
            8'd113: return 20'd17533;
            8'd114: return 20'd17381;
            8'd115: return 20'd17231;
            8'd116: return 20'd17084;
            8'd117: return 20'd16939;
            8'd118: return 20'd16797;
            8'd119: return 20'd16657;
            8'd120: return 20'd16519;
            8'd121: return 20'd16384;
            8'd122: return 20'd16250;
            8'd123: return 20'd16119;
            8'd124: return 20'd15990;
            8'd125: return 20'd15863;
            8'd126: return 20'd15738;
            8'd127: return 20'd15616;
            8'd128: return 20'd15494;
            8'd129: return 20'd15375;
            8'd130: return 20'd15258;
            8'd131: return 20'd15142;
            8'd132: return 20'd15028;
            8'd133: return 20'd14916;
            8'd134: return 20'd14806;
            8'd135: return 20'd14697;
            8'd136: return 20'd14590;
            8'd137: return 20'd14484;
            8'd138: return 20'd14380;
            8'd139: return 20'd14277;
            8'd140: return 20'd14176;
            8'd141: return 20'd14076;
            8'd142: return 20'd13977;
            8'd143: return 20'd13880;
            8'd144: return 20'd13785;
            8'd145: return 20'd13690;
            8'd146: return 20'd13597;
            8'd147: return 20'd13505;
            8'd148: return 20'd13415;
            8'd149: return 20'd13325;
            8'd150: return 20'd13237;
            8'd151: return 20'd13150;
            8'd152: return 20'd13064;
            8'd153: return 20'd12979;
            8'd154: return 20'd12895;
            8'd155: return 20'd12813;
            8'd156: return 20'd12731;
            8'd157: return 20'd12650;
            8'd158: return 20'd12571;
            8'd159: return 20'd12492;
            8'd160: return 20'd12415;
            8'd161: return 20'd12338;
            8'd162: return 20'd12262;
            8'd163: return 20'd12188;
            8'd164: return 20'd12114;
            8'd165: return 20'd12041;
            8'd166: return 20'd11969;
            8'd167: return 20'd11897;
            8'd168: return 20'd11827;
            8'd169: return 20'd11757;
            8'd170: return 20'd11689;
            8'd171: return 20'd11621;
            8'd172: return 20'd11554;
            8'd173: return 20'd11487;
            8'd174: return 20'd11421;
            8'd175: return 20'd11357;
            8'd176: return 20'd11292;
            8'd177: return 20'd11229;
            8'd178: return 20'd11166;
            8'd179: return 20'd11104;
            8'd180: return 20'd11043;
            8'd181: return 20'd10982;
            8'd182: return 20'd10922;
            8'd183: return 20'd10863;
            8'd184: return 20'd10804;
            8'd185: return 20'd10746;
            8'd186: return 20'd10689;
            8'd187: return 20'd10632;
            8'd188: return 20'd10575;
            8'd189: return 20'd10520;
            8'd190: return 20'd10465;
            8'd191: return 20'd10410;
            8'd192: return 20'd10356;
            8'd193: return 20'd10303;
            8'd194: return 20'd10250;
            8'd195: return 20'd10198;
            8'd196: return 20'd10146;
            8'd197: return 20'd10095;
            8'd198: return 20'd10044;
            8'd199: return 20'd9994;
            8'd200: return 20'd9944;
            8'd201: return 20'd9895;
            8'd202: return 20'd9846;
            8'd203: return 20'd9798;
            8'd204: return 20'd9750;
            8'd205: return 20'd9703;
            8'd206: return 20'd9656;
            8'd207: return 20'd9609;
            8'd208: return 20'd9563;
            8'd209: return 20'd9518;
            8'd210: return 20'd9473;
            8'd211: return 20'd9428;
            8'd212: return 20'd9384;
            8'd213: return 20'd9340;
            8'd214: return 20'd9296;
            8'd215: return 20'd9253;
            8'd216: return 20'd9211;
            8'd217: return 20'd9169;
            8'd218: return 20'd9127;
            8'd219: return 20'd9085;
            8'd220: return 20'd9044;
            8'd221: return 20'd9003;
            8'd222: return 20'd8963;
            8'd223: return 20'd8923;
            8'd224: return 20'd8883;
            8'd225: return 20'd8844;
            8'd226: return 20'd8805;
            8'd227: return 20'd8766;
            8'd228: return 20'd8728;
            8'd229: return 20'd8690;
            8'd230: return 20'd8653;
            8'd231: return 20'd8615;
            8'd232: return 20'd8578;
            8'd233: return 20'd8542;
            8'd234: return 20'd8505;
            8'd235: return 20'd8469;
            8'd236: return 20'd8433;
            8'd237: return 20'd8398;
            8'd238: return 20'd8363;
            8'd239: return 20'd8328;
            8'd240: return 20'd8293;
            8'd241: return 20'd8259;
            8'd242: return 20'd8225;
            8'd243: return 20'd8192;
            8'd244: return 20'd8158;
            8'd245: return 20'd8125;
            8'd246: return 20'd8092;
            8'd247: return 20'd8059;
            8'd248: return 20'd8027;
            8'd249: return 20'd7995;
            8'd250: return 20'd7963;
            8'd251: return 20'd7931;
            8'd252: return 20'd7900;
            8'd253: return 20'd7869;
            8'd254: return 20'd7838;
            8'd255: return 20'd7808;
            default: return 20'd65536;
        endcase
    endfunction

    always_comb begin
        selected=channels[channel];
        divisor=clock_divide(channel_clock);
        tick=counter==SAMPLE_CLOCKS-1;
        // One wait cycle for the RAM read (address is registered by the board and stable);
        // initialization sweep after reset blocks the register interface.
        reg_ready=state==IDLE && !tick && !init_active && (valid_seen || !reg_valid);
        reg_read_data={register_read({reg_address[11:2],2'b10}),register_read({reg_address[11:2],2'b00})};
        irq=|int_pending;
        unsupported_reverb=control[4];
    end
    // Block-RAM write decode: one registered MMIO write touches up to two adjacent halfword
    // banks (offsets 4..15); the post-reset sweep clears all banks of every channel.
    logic [11:0][1:0] bank_we;
    logic [11:0][15:0] bank_wdata;
    wire spu_write_ok = reg_valid && reg_ready && reg_write && reg_address<12'h400;
    always_comb begin
        bank_we='0;bank_wdata='0;
        for(integer k=0;k<12;k=k+1) begin
            for(integer lane=0;lane<2;lane=lane+1)
                if(spu_write_ok && ({reg_address[4:2],1'b0}+4'(lane))==4'(k+4)) begin
                    bank_we[k]=reg_strobe[lane*2+:2];
                    bank_wdata[k]=reg_data[lane*16+:16];
                end
            if(init_active) begin bank_we[k]=2'b11;bank_wdata[k]=16'h0000;end
        end
    end
    wire [4:0] bank_write_channel = init_active ? init_channel : reg_address[9:5];
    vr0_spu_bank mmio_bank (.clk,.write_address(bank_write_channel),.we(bank_we),.wdata(bank_wdata),
        .read_address(reg_address[9:5]),.row(mmio_row));
    vr0_spu_bank engine_bank (.clk,.write_address(bank_write_channel),.we(bank_we),.wdata(bank_wdata),
        .read_address(channel),.row(engine_row));
    vr0_voice voice (
        .clk,.reset,.job_valid(state==START),.job_ready,
        .current_address(selected.address),.envelope_volume(selected.envelope),
        .envelope_stage(selected.stage),.frequency(engine_row[0]),.modes(engine_row[1][14:8]),
        .texture_selected(engine_row[1][14] && control[5]),
        .loop_begin({engine_row[3][5:0],engine_row[2]}),.loop_end({engine_row[5][5:0],engine_row[4]}),
        .left_volume(engine_row[3][14:8]),.right_volume(engine_row[5][14:8]),
        .envelope_rates({{16{engine_row[11][15]}},engine_row[9],{16{engine_row[11][7]}},engine_row[8],
                         {16{engine_row[10][15]}},engine_row[7],{16{engine_row[10][7]}},engine_row[6]}),
        .envelope_targets({engine_row[11][14:8],engine_row[11][6:0],engine_row[10][14:8],engine_row[10][6:0]}),
        .clock_divisor(divisor),
        .result_valid,.result_ready(state==WAIT_VOICE),.next_address,
        .next_envelope_volume(next_envelope),.next_envelope_stage(next_stage),
        .left_contribution(contribution_left),.right_contribution(contribution_right),
        .ended(voice_ended),.memory_fault(voice_fault),.unsupported_modes(voice_unsupported),
        .req_valid,.req_ready,.req_address,.req_data,.req_strobe,.req_write,
        .rsp_valid,.rsp_data,.rsp_error
    );

    always_ff @(posedge clk) begin : update
        channel_t changed;
        logic [11:0] address;
        logic [15:0] data, mask;
        integer shift, n;
        if(reset) begin
            state<=IDLE; counter<=0; channel<=0; completed<=0;
            mix_left<=0;mix_right<=0;completed_left<=0;completed_right<=0;
            sample_valid<=0;irq_event<=0;sample_left<=0;sample_right<=0;
            underrun<=0;memory_fault<=0;unsupported_modes<=0;
            status<=0;note_on<=0;int_mask<=0;int_pending<=0;
            control<=0;maximum<=31;channel_clock<=0;reverb_factor<=0;buffer_start<=0;
            for(integer i=0;i<32;i=i+1) begin
                channels[i]<='0;channels[i].stage<=1;channels[i].ld<=1;
            end
            init_active<=1;init_channel<=0;valid_seen<=0;
            for(integer i=0;i<4;i=i+1) buffer_size[i]<=0;
        end else begin
            sample_valid<=0;irq_event<=0;
            valid_seen<=reg_valid && !reg_ready;
            if(init_active) begin
                init_channel<=init_channel+5'd1;
                if(init_channel==5'd31) init_active<=0;
            end
            if(tick) begin
                counter<=0;sample_valid<=1;
                if(completed) begin sample_left<=completed_left;sample_right<=completed_right;end
                // Late scan: repeat the previous sample rather than emitting a
                // full-scale step to zero; the sticky underrun diagnostic remains.
                else if(state!=IDLE) underrun<=1;
                completed<=0;
                if(state==IDLE) begin state<=SELECT;channel<=0;mix_left<=0;mix_right<=0;end
                else underrun<=1;
            end else counter<=counter+1'b1;
            case(state)
                SELECT: if(!control[15]) state<=DONE;
                    else if(status[channel]) state<=START;
                    else if(channel==maximum) state<=DONE;
                    else channel<=channel+1'b1;
                START: if(job_ready) state<=WAIT_VOICE;
                WAIT_VOICE: if(result_valid) begin
                    channels[channel].address<=next_address;
                    channels[channel].envelope<=next_envelope;
                    channels[channel].stage<=next_stage;
                    mix_left<=mix_left+contribution_left;mix_right<=mix_right+contribution_right;
                    memory_fault<=memory_fault|voice_fault;
                    unsupported_modes<=unsupported_modes|voice_unsupported;
                    if(voice_ended) begin
                        status[channel]<=0;
                        if(!int_mask[channel]) begin int_pending[channel]<=1;irq_event<=!int_pending[channel];end // MAME: IRQ only when old_pend != m_int_pend
                        state<=DONE; // pinned reference ends this entire sample's scan
                    end else if(channel==maximum) state<=DONE;
                    else begin channel<=channel+1'b1;state<=SELECT;end
                end
                DONE: begin completed_left<=clip(mix_left);completed_right<=clip(mix_right);completed<=1;state<=IDLE;end
                default: begin end
            endcase
            if(reg_valid && reg_ready && reg_write) begin
                if(reg_address<12'h400) begin
                    // Each channel merges its own fields; avoid a 32-channel
                    // read mux before the byte-mask merge and write decoder.
                    for(integer c=0;c<32;c=c+1) if(reg_address[9:5]==5'(c)) begin
                        changed=channels[c];
                        for(integer lane=0;lane<2;lane=lane+1) begin
                            mask={{8{reg_strobe[lane*2+1]}},{8{reg_strobe[lane*2]}}};
                            if(mask!=0 && ({reg_address[4:2],1'b0}+4'(lane))<4)
                                changed=channel_write(changed,{reg_address[4:2],1'b0}+4'(lane),reg_data[lane*16+:16],mask);
                        end
                        channels[c]<=changed;
                    end
                end else for(integer lane=0;lane<2;lane=lane+1) begin
                    address={reg_address[11:2],2'b00}+12'(lane*2);
                    data=reg_data[lane*16+:16];
                    mask={{8{reg_strobe[lane*2+1]}},{8{reg_strobe[lane*2]}}};
                    shift=address[1]?BANK_SHIFT:0;
                    if(mask!=0) case(address)
                        12'h404,12'h406: status[data[4:0]]<=data[15];
                        12'h408,12'h40a: note_on[data[4:0]]<=data[15];
                        12'h410: if(mask[7:0]!=0) reverb_factor<=data[7:0];
                        12'h412: if(mask[7:0]!=0) buffer_start<=data[6:0];
                        12'h420,12'h422,12'h440,12'h442: begin
                            n=(address[6]?2:0)+(address[1]?1:0);
                            buffer_size[n]<=(buffer_size[n]&~mask[11:0])|(data[11:0]&mask[11:0]);
                        end
                        12'h480,12'h482: int_mask[shift+:16]<=(int_mask[shift+:16]&~mask)|(data&mask);
                        12'h500,12'h502: int_pending[shift+:16]<=int_pending[shift+:16]&~(data&mask);
                        12'h600: begin
                            if(mask[7:0]!=0) channel_clock<=data[7:0];
                            if(mask[15:8]!=0) maximum<=data[12:8];
                        end
                        12'h602: control<=(control&~mask)|(data&mask);
                        default: begin end
                    endcase
                end
            end
        end
    end
endmodule

// Twelve 16-bit banks (halfword offsets 4..15) x 32 channels with byte write enables.
// One synchronous write port, one registered read of every bank at the read address.
module vr0_spu_bank (
    input logic clk,
    input logic [4:0] write_address, read_address,
    input logic [11:0][1:0] we,
    input logic [11:0][15:0] wdata,
    output logic [11:0][15:0] row
);
    genvar k, b;
    generate for(k=0;k<12;k=k+1) begin : bank
        for(b=0;b<2;b=b+1) begin : lane
            (* ramstyle = "M10K" *) logic [7:0] mem [0:31];
            always_ff @(posedge clk) begin
                if(we[k][b]) mem[write_address] <= wdata[k][b*8+:8];
                row[k][b*8+:8] <= mem[read_address];
            end
        end
    end endgenerate
endmodule
