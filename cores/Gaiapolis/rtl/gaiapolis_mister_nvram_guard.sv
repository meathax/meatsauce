// SPDX-License-Identifier: GPL-3.0-or-later
// Arcade MRA NVRAM index2: staged restores, safe serial boundary, real dump path.
module gaiapolis_mister_nvram_guard #(
    parameter integer FILE_BYTES=128,
    parameter integer LEGACY_BYTES=128
) (
    input  logic clk, cold_reset,
    input  logic raw_download, raw_upload, raw_wr, raw_rd,
    input  logic [15:0] raw_index,
    input  logic [26:0] raw_addr,
    input  logic [7:0] raw_dout, game_din,
    input  logic safe_wait, serial_commit, autosave, osd_open,
    output logic [7:0] host_din, game_dout,
    output logic [26:0] game_addr,
    output logic game_ram, game_wr, host_wait,
    output logic freeze_req, restore_pending, upload_req,
    output logic restore_complete, upload_complete, transfer_error
);
    typedef enum logic [3:0] {IDLE,COLLECT,WAIT_WRITE,COPY_WRITE,DRAIN_WRITE,
                              WAIT_READ,WARM_READ,READ_DATA,DRAIN_READ} state_t;
    state_t state;
    localparam integer ADDR_WIDTH=$clog2(FILE_BYTES);
    localparam integer COUNT_WIDTH=$clog2(FILE_BYTES+1);
    localparam [COUNT_WIDTH-1:0] FILE_LIMIT=COUNT_WIDTH'(FILE_BYTES);
    localparam [COUNT_WIDTH-1:0] LEGACY_LIMIT=COUNT_WIDTH'(LEGACY_BYTES);
    logic [COUNT_WIDTH-1:0] write_count, read_count, copy_limit;
    logic [ADDR_WIDTH-1:0] copy_addr;
    logic [3:0] delay_count;
    logic [1:0] copy_phase;
    logic bad_restore, dirty, request_sent;
    wire nv_index = raw_index==16'd2;
    wire load_session = nv_index && raw_download;
    wire save_session = nv_index && raw_upload;
    wire collect_write = state==COLLECT && load_session && raw_wr &&
                         raw_addr<27'(FILE_BYTES) &&
                         raw_addr=={{(27-COUNT_WIDTH){1'b0}},write_count};
    wire [7:0] staged_data;

    // Real pinned JTFRAME RAM, not a modeled EEPROM or a replacement dump mux.
    jtframe_dual_ram #(.DW(8),.AW(ADDR_WIDTH)) u_restore_stage(
        .clk0(clk),.data0(raw_dout),.addr0(raw_addr[ADDR_WIDTH-1:0]),.we0(collect_write),.q0(),
        .clk1(clk),.data1(8'd0),.addr1(copy_addr),.we1(1'b0),.q1(staged_data)
    );

    always_comb begin
        freeze_req = state!=IDLE && state!=COLLECT;
        restore_pending = state==WAIT_WRITE || state==COPY_WRITE || state==DRAIN_WRITE;
        game_ram = state==COPY_WRITE || state==DRAIN_WRITE ||
                   state==WARM_READ || state==READ_DATA || state==DRAIN_READ;
        game_addr = restore_pending ? {{(27-ADDR_WIDTH){1'b0}},copy_addr} : raw_addr;
        game_dout = restore_pending ? staged_data : raw_dout;
        game_wr = state==COPY_WRITE && copy_phase==2'd2;
        host_din = save_session ? (state==READ_DATA && raw_addr<27'(FILE_BYTES) ? game_din : 8'd0) : game_din;
        // Download data are staged. Upload data wait until the game grants a
        // stable pause and the synchronous dump/RAM path has settled.
        // WAIT_WRITE owns no bus, so it must not stall the HPS: Main only
        // releases the game reset (status[0]) after its next commands.
        host_wait = load_session ? state!=COLLECT :
                    save_session ? state!=READ_DATA : !(state==IDLE || state==WAIT_WRITE);
    end

    always_ff @(posedge clk) begin
        if (cold_reset) begin
            state<=IDLE;write_count<='0;read_count<='0;copy_addr<='0;copy_limit<=FILE_LIMIT;
            delay_count<=4'd0;copy_phase<=2'd0;bad_restore<=1'b0;
            dirty<=1'b0;request_sent<=1'b0;upload_req<=1'b0;
            restore_complete<=1'b0;upload_complete<=1'b0;transfer_error<=1'b0;
        end else begin
            upload_req<=1'b0;restore_complete<=1'b0;upload_complete<=1'b0;
            if (serial_commit) dirty<=1'b1;
            if (dirty && autosave && osd_open && state==IDLE && !request_sent &&
                !load_session && !save_session) begin
                upload_req<=1'b1;request_sent<=1'b1;
            end
            case (state)
                IDLE: begin
                    if (load_session) begin
                        state<=COLLECT;write_count<='0;bad_restore<=1'b0;copy_addr<='0;
                    end else if (save_session) begin
                        state<=WAIT_READ;read_count<='0;
                    end
                end
                COLLECT: begin
                    if (raw_wr && load_session) begin
                        if (collect_write && write_count<FILE_LIMIT) write_count<=write_count+COUNT_WIDTH'(1);
                        else bad_restore<=1'b1;
                    end
                    if (!load_session) begin
                        if ((write_count==FILE_LIMIT || write_count==LEGACY_LIMIT) && !bad_restore) begin
                            state<=WAIT_WRITE;copy_limit<=write_count;
                        end
                        else begin state<=IDLE;transfer_error<=1'b1;end
                    end
                end
                WAIT_WRITE: if (!safe_wait) begin
                    state<=COPY_WRITE;copy_phase<=2'd0;copy_addr<='0;
                end
                COPY_WRITE: begin
                    if (copy_phase==2'd2) begin
                        copy_phase<=2'd0;
                        if (COUNT_WIDTH'(copy_addr)+COUNT_WIDTH'(1)==copy_limit) begin state<=DRAIN_WRITE;delay_count<=4'd8;end
                        else copy_addr<=copy_addr+ADDR_WIDTH'(1);
                    end else copy_phase<=copy_phase+2'd1;
                end
                DRAIN_WRITE: begin
                    if (delay_count!=0) delay_count<=delay_count-4'd1;
                    else begin state<=IDLE;restore_complete<=1'b1;end
                end
                WAIT_READ: begin
                    if (!save_session) begin state<=IDLE;request_sent<=1'b0;end
                    else if (!safe_wait) begin state<=WARM_READ;delay_count<=4'd3;end
                end
                WARM_READ: begin
                    if (delay_count!=0) delay_count<=delay_count-4'd1;
                    else state<=READ_DATA;
                end
                READ_DATA: begin
                    if (raw_rd && raw_addr<27'(FILE_BYTES) && read_count<FILE_LIMIT)
                        read_count<=read_count+COUNT_WIDTH'(1);
                    if (!save_session) begin state<=DRAIN_READ;delay_count<=4'd8;end
                end
                DRAIN_READ: begin
                    if (delay_count!=0) delay_count<=delay_count-4'd1;
                    else begin
                        state<=IDLE;request_sent<=1'b0;
                        if (read_count>=FILE_LIMIT) begin
                            upload_complete<=1'b1;
                            if (!serial_commit) dirty<=1'b0;
                        end
                    end
                end
                default: begin state<=IDLE;transfer_error<=1'b1;end
            endcase
        end
    end
endmodule
