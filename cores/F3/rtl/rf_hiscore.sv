// F3 EEPROM + per-set RAM scores, all ports synchronous to clk_sys.
// Config index 3: 8 LE words (HS, version, count, bytes, id_lo, id_hi,
// legacy_allowed, boot_frames), then {offset_lo, offset_hi, length, guards}.
// NVRAM index 254: 128 EEPROM bytes, 16-byte F3HS header, score bytes.
module rf_hiscore #(
    parameter MAX_WORDS = 1024,
    parameter VARIABLE_RAM=0,
    parameter SYNC_EEPROM=0
)(
    input logic clk, clear, reset, run, vbl_rise,
    input logic osd_visible,
    input logic ioctl_download, ioctl_upload, ioctl_wr,
    input logic [7:0] ioctl_index,
    input logic [26:0] ioctl_addr,
    input logic [15:0] ioctl_dout,
    output logic [15:0] sv_data,
    output logic upload_req, upload_wait,
    output logic hs_pause,
    input logic hs_grant,
    output logic hs_req, input wire hs_ready,
    output logic [15:0] hs_addr,
    output logic [15:0] hs_wdata,
    output logic [1:0] hs_be,
    output logic hs_we,
    input logic [15:0] hs_q,
    output logic [5:0] nv_addr,
    input logic [15:0] nv_q,
    output logic save_ready, sh_ok_o, injected_o
);
    localparam [15:0] CFG_MAGIC=16'h5348, FILE_MAGIC=16'h3346;
    logic [16:0] offsets [0:7];
    logic [11:0] lengths [0:7];
    logic [15:0] guards [0:7];
    logic [1:0] skip_guard [0:7];
    logic [15:0] cfg_header [0:7];
    logic [6:0] cfg_words=0;
    logic [15:0] cfg_sum=0;
    logic cfg_bad=0, configured=0;
    logic [3:0] count=0;
    logic [11:0] total=0;
    logic [31:0] profile_id=0;
    logic legacy_allowed=0;
    logic [15:0] boot_frames=0;
    wire config_load=ioctl_download && ioctl_index==8'd3;
    wire nv_load=ioctl_download && ioctl_index==8'd254;
    wire nv_upload=ioctl_upload && ioctl_index==8'd254;
    logic cfg_d=0, load_d=0, upload_d=0;
    logic [15:0] header [0:7];
    logic [11:0] load_words=0;
    logic load_bad=0, legacy=0, file_valid=0, legacy_nonempty=0;
    logic [31:0] load_sum=0, snapshot_sum=0, stored_sum=0;
    logic [15:0] shadow [0:MAX_WORDS-1];
    wire [15:0] ee_shadow_q;
    logic [9:0] shadow_addr;
    logic [15:0] shadow_q;
    always_ff @(posedge clk) shadow_q <= shadow[shadow_addr];

    // Loader processing is independent of CPU reset, including first boot.
    wire [26:0] tail_word=(ioctl_addr-27'd128)>>1;
    wire [26:0] payload_word=legacy ? tail_word : tail_word-27'd8;
    logic shadow_we=0;
    logic [9:0] shadow_waddr;
    logic [15:0] shadow_wdata;
    wire load_payload=nv_load && ioctl_wr && ioctl_addr>=128 &&
        ((load_words==0 && ioctl_dout!=FILE_MAGIC && legacy_allowed) ||
         (load_words!=0 && (legacy || tail_word>=8)));
    always_ff @(posedge clk) begin
        if (load_payload && (load_words==0 || payload_word<MAX_WORDS))
            shadow[load_words==0 ? 10'd0 : payload_word[9:0]] <= ioctl_dout;
        else if (shadow_we) shadow[shadow_waddr] <= shadow_wdata;
    end

    logic snapshot_complete=0;
    wire capture_invalidate;
    always_ff @(posedge clk) begin
        cfg_d<=config_load; load_d<=nv_load; upload_d<=nv_upload;
        if (clear) begin
            cfg_words<=0; cfg_sum<=0; cfg_bad<=0; configured<=0;
            file_valid<=0; count<=0; total<=0; legacy_allowed<=0;
            load_words<=0; load_bad<=0; load_sum<=0; stored_sum<=0;
        end else begin
            if (config_load && !cfg_d) begin
                cfg_words<=0; cfg_sum<=0; cfg_bad<=0; configured<=0;
            end
            if (config_load && ioctl_wr) begin
                if (ioctl_addr != {19'd0,cfg_words,1'b0} || ioctl_addr>=80 || ioctl_addr[0]) cfg_bad<=1;
                if (ioctl_addr<16) cfg_header[ioctl_addr[3:1]]<=ioctl_dout;
                else if (ioctl_addr<80) begin
                    case(ioctl_addr[2:1])
                        0: offsets[(ioctl_addr-16)>>3][15:0]<=ioctl_dout;
                        1: begin
                            offsets[(ioctl_addr-16)>>3][16]<=ioctl_dout[0];
                            skip_guard[(ioctl_addr-16)>>3]<=ioctl_dout[9:8];
                            if((ioctl_dout & 16'hfcfe)!=0) cfg_bad<=1;
                        end
                        2: begin
                            lengths[(ioctl_addr-16)>>3]<=ioctl_dout[11:0];
                            cfg_sum<=cfg_sum+ioctl_dout;
                            if(ioctl_dout==0 || ioctl_dout>2048) cfg_bad<=1;
                        end
                        3: begin
                            guards[(ioctl_addr-16)>>3]<=ioctl_dout;
                            if({1'b0,offsets[(ioctl_addr-16)>>3]}+{6'd0,lengths[(ioctl_addr-16)>>3]}>18'h20000) cfg_bad<=1;
                        end
                    endcase
                end
                if(cfg_words<127) cfg_words<=cfg_words+1'b1;
            end
            if (!config_load && cfg_d) begin
                configured<=!cfg_bad && cfg_header[0]==CFG_MAGIC && cfg_header[1]==1 &&
                    cfg_header[2]<=8 && cfg_header[3]<=2048 && cfg_sum==cfg_header[3] &&
                    cfg_words==8+4*cfg_header[2] && ((cfg_header[2]==0)==(cfg_header[3]==0));
                count<=cfg_header[2][3:0]; total<=cfg_header[3][11:0];
                profile_id<={cfg_header[5],cfg_header[4]};
                legacy_allowed<=cfg_header[6][0]; boot_frames<=cfg_header[7];
            end
            if(nv_load && !load_d) begin
                file_valid<=0; load_words<=0; load_bad<=0; load_sum<=0; legacy<=0; legacy_nonempty<=0;
            end
            if(nv_load && ioctl_wr && ioctl_addr>=128) begin
                if(ioctl_addr != 128+{14'd0,load_words,1'b0} || ioctl_addr[0] || load_words>=1032) load_bad<=1;
                if(load_words==0) begin
                    legacy<=ioctl_dout!=FILE_MAGIC && legacy_allowed;
                    if(ioctl_dout!=FILE_MAGIC && !legacy_allowed) load_bad<=1;
                end
                if(tail_word<8) header[tail_word[2:0]]<=ioctl_dout;
                if(load_payload && (load_words==0 || payload_word<((total+1)>>1))) begin
                    load_sum<=load_sum+{16'd0,ioctl_dout};
                    if(ioctl_dout!=0 && ioctl_dout!=16'hffff) legacy_nonempty<=1;
                end
                if(load_words<4095) load_words<=load_words+1'b1;
            end
            if(!nv_load && load_d) begin
                file_valid<=configured && !load_bad && count!=0 &&
                    ((legacy && legacy_allowed && legacy_nonempty && load_words>=((total+1)>>1) && load_words<=64) ||
                     (!legacy && load_words==8+((total+1)>>1) &&
                      header[0]==FILE_MAGIC && header[1]==16'h5348 && header[2]==1 &&
                      header[3]=={4'd0,total} && {header[5],header[4]}==profile_id &&
                      {header[7],header[6]}==load_sum));
                stored_sum<=load_sum;
            end
            if(snapshot_complete && count!=0) begin file_valid<=1;stored_sum<=snapshot_sum;end
            if(capture_invalidate) file_valid<=0;
        end
    end

    typedef enum logic [4:0] {IDLE,WAIT_GRANT,GUARD_ADDR,GUARD_WAIT,GUARD_CHECK,
        RESTORE_ADDR,RESTORE_WAIT,RESTORE_WRITE,RESTORE_DRAIN,
        COPY_EEPROM,CAPTURE_ADDR,CAPTURE_WAIT,CAPTURE_BYTE,CAPTURE_DRAIN,RELEASE,ABORT_WAIT,RESTORE_ISSUE,COPY_EEPROM_WAIT} state_t;
    state_t state=IDLE;
    logic [3:0] range_no=0;
    logic end_guard=0, want_capture=0, checked_once=0, restore_done=0;
    logic shadow_good=0;
    logic [11:0] byte_no=0, range_byte=0, guard_dump=0;
    logic [7:0] low_byte=0;
    logic [6:0] ee_index=0;
    logic [15:0] frames=0;
    logic upload_pending=0, snapshot_ready=0, snapshot_valid=0;
    logic request_issued=0, session_visible=0;
    logic session_snapshot=0;
    assign capture_invalidate=state==CAPTURE_ADDR && byte_no==0;
    wire [16:0] ram_byte=offsets[range_no[2:0]]+{5'd0,range_byte};
    wire [7:0] ram_data=ram_byte[0] ? hs_q[7:0] : hs_q[15:8];
    wire [7:0] score_byte=byte_no[0] ? shadow_q[15:8] : shadow_q[7:0];
    wire [11:0] guard_byte=guard_dump+(end_guard ? lengths[range_no[2:0]]-12'd1 : 12'd0);
    wire [7:0] expected_guard=end_guard ? guards[range_no[2:0]][15:8] : guards[range_no[2:0]][7:0];
    wire [7:0] file_guard=guard_byte[0] ? shadow_q[15:8] : shadow_q[7:0];
    wire capture_start=nv_upload && !upload_d;
    assign upload_wait=nv_upload && !snapshot_ready;
    assign nv_addr=ee_index[5:0];
    wire copy_ee=state==COPY_EEPROM && !clear && (!reset || nv_upload);
    generate if(SYNC_EEPROM)begin: native_ee_snapshot
        rf_bram #(.WIDTH(16),.AW(6)) data(.clk(clk),.waddr(ee_index[5:0]),.wdata(nv_q),.wren(copy_ee),
            .raddr(ioctl_addr[6:1]),.q(ee_shadow_q));
    end else begin: legacy_ee_snapshot
        logic [15:0] words[0:63];
        logic [15:0] ee_q;
        always_ff @(posedge clk)begin
            if(copy_ee)words[ee_index[5:0]]<=nv_q;
            ee_q<=words[ioctl_addr[6:1]];
        end
        assign ee_shadow_q=ee_q;
    end endgenerate
    always_comb begin
        shadow_addr=byte_no[10:1];
        if(state==GUARD_ADDR || state==GUARD_WAIT || state==GUARD_CHECK) shadow_addr=guard_byte[10:1];
        else if(nv_upload && snapshot_ready && ioctl_addr>=144) shadow_addr=10'((ioctl_addr-144)>>1);
    end
    logic ee_select;
    logic [15:0] other_data;
    assign sv_data=ee_select?ee_shadow_q:other_data;
    always_ff @(posedge clk) begin
        ee_select<=ioctl_addr<128;
        if(ioctl_addr>=128 && ioctl_addr<144) begin
            case(ioctl_addr[3:1])
                0: other_data<=snapshot_valid ? FILE_MAGIC : 16'd0;
                1: other_data<=16'h5348;
                2: other_data<=16'd1;
                3: other_data<={4'd0,total};
                4: other_data<=profile_id[15:0];
                5: other_data<=profile_id[31:16];
                6: other_data<=snapshot_sum[15:0];
                7: other_data<=snapshot_sum[31:16];
            endcase
        end else other_data<=shadow_q;
    end

    // Main polls the upload request before drawing the first OSD page.
    // Pre-arm in gameplay; re-arm only after the actual overlay closes.
    // Info/submenu OSD_STATUS changes do not affect osd_visible.
    always_ff @(posedge clk) begin
        upload_req<=0;
        if(clear || reset) begin request_issued<=0; session_visible<=0; end
        else begin
            if(osd_visible) session_visible<=1;
            if(session_visible && !osd_visible && !nv_upload) begin
                session_visible<=0; request_issued<=0;
            end
            if(run && configured && save_ready && !osd_visible && !request_issued && !nv_upload && !nv_load) begin
                upload_req<=1; request_issued<=1;
            end
            if(capture_start) request_issued<=1;
        end
    end

    // A completion grant replaces the old guessed 64-cycle CPU pause.
    // Registered RAM/shadow reads have address/wait/consume stages.
    always_ff @(posedge clk) begin
        if(!VARIABLE_RAM)begin hs_we<=0;hs_req<=0;end
        shadow_we<=0; snapshot_complete<=0;
        if(clear || (reset && !nv_upload)) begin
            state<=IDLE; hs_pause<=0;hs_req<=0;hs_we<=0; frames<=0; save_ready<=0;
            restore_done<=0; checked_once<=0; injected_o<=0; sh_ok_o<=0;
            upload_pending<=0; snapshot_ready<=0; want_capture<=0; session_snapshot<=0;
        end else begin
            if(vbl_rise && run && frames<boot_frames) frames<=frames+1'b1;
            if(session_visible && !osd_visible && !nv_upload) session_snapshot<=0;
            if(capture_start) begin
                upload_pending<=!session_snapshot;
                snapshot_ready<=session_snapshot;
            end
            if(!nv_upload) snapshot_ready<=0;
            case(state)
                IDLE: begin
                    if(configured && run && count==0) save_ready<=1;
                    // Snapshot on every upload, score profile or not: Main's
                    // "Save settings" uploads index 254 unconditionally, and
                    // upload_wait holds ioctl_wait until snapshot_ready. Gating
                    // this on `configured` froze the whole MiSTer (SPI blocked)
                    // on sets without an MRA index-3 profile. Unconfigured
                    // sets have count==0, so only the EEPROM is copied.
                    if(upload_pending || (capture_start && !session_snapshot)) begin
                        hs_pause<=1; want_capture<=1; state<=WAIT_GRANT;
                    end else if(configured && run && count!=0 && !restore_done &&
                                vbl_rise && frames==boot_frames && !nv_load) begin
                        hs_pause<=1; want_capture<=0; range_no<=0; end_guard<=0;
                        guard_dump<=0; shadow_good<=file_valid; state<=WAIT_GRANT;
                    end
                end
                WAIT_GRANT: if(hs_grant) begin
                    if(want_capture) begin
                        ee_index<=0; snapshot_sum<=save_ready ? 32'd0 : stored_sum;
                        snapshot_valid<=save_ready || file_valid; state<=SYNC_EEPROM?COPY_EEPROM_WAIT:COPY_EEPROM;
                    end else state<=GUARD_ADDR;
                end
                GUARD_ADDR: begin
                    hs_addr<=(offsets[range_no[2:0]]+(end_guard ? {5'd0,lengths[range_no[2:0]]}-17'd1 : 17'd0))>>1;
                    if(VARIABLE_RAM)begin hs_req<=1;hs_we<=0;end
                    state<=GUARD_WAIT;
                end
                GUARD_WAIT: if(!VARIABLE_RAM || hs_ready)begin hs_req<=0;state<=GUARD_CHECK;end
                GUARD_CHECK: begin
                    if(!skip_guard[range_no[2:0]][end_guard] &&
                       ((offsets[range_no[2:0]][0] ^ (end_guard && !lengths[range_no[2:0]][0])) ? hs_q[7:0] : hs_q[15:8])!=expected_guard) begin
                        checked_once<=0; state<=RELEASE;
                    end else begin
                        // hiscore.dat guards describe the game's DEFAULT table.
                        // A saved winner's name/score can change these bytes.
                        // File identity/length/checksum validate the saved payload.
                        if(!end_guard) begin end_guard<=1; state<=GUARD_ADDR; end
                        else if(range_no+1<count) begin
                            guard_dump<=guard_dump+lengths[range_no[2:0]];
                            range_no<=range_no+1'b1; end_guard<=0; state<=GUARD_ADDR;
                        end else if(!checked_once) begin checked_once<=1; state<=RELEASE; end
                        else begin
                            save_ready<=1;
                            sh_ok_o<=shadow_good;
                            if(shadow_good) begin
                                byte_no<=0; range_no<=0; range_byte<=0; state<=RESTORE_ADDR;
                            end else begin restore_done<=1; state<=RELEASE; end
                        end
                    end
                end
                RESTORE_ADDR: begin
                    // The shadow BRAM address follows byte_no. Allow its
                    // registered read to settle after the preceding byte.
                    state<=VARIABLE_RAM?RESTORE_ISSUE:RESTORE_WAIT;
                end
                RESTORE_ISSUE: begin
                    hs_addr<=ram_byte[16:1];hs_wdata<={score_byte,score_byte};
                    hs_be<=ram_byte[0]?2'b01:2'b10;hs_we<=1;hs_req<=1;
                    state<=RESTORE_WAIT;
                end
                RESTORE_WAIT: if(!VARIABLE_RAM || hs_ready)begin
                    hs_req<=0;if(VARIABLE_RAM)hs_we<=0;state<=RESTORE_WRITE;
                end
                RESTORE_WRITE: begin
                    if(!VARIABLE_RAM)begin
                        hs_addr<=ram_byte[16:1];hs_wdata<={score_byte,score_byte};
                        hs_be<=ram_byte[0]?2'b01:2'b10;hs_we<=1;
                    end
                    if(byte_no+1==total) state<=RESTORE_DRAIN;
                    else begin
                        byte_no<=byte_no+1'b1;
                        if(range_byte+1==lengths[range_no[2:0]]) begin range_no<=range_no+1'b1;range_byte<=0;end
                        else range_byte<=range_byte+1'b1;
                        state<=RESTORE_ADDR;
                    end
                end
                RESTORE_DRAIN: begin restore_done<=1; injected_o<=1; state<=RELEASE; end
                COPY_EEPROM_WAIT:state<=COPY_EEPROM;
                COPY_EEPROM: begin
                    if(ee_index==63) begin
                        range_no<=0; range_byte<=0; byte_no<=0;
                        if(count!=0 && save_ready) state<=CAPTURE_ADDR; else state<=CAPTURE_DRAIN;
                    end else begin ee_index<=ee_index+1'b1;if(SYNC_EEPROM)state<=COPY_EEPROM_WAIT;end
                end
                CAPTURE_ADDR: begin
                    hs_addr<=ram_byte[16:1];if(VARIABLE_RAM)begin hs_req<=1;hs_we<=0;end
                    state<=CAPTURE_WAIT;
                end
                CAPTURE_WAIT: if(!VARIABLE_RAM || hs_ready)begin hs_req<=0;state<=CAPTURE_BYTE;end
                CAPTURE_BYTE: begin
                    if(!byte_no[0]) low_byte<=ram_data;
                    if(byte_no[0] || byte_no+1==total) begin
                        shadow_we<=1; shadow_waddr<=byte_no[10:1];
                        shadow_wdata<=byte_no[0] ? {ram_data,low_byte} : {8'd0,ram_data};
                        snapshot_sum<=snapshot_sum+{16'd0,(byte_no[0] ? {ram_data,low_byte} : {8'd0,ram_data})};
                    end
                    if(byte_no+1==total) state<=CAPTURE_DRAIN;
                    else begin
                        byte_no<=byte_no+1'b1;
                        if(range_byte+1==lengths[range_no[2:0]]) begin range_no<=range_no+1'b1;range_byte<=0;end
                        else range_byte<=range_byte+1'b1;
                        state<=CAPTURE_ADDR;
                    end
                end
                CAPTURE_DRAIN: begin
                    snapshot_ready<=1; upload_pending<=0;
                    session_snapshot<=1;
                    snapshot_complete<=count!=0 && save_ready; state<=RELEASE;
                end
                ABORT_WAIT: if(hs_ready || !hs_req)begin hs_req<=0;hs_we<=0;state<=RELEASE;end
                RELEASE: begin hs_pause<=0;hs_req<=0;hs_we<=0;state<=IDLE;end
                default: state<=IDLE;
            endcase
            // Drain any already scheduled byte write on an aborted upload.
            if(want_capture && !nv_upload && state!=IDLE && state!=RELEASE) begin
                if(VARIABLE_RAM && hs_req && !hs_ready)state<=ABORT_WAIT;
                else begin hs_req<=0;hs_we<=0;state<=RELEASE;end
                upload_pending<=0;snapshot_ready<=0;
            end
        end
    end
endmodule
