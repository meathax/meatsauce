// SPDX-License-Identifier: GPL-3.0-or-later
// Signature-gated MAME score RAM persistence, sharing composite HPS index4.
// Inactive source candidate: no profile registration or hardware qualification.
module osman_scores #(
    parameter JOE_SCORE_CANDIDATE = 1'b0
) (
    input wire clk, reset, image_start, game_reset, enabled,
    input wire [7:0] profile,
    input wire paused, osd_open, autosave,
    input wire ioctl_download, ioctl_upload, ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_index,
    input wire [7:0] ioctl_dout,
    output reg [7:0] ioctl_din,
    output reg ioctl_upload_req,
    output wire pause_request, save_busy, configured,
    output reg score_valid, restored, dirty, format_error,
    output wire restore_pending,
    output reg file_complete, file_accepted,
    output wire ram_req,
    output reg ram_we,
    output reg [25:0] ram_addr,
    output reg [7:0] ram_wdata,
    input wire ram_valid,
    input wire [7:0] ram_rdata
);
    localparam CFG=0, RUN=1, DUMP=2, GATHER=3, WAIT_INIT=4;
    localparam PROBE_IDLE=0, PROBE_WAIT=1, PROBE_READ=2, PROBE_START=3;
    reg [2:0] phase;
    reg [1:0] probe;
    reg [7:0] shadow[0:238];
    reg [7:0] header[0:15];
    reg [8:0] load_count;
    reg [15:0] load_crc, score_crc;
    reg tail_seen, tail_order, tail_commit, tail_ff, tail_lanes, tail_padding;
    reg last_download, last_upload, last_osd, last_extract, last_restore;
    reg load_pending, snapshot_pending, upload_final_seen;
    reg [7:0] feed_index, gather_index;
    reg [2:0] feed_wait;
    reg [1:0] reset_pad;
    reg [15:0] gather_crc;
    reg gather_changed;
    reg [3:0] probe_index;
    reg probe_good;
    wire downloading = ioctl_download && ioctl_index==16'd4;
    wire uploading = ioctl_upload && ioctl_index==16'd4;
    wire file_start = downloading && !last_download;
    wire file_end = !downloading && last_download;
    // Adapter component native ranking paths; original-ROM CPU acceptance remains pending.
    // Joe stays disabled unless an explicit private component test opts in.
    // RAW CPU span158 + duplicate final initial1; framing remains384 bytes.
    // The bus canonicalizes Joe's physical100xxx addresses;180xxx is invalid.
    wire charlie = profile == 8'd3;
    wire joe = JOE_SCORE_CANDIDATE && profile == 8'd2;
    wire score_supported = profile < 8'd2 || charlie || joe;
    wire [7:0] table_length = joe ? 8'd158 : charlie ? 8'd174 : 8'd238;
    wire [7:0] payload_length = table_length + 8'd1;
    wire [25:0] table_base = joe ? 26'h1000c0 : charlie ? 26'h184a80 : 26'h186f80;
    wire [25:0] table_last = joe ? 26'h10015d : charlie ? 26'h184b2d : 26'h18706d;
    wire [25:0] marker_addr = joe ? 26'h10015c : charlie ? 26'h182200 : 26'h187068;
    reg [7:0] joe_first_signature;
    reg joe_saw_unready;
    wire [7:0] first_signature = joe ? joe_first_signature : charlie ? 8'h00 : 8'h93;
    wire [7:0] marker_signature = joe ? 8'h09 : charlie ? 8'he6 : 8'h01;
    reg initialized, probe_save;
    reg [15:0] init_wait;
    reg [7:0] active_profile;
    // Joe authenticates the EEPROM prefix from the SAME raw index4 stream.
    // Native LE EEPROM byte3 is the wear selector; HPS transports BE16 words.
    // Original246F4 loads only32 words: native header4 + six10-byte slots.
    reg [7:0] joe_prefix_count, joe_selector;
    reg joe_prefix_order;
    reg [7:0] joe_magic[0:2];
    reg [7:0] joe_slot[0:9];
    wire [6:0] joe_native_byte = ioctl_addr[6:0] ^ 7'd1;
    wire [6:0] joe_slot_base = 7'd4 + (joe_selector[6:0] * 7'd10);
    wire [6:0] joe_slot_offset = joe_native_byte - joe_slot_base;
    wire [7:0] joe_prefix_next = (file_start ? 8'd0 : joe_prefix_count) + 8'd1;
    // Eight-bit addition deliberately matches the ORIGINAL modulo256 checksum.
    wire [7:0] joe_slot_checksum = joe_slot[0] + joe_slot[1] + joe_slot[2] +
        joe_slot[4] + joe_slot[5] + joe_slot[6] + joe_slot[7] + joe_slot[8] + joe_slot[9];
    wire joe_prefix_valid = joe_prefix_order && joe_prefix_count==8'd128 &&
        joe_magic[0]=="J" && joe_magic[1]=="M" && joe_magic[2]=="R" &&
        joe_selector<8'd6 && joe_slot[3]==joe_slot_checksum;
    // FD3C restores this selected record into the first RAM row on CPU boot.
    // Compare all24 score bits and three initials; native EEPROM has no bit24+.
    wire joe_prefix_top_matches = shadow[0]==joe_slot[9] && shadow[1]==0 &&
        shadow[4]==joe_slot[7] && shadow[5]==joe_slot[8] &&
        shadow[8]==joe_slot[4] && shadow[9]==joe_slot[5] && shadow[12]==joe_slot[6];
    wire profile_changed = profile != active_profile;
    wire cold = reset || image_start || file_start || !score_supported || profile_changed;
    reg pending_req;
    assign ram_req = score_supported && !profile_changed && pending_req && !(game_reset && (probe_access || joe));
    wire hs_pause, hs_read, hs_write, hs_restore, hs_extract;
    // The donor stores a fixed 25-bit byte address; widen only at the board port.
    wire [24:0] hs_byte_addr;
    wire [25:0] hs_addr = {1'b0, hs_byte_addr};
    wire [7:0] hs_data, hs_out;
    wire hs_configured;
    reg [7:0] hs_index, hs_dout;
    reg [24:0] hs_ioaddr;
    reg hs_download, hs_wr, hs_upload;
    reg hs_osd;
    wire hs_reset = game_reset || phase==CFG || phase==DUMP || phase==WAIT_INIT || reset_pad!=0;
    wire probe_access = probe==PROBE_READ;
    wire need = probe_access || ((hs_read || hs_write) && phase==RUN);
    wire request_we = !probe_access && hs_write;
    // Original2EB0 writes J(code9) last, after the complete5000/YAJ row.
    // The extra top read latches actual EEPROM-restored data for donor config.
    function automatic [25:0] joe_probe_addr(input [3:0] index);
        begin case(index)
            0:joe_probe_addr=26'h10015c;
            1:joe_probe_addr=26'h100150;2:joe_probe_addr=26'h100151;
            3:joe_probe_addr=26'h100154;4:joe_probe_addr=26'h100155;
            5:joe_probe_addr=26'h100158;6:joe_probe_addr=26'h100159;
            7:joe_probe_addr=26'h10015d;
            default:joe_probe_addr=26'h1000c0;
        endcase end
    endfunction
    function automatic [7:0] joe_probe_signature(input [3:0] index);
        begin case(index)
            0:joe_probe_signature=8'h09;
            3:joe_probe_signature=8'h88;4:joe_probe_signature=8'h13;
            5:joe_probe_signature=8'h18;
            default:joe_probe_signature=8'h00;
        endcase end
    endfunction
    wire [25:0] request_addr = probe_access ? (joe ? joe_probe_addr(probe_index) :
        (probe_index==0 ? table_base : probe_index==1 ? table_last : marker_addr)) : hs_addr;
    wire [7:0] request_data = hs_data;
    wire in_range = (request_addr>=table_base && request_addr<=table_last) || request_addr==marker_addr;
    wire connected = !request_addr[1];
    reg cache_valid, cache_we;
    reg [25:0] cache_addr;
    reg [7:0] cache_data, cache_wdata;
    wire cache_match = cache_valid && cache_addr==request_addr && cache_we==request_we &&
        (!request_we || cache_wdata==request_data);
    wire access_ready = !need || !in_range || !connected || cache_match;
    wire [7:0] read_value = in_range && connected && cache_match ? cache_data : 8'hff;
    wire hs_enable = !cold && (phase!=RUN ||
        ((enabled || hs_restore || hs_extract || hs_pause || probe==PROBE_START) && !downloading && (probe==PROBE_IDLE || probe==PROBE_START) &&
        (!hs_pause || paused) && access_ready));
    assign pause_request = score_supported && (hs_pause || probe!=PROBE_IDLE);
    assign save_busy = score_supported && (snapshot_pending || probe!=PROBE_IDLE || hs_extract || phase==GATHER);
    assign configured = score_supported && hs_configured;
    assign restore_pending = score_supported && score_valid && !restored;

    function automatic [15:0] crc_byte(input [15:0] old, input [7:0] value);
        reg [15:0] c; integer n;
        begin
            c=old^{value,8'h00};
            for(n=0;n<8;n=n+1) c=c[15] ? (c<<1)^16'h1021 : c<<1;
            crc_byte=c;
        end
    endfunction
    function automatic [7:0] config_byte(input [7:0] offset);
        begin
            // Delay/retry=65535; actual handshake permits two-clock hold/pad.
            case(offset)
                4:config_byte=8'hff;5:config_byte=8'hff;
                7,9,14:config_byte=2;11:config_byte=1;
                17:config_byte=joe ? 8'h10 : 8'h18;18:config_byte=joe ? 8'h00 : charlie ? 8'h4a : 8'h6f;19:config_byte=joe ? 8'hc0 : 8'h80;
                20:config_byte=table_length;21:config_byte=first_signature;
                25:config_byte=joe ? 8'h10 : 8'h18;26:config_byte=joe ? 8'h01 : charlie ? 8'h22 : 8'h70;
                27:config_byte=joe ? 8'h5c : charlie ? 8'h00 : 8'h68;
                28:config_byte=1;29,30:config_byte=marker_signature;
                default:config_byte=0;
            endcase
        end
    endfunction

    always @* begin
        hs_index=0;hs_ioaddr=0;hs_dout=0;hs_download=0;hs_wr=0;hs_upload=0;
        if(score_supported && phase==CFG) begin
            hs_index=3;hs_download=1;hs_ioaddr={17'd0,feed_index};
            hs_dout=config_byte(feed_index);hs_wr=feed_wait==0;
        end else if(score_supported && phase==DUMP) begin
            hs_index=4;hs_download=1;hs_ioaddr={17'd0,feed_index};
            hs_dout=shadow[feed_index];hs_wr=feed_wait==0;
        end else if(score_supported && phase==GATHER) begin
            hs_index=4;hs_upload=1;hs_ioaddr={17'd0,gather_index};
        end
        // Prefix belongs exclusively to EEPROM; root muxes the two byte ports.
        ioctl_din=8'hff;
        if(score_supported) case(ioctl_addr)
            128:ioctl_din="O";129:ioctl_din="S";130:ioctl_din="H";131:ioctl_din="S";
            132:ioctl_din=1;133:ioctl_din=profile;134:ioctl_din=payload_length;135:ioctl_din=0;
            136:ioctl_din=score_valid ? score_crc[7:0] : 8'hff;
            137:ioctl_din=score_valid ? score_crc[15:8] : 8'hff;
            138:ioctl_din={7'd0,score_valid};
            139,140,141,142,143:ioctl_din=0;
            383:ioctl_din=8'ha5;
            default: if(ioctl_addr>=144 && ioctl_addr<383)
                ioctl_din=(score_valid && ioctl_addr<27'd144+{19'd0,payload_length}) ? shadow[ioctl_addr-144] : 8'hff;
        endcase
    end

    hiscore #(.HS_ADDRESSWIDTH(25),.HS_SCOREWIDTH(8),.CFG_ADDRESSWIDTH(1)) u_hiscore (
        .clk(clk),.enable(hs_enable),.reset_all(cold),.reset(hs_reset),.paused(paused),
        .autosave(1'b0),.ioctl_upload(hs_upload),.ioctl_upload_req(),
        .ioctl_download(hs_download),.ioctl_wr(hs_wr),.ioctl_addr(hs_ioaddr),
        .ioctl_index(hs_index),.OSD_STATUS(hs_osd),.data_from_hps(hs_dout),
        .data_from_ram(read_value),.ram_address(hs_byte_addr),.data_to_hps(hs_out),
        .data_to_ram(hs_data),.ram_write(hs_write),.ram_intent_read(hs_read),
        .ram_intent_write(),.pause_cpu(hs_pause),.configured(hs_configured),
        .restore_active(hs_restore),.extract_active(hs_extract)
    );

    // Tuple completion cache: a held vendor request causes one real RAM access.
    always @(posedge clk) begin
        if(cold || (game_reset && (probe_access || joe))) begin
            pending_req<=0;ram_we<=0;ram_addr<=0;ram_wdata<=0;cache_valid<=0;
            cache_addr<=0;cache_we<=0;cache_data<=0;cache_wdata<=0;
        end else begin
            if(!need || !paused || !in_range || !connected) cache_valid<=0;
            if(pending_req && ram_valid) begin
                pending_req<=0;cache_valid<=1;cache_addr<=ram_addr;cache_we<=ram_we;
                cache_wdata<=ram_wdata;cache_data<=ram_rdata;
            end else if(!pending_req && need && paused && in_range && connected && !cache_match) begin
                pending_req<=1;ram_we<=request_we;ram_addr<=request_addr;ram_wdata<=request_data;
            end
        end
    end

    integer i;
    always @(posedge clk) begin
        if(reset || image_start || !score_supported || profile_changed) begin
            active_profile<=profile;
            phase<=joe ? WAIT_INIT : CFG;probe<=PROBE_IDLE;feed_index<=0;feed_wait<=0;gather_index<=0;reset_pad<=0;
            load_count<=0;load_crc<=16'hffff;score_crc<=16'hffff;
            tail_seen<=0;tail_order<=1;tail_commit<=0;tail_ff<=1;tail_lanes<=1;tail_padding<=1;
            last_download<=0;last_upload<=0;last_osd<=0;last_extract<=0;last_restore<=0;
            load_pending<=0;snapshot_pending<=0;upload_final_seen<=0;
            score_valid<=0;restored<=0;dirty<=0;format_error<=0;ioctl_upload_req<=0;hs_osd<=0;
            gather_crc<=16'hffff;gather_changed<=0;probe_index<=0;probe_good<=0;
            initialized<=0;probe_save<=0;init_wait<=joe ? 16'd0 : 16'hffff;
            joe_saw_unready<=0;joe_first_signature<=0;
            joe_prefix_count<=0;joe_selector<=8'hff;joe_prefix_order<=1;
            for(i=0;i<3;i=i+1) joe_magic[i]<=0;
            for(i=0;i<10;i=i+1) joe_slot[i]<=0;
            file_complete<=0;file_accepted<=0;
            for(i=0;i<16;i=i+1) header[i]<=0;
        end else begin
            file_complete<=0;
            last_download<=downloading;last_upload<=uploading;last_osd<=osd_open;
            last_extract<=hs_extract;last_restore<=hs_restore;
            if(phase==RUN && reset_pad!=0 && hs_enable) reset_pad<=reset_pad-1'b1;
            if(score_supported && !initialized && enabled && (phase==RUN || (joe && phase==WAIT_INIT)) && probe==PROBE_IDLE &&
                !hs_restore && !hs_pause && !game_reset && !downloading && init_wait!=0)
                init_wait<=init_wait-1'b1;
            if(last_restore && !hs_restore && score_valid && !game_reset) begin
                restored<=1;initialized<=1;
            end
            if(uploading && !last_upload) begin ioctl_upload_req<=0;upload_final_seen<=0;end
            if(uploading && ioctl_addr==383) upload_final_seen<=1;
            if(!uploading && last_upload && upload_final_seen) dirty<=0;
            if(autosave && osd_open && dirty && !save_busy && !uploading && !last_upload && !ioctl_download) ioctl_upload_req<=1;
            if(osd_open && !last_osd && enabled) snapshot_pending<=1;
            if(!enabled && probe==PROBE_IDLE && !hs_extract) snapshot_pending<=0;

            if(file_start) begin
                phase<=joe ? WAIT_INIT : CFG;feed_index<=0;feed_wait<=0;probe<=PROBE_IDLE;hs_osd<=0;reset_pad<=0;
                load_count<=0;load_crc<=16'hffff;tail_seen<=0;tail_order<=1;
                tail_commit<=0;tail_ff<=1;tail_lanes<=1;tail_padding<=1;format_error<=0;
                file_accepted<=0;
                score_valid<=0;restored<=0;load_pending<=0;snapshot_pending<=0;dirty<=0;
                initialized<=0;probe_save<=0;init_wait<=joe ? 16'd0 : 16'hffff;
                joe_saw_unready<=0;joe_first_signature<=0;
                joe_prefix_count<=0;joe_selector<=8'hff;joe_prefix_order<=1;
                for(i=0;i<3;i=i+1) joe_magic[i]<=0;
                for(i=0;i<10;i=i+1) joe_slot[i]<=0;
            end
            if(joe && downloading && ioctl_wr && ioctl_addr<27'd128) begin
                // A first byte on file_start uses a fresh count, never old state.
                if(ioctl_addr!=(file_start ? 27'd0 : {19'd0,joe_prefix_count}) ||
                    (!file_start && joe_prefix_count>=8'd128)) joe_prefix_order<=0;
                if(file_start || joe_prefix_count<8'd128) joe_prefix_count<=joe_prefix_next;
                case(joe_native_byte)
                    0:joe_magic[0]<=ioctl_dout;
                    1:joe_magic[1]<=ioctl_dout;
                    2:joe_magic[2]<=ioctl_dout;
                    3:joe_selector<=ioctl_dout;
                    default:begin
                        if(joe_selector<8'd6 && joe_native_byte>=joe_slot_base &&
                            joe_native_byte<(joe_slot_base+7'd10))
                            joe_slot[joe_slot_offset[3:0]]<=ioctl_dout;
                    end
                endcase
            end
            if(downloading && ioctl_wr && ioctl_addr>=128) begin
                tail_seen<=1;
                if(ioctl_addr!=(27'd128+{18'd0,load_count}) || load_count>=9'd256) tail_order<=0;
                if(load_count<256) load_count<=load_count+1'b1;
                if(ioctl_addr>=128 && ioctl_addr<144) header[ioctl_addr-128]<=ioctl_dout;
                if(ioctl_addr>=144 && ioctl_addr<383) begin
                    shadow[ioctl_addr-144]<=ioctl_dout;
                    if(ioctl_addr<27'd144+{19'd0,payload_length}) load_crc<=crc_byte(load_crc,ioctl_dout);
                    else if(ioctl_dout!=8'hff) tail_padding<=0;
                    if(ioctl_dout!=8'hff) tail_ff<=0;
                    if(((ioctl_addr-144)&2)!=0 && ioctl_addr<27'd144+{19'd0,table_length} && ioctl_dout!=8'hff) tail_lanes<=0;
                    if(joe && ((ioctl_addr-144)&15)==13 &&
                        ioctl_addr<27'd144+{19'd0,table_length} && ioctl_dout!=0) tail_lanes<=0;
                end
                if(ioctl_addr==383 && ioctl_dout==8'ha5) tail_commit<=1;
            end
            // Clear any old Joe pending state even for empty/rejected input.
            // A valid tail below sets its newly accepted pending bit afterwards.
            // Current-transfer EOF pulse; retained validity is not a verdict.
            if(file_end) begin file_complete<=1;file_accepted<=0;end
            if(joe && file_end) begin load_pending<=0;score_valid<=0;end
            if(file_end && tail_seen) begin
                if(tail_order && load_count==256 && tail_commit &&
                    header[0]=="O" && header[1]=="S" && header[2]=="H" && header[3]=="S" &&
                    header[4]==1 && header[5]==profile && header[6]==payload_length && header[7]==0 && tail_padding &&
                    header[11]==0 && header[12]==0 && header[13]==0 && header[14]==0 && header[15]==0) begin
                    if(header[10]==0 && {header[9],header[8]}==16'hffff && tail_ff) begin
                        score_valid<=0;file_accepted<=1;
                    end else if(header[10]==1 && {header[9],header[8]}==load_crc && tail_lanes &&
                        (charlie || (joe && joe_prefix_valid && joe_prefix_top_matches && shadow[158]==shadow[156]) || (!joe && shadow[232]==shadow[238]))) begin
                        score_valid<=1;score_crc<=load_crc;load_pending<=1;file_accepted<=1;
                    end else format_error<=1;
                end else format_error<=1;
            end

            // A Joe file_start wins over every old phase/probe completion.
            // In particular an old READ/index8 cannot re-latch stale readiness.
            if(!(joe && file_start)) begin
            case(phase)
                CFG: if(!file_start) begin
                    if(feed_wait==3) begin
                        feed_wait<=0;
                        if(feed_index==31) begin phase<=RUN;feed_index<=0;end
                        else feed_index<=feed_index+1'b1;
                    end else feed_wait<=feed_wait+1'b1;
                end
                DUMP: begin
                    if(feed_wait==3) begin
                        feed_wait<=0;
                        if(feed_index==table_length) begin phase<=RUN;feed_index<=0;reset_pad<=2;end
                        else feed_index<=feed_index+1'b1;
                    end else feed_wait<=feed_wait+1'b1;
                end
                GATHER: begin
                    if(feed_wait==4) begin
                        shadow[gather_index]<=hs_out;
                        gather_crc<=crc_byte(gather_crc,hs_out);
                        if(!score_valid || shadow[gather_index]!=hs_out) gather_changed<=1;
                        feed_wait<=0;
                        if(gather_index==table_length) begin
                            phase<=RUN;
                            if(joe && hs_out!=shadow[156]) begin
                                score_valid<=0;dirty<=0;format_error<=1;
                            end else begin
                                score_valid<=1;score_crc<=crc_byte(gather_crc,hs_out);
                                if(gather_changed || !score_valid || shadow[gather_index]!=hs_out) dirty<=1;
                            end
                        end else gather_index<=gather_index+1'b1;
                    end else feed_wait<=feed_wait+1'b1;
                end
                RUN: begin
                    if(load_pending && !downloading && !file_start) begin
                        phase<=DUMP;feed_index<=0;feed_wait<=0;load_pending<=0;
                    end else if(last_extract && !hs_extract) begin
                        phase<=GATHER;gather_index<=0;feed_wait<=0;gather_crc<=16'hffff;gather_changed<=0;
                    end
                end
            endcase

            case(probe)
                PROBE_IDLE: if(snapshot_pending && enabled && phase==RUN && !hs_restore && !hs_pause && !game_reset && !downloading) begin
                    snapshot_pending<=0;probe_index<=0;probe_good<=1;probe_save<=1;
                    if(initialized) begin probe<=PROBE_START;hs_osd<=1;end
                    else probe<=PROBE_WAIT;
                end else if(score_supported && !initialized && enabled && init_wait==0 &&
                    (phase==RUN || (joe && phase==WAIT_INIT)) && !hs_restore && !hs_pause && !game_reset && !downloading) begin
                    init_wait<=joe ? 16'd256 : 16'hffff;probe_save<=0;probe<=PROBE_WAIT;probe_index<=0;
                    probe_good<=joe ? joe_saw_unready : 1'b1;
                end
                PROBE_WAIT: if(paused) probe<=PROBE_READ;
                PROBE_READ: if(access_ready) begin
                    if(joe) begin
                        // Retained factory RAM alone never proves a new boot.
                        // Missing the real pre-init transition leaves this candidate held.
                        if(probe_index==0 && read_value!=8'h09) joe_saw_unready<=1;
                        if(probe_index<8 && read_value!=joe_probe_signature(probe_index)) probe_good<=0;
                        if(probe_index==8) begin
                            if(probe_good && joe_saw_unready && !game_reset) begin
                                joe_first_signature<=read_value;initialized<=1;
                                phase<=CFG;feed_index<=0;feed_wait<=0;
                            end
                            probe<=PROBE_IDLE;
                        end else probe_index<=probe_index+1'b1;
                    end else begin
                    if(probe_index==1 && !charlie && initialized && probe_save) begin
                        if(read_value!=8'h00 && read_value!=8'h01) probe_good<=0;
                    end else if(read_value!=(probe_index==0 ? first_signature : probe_index==1 ? 8'h00 : marker_signature)) probe_good<=0;
                    if(probe_index==2) begin
                        if(probe_good && read_value==marker_signature && !game_reset) begin
                            initialized<=1;
                            if(probe_save) begin probe<=PROBE_START;hs_osd<=1;end
                            else probe<=PROBE_IDLE;
                        end
                        else probe<=PROBE_IDLE;
                    end else probe_index<=probe_index+1'b1;
                    end
                end
                PROBE_START: if(hs_pause) begin probe<=PROBE_IDLE;hs_osd<=0;end
            endcase
            end
            // Reset wins over old probe/completion assignments on this edge.
            // Keep configuration/shadow; deliver reset to the next enabled donor edge.
            if(game_reset) begin
                restored<=0;initialized<=0;init_wait<=joe ? 16'd0 : 16'hffff;last_restore<=0;reset_pad<=1;
                if(joe) begin
                    phase<=WAIT_INIT;feed_index<=0;feed_wait<=0;
                    // File edges own their accepted/cleared pending state.
                    // Do not resurrect or erase it using pre-edge score_valid.
                    if(!file_start && !file_end && !downloading) load_pending<=score_valid;
                    joe_saw_unready<=0;joe_first_signature<=0;
                end
                probe<=PROBE_IDLE;probe_index<=0;probe_good<=0;probe_save<=0;
                hs_osd<=0;snapshot_pending<=0;
            end
        end
    end
endmodule
