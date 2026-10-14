// SPDX-License-Identifier: GPL-3.0-or-later
// Stage the EEPROM prefix independently of the optional checked score trailer.
module osman_nvram (
    input wire clk, reset, image_start, seed_ready, game_reset,
    input wire [7:0] profile,
    input wire score_file_complete, score_file_accepted, eeprom_restore_ready,
    input wire paused, eeprom_busy, osd_open, autosave,
    input wire ioctl_download, ioctl_upload, ioctl_wr,
    input wire [26:0] ioctl_addr,
    input wire [15:0] ioctl_index,
    input wire [7:0] ioctl_dout,
    output wire [7:0] ioctl_din,
    output reg ioctl_upload_req,
    output wire ready,
    output reg restore_error,
    output wire pause_request,
    output wire eeprom_restore_en,
    output reg [5:0] eeprom_restore_addr,
    output reg [15:0] eeprom_restore_data,
    output wire [5:0] eeprom_read_addr,
    input wire [15:0] eeprom_read_data
);
    localparam IDLE=0, COMMIT=2;
    wire downloading_nvram = ioctl_download && ioctl_index == 16'd4;
    wire downloading_finish = ioctl_download && ioctl_index == 16'd255;
    reg last_nvram, last_finish, final_seen, marker_seen, last_donor_req;
    wire file_start = downloading_nvram && !last_nvram;
    wire file_end = !downloading_nvram && last_nvram;
    reg [1:0] restore_phase;
    reg [8:0] received_bytes;
    reg receive_ok;
    reg [7:0] receive_profile, high_byte;
    reg [15:0] prefix_words[0:63];
    reg [5:0] commit_word;
    reg restore_pulse;
    wire commit_epoch_live = !reset && !image_start && seed_ready && receive_profile==profile && !restore_error;
    // Keep valid/address/data until actual seed-priority sink acceptance.
    // Mask live epoch loss before the physical EEPROM consumes a word.
    assign eeprom_restore_en = restore_pulse && commit_epoch_live;
    wire [8:0] effective_count = file_start ? 9'd0 : received_bytes;
    wire [6:0] donor_addr;
    wire donor_pause, donor_upload_req;
    wire [7:0] donor_data = donor_addr[0] ? eeprom_read_data[7:0] : eeprom_read_data[15:8];

    // Last restore pulse is consumed by the EEPROM on the NEXT edge.
    // Never release CPU or score RAM while that final word is still in flight.
    assign ready = !reset && !image_start && seed_ready && final_seen && !restore_error && !downloading_nvram &&
        restore_phase==IDLE && !restore_pulse;
    assign eeprom_read_addr = donor_addr[6:1];
    assign pause_request = downloading_nvram || restore_phase!=IDLE || restore_pulse || (ready && donor_pause);

    nvram #(.DUMPWIDTH(7), .CONFIGINDEX(3), .DUMPINDEX(4), .PAUSEPAD(4)) u_nvram (
        .clk(clk), .reset(reset || game_reset || !ready), .paused(paused),
        .autosave(autosave), .OSD_STATUS(osd_open && !eeprom_busy && ready),
        .ioctl_download(ioctl_download), .ioctl_upload(ioctl_upload),
        // Full raw transfer goes to this wrapper; donor framing stays128 bytes.
        .ioctl_wr(ioctl_wr && (ioctl_index!=16'd4 || ioctl_addr<27'd128)),
        .ioctl_addr(ioctl_addr[24:0]), .ioctl_index(ioctl_index[7:0]),
        .ioctl_dout(ioctl_dout), .ioctl_din(ioctl_din), .ioctl_upload_req(donor_upload_req),
        .nvram_address(donor_addr), .nvram_data_out(donor_data), .pause_cpu(donor_pause)
    );

    always @(posedge clk) begin
        last_nvram<=downloading_nvram;last_finish<=downloading_finish;last_donor_req<=donor_upload_req;
        if(reset || image_start) begin
            last_nvram<=0;last_finish<=0;last_donor_req<=0;final_seen<=0;marker_seen<=0;
            received_bytes<=0;receive_ok<=0;receive_profile<=profile;high_byte<=0;
            restore_phase<=IDLE;commit_word<=0;restore_pulse<=0;
            eeprom_restore_addr<=0;eeprom_restore_data<=0;restore_error<=0;ioctl_upload_req<=0;
        end else begin
            if(file_start) begin
                final_seen<=0;received_bytes<=0;high_byte<=0;receive_profile<=profile;
                receive_ok<=seed_ready && restore_phase==IDLE && !restore_pulse && !restore_error;
                // HPS overlap with an accepted commit is a protocol error.
                // Abort remaining old work and hold reset until a new image/seed.
                if(restore_phase!=IDLE || restore_pulse) restore_error<=1;
                restore_phase<=IDLE;commit_word<=0;restore_pulse<=0;
            end
            if(downloading_nvram && ioctl_wr) begin
                if(!seed_ready || ioctl_addr>=27'd384 || ioctl_addr!={18'd0,effective_count} ||
                    (!file_start && (!receive_ok || receive_profile!=profile)) ||
                    (file_start && (restore_phase!=IDLE || restore_pulse || restore_error))) begin
                    receive_ok<=0;restore_error<=1;
                end else begin
                    received_bytes<=effective_count+9'd1;
                    if(ioctl_addr<27'd128) begin
                        if(!ioctl_addr[0]) high_byte<=ioctl_dout;
                        else prefix_words[ioctl_addr[6:1]]<={high_byte,ioctl_dout};
                    end
                end
            end
            // Profile/seed changes matter even on a cycle with no WR.
            if(downloading_nvram && !file_start && (!seed_ready || receive_profile!=profile)) begin
                receive_ok<=0;restore_error<=1;
            end
            if(file_end) begin
                if(!receive_ok || receive_profile!=profile || !seed_ready || restore_error) begin
                    restore_error<=1;restore_phase<=IDLE;
                end else if(received_bytes>=9'd128 && received_bytes<=9'd384) begin
                    // A complete EEPROM prefix retains its legacy contract even
                    // when the optional score tail is rejected or interrupted.
                    // The score parser independently prevents rejected RAM writes.
                    restore_phase<=COMMIT;commit_word<=0;
                end
                else begin restore_error<=1;restore_phase<=IDLE;end
            end
            // A new transfer wins over the old EOF verdict and commit phase.
            if(!file_start && !file_end) begin
                if((restore_phase!=IDLE || restore_pulse) && (!seed_ready || receive_profile!=profile || restore_error)) begin
                    restore_error<=1;restore_phase<=IDLE;restore_pulse<=0;
                end else case(restore_phase)
                    COMMIT:if(!downloading_nvram && !restore_error) begin
                        if(restore_pulse) begin
                            if(eeprom_restore_en && eeprom_restore_ready) begin
                                // The actual EEPROM consumes this word on THIS edge.
                                restore_pulse<=0;
                                if(commit_word==6'd63) restore_phase<=IDLE;
                                else commit_word<=commit_word+6'd1;
                            end
                        end else if(!eeprom_busy) begin
                            restore_pulse<=1;eeprom_restore_addr<=commit_word;
                            eeprom_restore_data<=prefix_words[commit_word];
                        end
                    end
                endcase
            end
            if(downloading_finish && !last_finish) marker_seen<=0;
            if(downloading_finish && ioctl_wr) begin
                if(ioctl_addr!=0 || ioctl_dout!=8'ha5 || (last_finish && marker_seen)) restore_error<=1;
                else marker_seen<=1;
            end
            if(last_finish && !downloading_finish) begin
                if(marker_seen) final_seen<=1;else restore_error<=1;
            end
            // One save per donor request. The donor holds its request until the OSD closes
            // (it waits for the game to unpause), so a level-sensitive re-arm made Main
            // save again after every menu selection.
            if(donor_upload_req && !last_donor_req && ready) ioctl_upload_req<=1;
            if(ioctl_upload && ioctl_index==16'd4) ioctl_upload_req<=0;
        end
    end
endmodule
