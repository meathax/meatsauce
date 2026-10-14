// MiSTer hiscore v14 index-3 configuration/index-4 dump protocol, adapted to
// acknowledged CPU RAM. Uses dpram_hs from the pinned GPLv3 hiscore.v donor.
// The fixed-delay donor FSM cannot stall on ram_ack; this adapter owns the FSM.
// Snapshot banks make an interrupted extraction/download leave the old save intact.
module argus_hiscore #(parameter bit HPS_UPLOAD_PREFETCH=0) (
    input logic clk_sys, reset, session_reset, game_reset,
    input logic [1:0] game_id,
    input logic frame_start, ram_grant, osd_open, autosave,
    // Accepted CPU work-RAM writes only; exclude hiscore borrowed writes.
    input logic cpu_ram_write,
    input logic [15:0] cpu_ram_addr,
    input logic [7:0] cpu_ram_wdata,
    input logic ioctl_download, ioctl_upload, ioctl_wr, ioctl_rd,
    input logic [24:0] ioctl_addr,
    input logic [7:0] ioctl_index, data_from_hps,
    output logic [7:0] data_to_hps,
    output logic ioctl_upload_req, ioctl_wait,
    output logic configured, initialized, dirty, protocol_error,
    output logic pause_cpu, ram_req, ram_we,
    output logic [15:0] ram_addr,
    output logic [7:0] ram_wdata,
    input logic ram_ack,
    input logic [7:0] ram_rdata
);
    `include "argus_hiscore_profile.svh"
    typedef enum logic [3:0] {IDLE, BORROW, CHECK_WAIT, CHECK_NEXT,
        CAPTURE_REQ, CAPTURE_WAIT, CAPTURE_NEXT, RESTORE_READ,
        RESTORE_REQ, RESTORE_WAIT, RESTORE_NEXT} state_t;
    state_t state;
    logic [1:0] last_game;
    logic last_download, last_upload, last_osd, last_game_reset;
    logic [7:0] last_index;
    logic [9:0] cfg_count, dump_count, upload_count;
    logic cfg_bad, dump_bad, upload_bad;
    logic active_bank, snapshot_valid, restore_pending, pending_save;
    logic signature_ok, changed, capture_write;
    logic require_invalidation;
    logic [2:0] sig_index;
    logic [8:0] offset;
    logic [7:0] captured_data;
    logic [7:0] bank0_q, bank1_q;
    wire cfg_transfer = ioctl_download && ioctl_index == 3;
    wire dump_transfer = ioctl_download && ioctl_index == 4;
    wire upload_transfer = ioctl_upload && ioctl_index == 4;
    wire clear_session = reset || session_reset || last_game != game_id;
    wire valid_game = game_id != 3;
    wire [9:0] dump_size = hs_dump_bytes(game_id);
    wire [8:0] buffer_read_address = upload_transfer ? ioctl_addr[8:0] : offset;
    wire [8:0] buffer_write_address = dump_transfer ? ioctl_addr[8:0] : offset;
    wire [7:0] buffer_write_data = dump_transfer ? data_from_hps : captured_data;
    wire buffer_write = (dump_transfer && ioctl_wr && !ioctl_wait &&
        ioctl_addr == {15'd0,dump_count} && dump_count < dump_size) || capture_write;
    wire [7:0] active_data = active_bank ? bank1_q : bank0_q;

    argus_sync_line_ram #(.AW(9),.DW(8)) bank0(
        .clk(clk_sys),.waddr(buffer_write_address),
        .we(buffer_write && active_bank && !clear_session),.wdata(buffer_write_data),
        .raddr(buffer_read_address),.q(bank0_q));

    argus_sync_line_ram #(.AW(9),.DW(8)) bank1(
        .clk(clk_sys),.waddr(buffer_write_address),
        .we(buffer_write && !active_bank && !clear_session),.wdata(buffer_write_data),
        .raddr(buffer_read_address),.q(bank1_q));
    always_comb begin
        data_to_hps = snapshot_valid && ioctl_addr < {15'd0,dump_size} ? active_data : 8'd0;
        // Parent forwards this to hps_io.ioctl_wait. Active borrow finishes before
        // a save upload or dump/config replacement is accepted.
        ioctl_wait = (cfg_transfer || dump_transfer || upload_transfer) && state != IDLE;
    end

    always_ff @(posedge clk_sys) begin
        if (clear_session) begin
            last_game <= game_id;
            last_download <= 0; last_upload <= 0; last_osd <= osd_open;
            last_game_reset <= game_reset; last_index <= 0;
            cfg_count <= 0; dump_count <= 0; upload_count <= 0;
            cfg_bad <= 0; dump_bad <= 0; upload_bad <= 0;
            configured <= 0; initialized <= 0; dirty <= 0; protocol_error <= 0;
            active_bank <= 0; snapshot_valid <= 0; restore_pending <= 0;
            pending_save <= 0; signature_ok <= 0; changed <= 0;
            // Work RAM survives session/game reset. A ROM replacement needs
            // new invalid->valid markers; cold reset uses normal DAT gating.
            require_invalidation <= !reset && (session_reset || last_game != game_id);
            sig_index <= 0; offset <= 0; capture_write <= 0; captured_data <= 0;
            state <= IDLE; pause_cpu <= 0; ram_req <= 0; ram_we <= 0;
            ram_addr <= 0; ram_wdata <= 0; ioctl_upload_req <= 0;
        end else begin
            // Latch even a sub-frame invalidation. Polling once per frame can
            // miss a complete clear/rebuild between two borrowing windows.
            // Static DAT endpoints are available before config3 arrives.
            if(cpu_ram_write && !game_reset && valid_game) begin
                for(integer marker=0;marker<6;marker=marker+1)
                    if(3'(marker)<hs_signature_count(game_id) &&
                       cpu_ram_addr==hs_signature_address(game_id,3'(marker)) &&
                       cpu_ram_wdata!=hs_signature_value(game_id,3'(marker)))
                        require_invalidation <= 0;
            end
            last_game <= game_id;
            last_download <= ioctl_download; last_upload <= ioctl_upload;
            last_index <= ioctl_index; last_osd <= osd_open; last_game_reset <= game_reset;
            ioctl_upload_req <= 0;
            capture_write <= 0;
            if (osd_open && !last_osd && !game_reset) pending_save <= 1;

            if (!ioctl_download) begin
                cfg_count <= 0; dump_count <= 0; cfg_bad <= 0; dump_bad <= 0;
            end
            if (cfg_transfer && ioctl_wr && !ioctl_wait) begin
                if (ioctl_addr != {15'd0,cfg_count} || cfg_count >= {4'd0,hs_config_bytes(game_id)} ||
                    data_from_hps != hs_config_byte(game_id,ioctl_addr[5:0]) || !valid_game) begin
                    cfg_bad <= 1; protocol_error <= 1;
                end
                cfg_count <= cfg_count + 1'b1;
            end
            if (dump_transfer && ioctl_wr && !ioctl_wait) begin
                if (ioctl_addr != {15'd0,dump_count} || dump_count >= dump_size || !configured) begin
                    dump_bad <= 1; protocol_error <= 1;
                end
                dump_count <= dump_count + 1'b1;
            end
            if (last_download && !ioctl_download) begin
                if (last_index == 3) begin
                    configured <= !cfg_bad && cfg_count == {4'd0,hs_config_bytes(game_id)} && valid_game;
                    if (cfg_bad || cfg_count != {4'd0,hs_config_bytes(game_id)}) protocol_error <= 1;
                end
                if (last_index == 4) begin
                    if (!dump_bad && dump_count == dump_size && configured) begin
                        active_bank <= ~active_bank;
                        snapshot_valid <= 1; dirty <= 0; restore_pending <= 1;
                    end else protocol_error <= 1;
                end
            end
            if (!ioctl_upload) begin upload_count <= 0; upload_bad <= 0; end
            // Native hps_io prefetches address 0 before any host byte is consumed.
            // Subsequent rd pulses carry the next prefetch address (1..N),
            // so only those pulses count bytes already sent to the host.
            if (upload_transfer && ioctl_rd && !ioctl_wait && (!HPS_UPLOAD_PREFETCH || ioctl_addr!=0)) begin
                if (!snapshot_valid || ioctl_addr != ({15'd0,upload_count} + (HPS_UPLOAD_PREFETCH ? 25'd1 : 25'd0)) || upload_count >= dump_size)
                    upload_bad <= 1;
                upload_count <= upload_count + 1'b1;
            end
            if (last_upload && !ioctl_upload && last_index == 4 && !upload_bad && upload_count == dump_size)
                dirty <= 0;

            // A game reset retains the committed save/config but abandons a
            // partially captured table. Parent clears a session for ROM changes,
            // including butasan <-> butasanj (same game_id, different set).
            if (game_reset) begin
                // Old matching markers do not prove the reboot completed.
                // CPU write observation records an invalid interval even when
                // clear/rebuild finishes before the first frame poll.
                require_invalidation <= 1;
                initialized <= 0; pending_save <= 0; state <= IDLE;
                pause_cpu <= 0; ram_req <= 0; ram_we <= 0; capture_write <= 0;
                if (!last_game_reset) restore_pending <= snapshot_valid;
            end else case (state)
                IDLE: begin
                    pause_cpu <= 0; ram_req <= 0; ram_we <= 0;
                    if (configured && valid_game && !ioctl_download && !ioctl_upload) begin
                        if (frame_start && (!initialized || restore_pending)) begin
                            pause_cpu <= 1; sig_index <= 0; signature_ok <= 1; state <= BORROW;
                        end else if (initialized && pending_save) begin
                            pause_cpu <= 1; offset <= 0; changed <= !snapshot_valid;
                            pending_save <= 0; state <= CAPTURE_REQ;
                        end
                    end
                end
                BORROW: if (ram_grant) begin
                    ram_addr <= hs_signature_address(game_id,sig_index); ram_we <= 0;
                    ram_req <= 1; state <= CHECK_WAIT;
                end
                CHECK_WAIT: if (ram_req && ram_ack) begin
                    ram_req <= 0;
                    signature_ok <= signature_ok && ram_rdata == hs_signature_value(game_id,sig_index);
                    state <= CHECK_NEXT;
                end
                CHECK_NEXT: begin
                    if (sig_index + 1'b1 == hs_signature_count(game_id)) begin
                        if(!signature_ok) require_invalidation <= 0;
                        if (signature_ok && !require_invalidation) begin
                            initialized <= 1; offset <= 0;
                            if (restore_pending && snapshot_valid) state <= RESTORE_READ;
                            else begin state <= IDLE; pause_cpu <= 0; end
                        end else begin state <= IDLE; pause_cpu <= 0; end
                    end else begin sig_index <= sig_index + 1'b1; state <= BORROW; end
                end
                CAPTURE_REQ: if (ram_grant) begin
                    ram_addr <= hs_dump_address(game_id,offset); ram_we <= 0;
                    ram_req <= 1; state <= CAPTURE_WAIT;
                end
                CAPTURE_WAIT: if (ram_req && ram_ack) begin
                    ram_req <= 0; captured_data <= ram_rdata; capture_write <= 1;
                    changed <= changed || ram_rdata != active_data; state <= CAPTURE_NEXT;
                end
                CAPTURE_NEXT: begin
                    if ({1'b0,offset} + 1'b1 == dump_size) begin
                        if (changed) begin active_bank <= ~active_bank; snapshot_valid <= 1; dirty <= 1; end
                        if (autosave && (changed || dirty)) ioctl_upload_req <= 1;
                        state <= IDLE; pause_cpu <= 0;
                    end else begin offset <= offset + 1'b1; state <= CAPTURE_REQ; end
                end
                RESTORE_READ: state <= RESTORE_REQ; // dpram_hs read latency
                RESTORE_REQ: if (ram_grant) begin
                    ram_addr <= hs_dump_address(game_id,offset); ram_wdata <= active_data;
                    ram_we <= 1; ram_req <= 1; state <= RESTORE_WAIT;
                end
                RESTORE_WAIT: if (ram_req && ram_ack) begin
                    ram_req <= 0; ram_we <= 0; state <= RESTORE_NEXT;
                end
                RESTORE_NEXT: begin
                    if ({1'b0,offset} + 1'b1 == dump_size) begin
                        restore_pending <= 0; state <= IDLE; pause_cpu <= 0;
                    end else begin offset <= offset + 1'b1; state <= RESTORE_READ; end
                end
                default: begin state <= IDLE; pause_cpu <= 0; ram_req <= 0; ram_we <= 0; protocol_error <= 1; end
            endcase
        end
    end
endmodule
