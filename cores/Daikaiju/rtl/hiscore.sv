// Daikaiju hiscore.dat-compatible RAM image and MiSTer NVRAM transport.
// The byte order and ranges come from the installed MAME hiscore.dat entry.
`default_nettype none

module daikaiju_hiscore #(
    parameter logic [19:0] RETRY_CYCLES = 20'd960000
) (
    input  logic        clk_sys,
    input  logic        reset_game,
    input  logic        nvram_download,
    input  logic        ioctl_wr,
    input  logic [26:0] ioctl_addr,
    input  logic [15:0] ioctl_dout,
    input  logic        ioctl_upload,
    output logic [15:0] ioctl_din,
    output logic        ioctl_upload_req,
    output logic        pause_req,
    input  logic        pause_ack,
    output logic [15:0] mem_address,
    output logic        mem_write,
    output logic [7:0]  mem_write_data,
    input  logic [7:0]  mem_read_data,
    input  logic        cpu_write,
    input  logic [15:0] cpu_address,
    input  logic [7:0]  cpu_write_data,
    output logic        ready
);
    localparam logic [7:0] HISCORE_BYTES = 8'd175;
    localparam logic [8:0] NVRAM_FILE_BYTES = 9'd176;

    typedef enum logic [3:0] {
        HS_WAIT_RESET, HS_DELAY, HS_WAIT_PAUSE, HS_SCAN_READ,
        HS_SCAN_CAPTURE, HS_SCAN_DONE, HS_COPY_DEFAULT, HS_RESTORE, HS_READY
    } hiscore_state_t;

    hiscore_state_t state = HS_WAIT_RESET;
    logic [7:0] scan_index, copy_index, restore_index;
    logic [19:0] retry_timer;
    logic [15:0] scan_sum, restore_sum, current_sum, baseline_sum, stored_sum;
    logic markers_good, restore_from_nvram, score_valid;
    logic scan_locked = 1'b0;
    logic scan_write_seen = 1'b0;
    logic nvram_download_q;
    logic [8:0] nvram_bytes_received;
    logic nvram_pending;
    logic dirty = 1'b0;
    // NVRAM bytes are stored by index parity: each 16-bit ioctl write
    // supplies one even and one odd byte, so each MLAB bank takes one write.
    // The seven marker bytes are mirrored in registers for the final check.
    logic [7:0] nvram_marker [0:6];
    logic nvram_bank_write [0:1];
    logic [6:0] nvram_bank_address [0:1];
    logic [7:0] nvram_bank_data [0:1];
    wire [7:0] nvram_bank_read [0:1];
    wire [7:0] nvram_restore_data=nvram_bank_read[restore_index[0]];
    logic [7:0] score_index, score_old, restore_value;
    wire [7:0] score_cpu_data,score_restore_data,score_upload0,score_upload1;
    logic score_store_write;
    logic [7:0] score_store_address,score_store_data;
    wire [7:0] upload_next_index=ioctl_addr[7:0]+8'd1;
    a74_live_byte_cache #(.INIT_ZERO(1)) score_cpu_store(.clk(clk_sys),.write_enable(score_store_write),.write_address(score_store_address),.write_data(score_store_data),.read_address(score_index),.read_data(score_cpu_data));
    a74_live_byte_cache #(.INIT_ZERO(1)) score_restore_store(.clk(clk_sys),.write_enable(score_store_write),.write_address(score_store_address),.write_data(score_store_data),.read_address(restore_index),.read_data(score_restore_data));
    a74_live_byte_cache #(.INIT_ZERO(1)) score_upload0_store(.clk(clk_sys),.write_enable(score_store_write),.write_address(score_store_address),.write_data(score_store_data),.read_address(ioctl_addr[7:0]),.read_data(score_upload0));
    a74_live_byte_cache #(.INIT_ZERO(1)) score_upload1_store(.clk(clk_sys),.write_enable(score_store_write),.write_address(score_store_address),.write_data(score_store_data),.read_address(upload_next_index),.read_data(score_upload1));
    // Coherent scan snapshot: one write port, CPU-old-value and copy readers.
    logic scan_store_write;
    logic [7:0] scan_store_address,scan_store_data;
    wire [7:0] scan_cpu_data,scan_copy_data;
    a74_live_byte_cache #(.INIT_ZERO(1)) scan_cpu_store(.clk(clk_sys),.write_enable(scan_store_write),.write_address(scan_store_address),.write_data(scan_store_data),.read_address(score_index),.read_data(scan_cpu_data));
    a74_live_byte_cache #(.INIT_ZERO(1)) scan_copy_store(.clk(clk_sys),.write_enable(scan_store_write),.write_address(scan_store_address),.write_data(scan_store_data),.read_address(copy_index),.read_data(scan_copy_data));
    genvar bank;
    generate for(bank=0;bank<2;bank=bank+1)begin:nvram_banks
        a74_live_byte_cache #(.AW(7),.INIT_ZERO(1)) store(.clk(clk_sys),.write_enable(nvram_bank_write[bank]),.write_address(nvram_bank_address[bank]),.write_data(nvram_bank_data[bank]),.read_address(restore_index[7:1]),.read_data(nvram_bank_read[bank]));
    end endgenerate
    integer init_index;

    function automatic logic [2:0] marker_slot(input logic [7:0] offset);
        case(offset)
            8'd0:marker_slot=3'd0; 8'd159:marker_slot=3'd1; 8'd160:marker_slot=3'd2;
            8'd162:marker_slot=3'd3; 8'd163:marker_slot=3'd4; 8'd164:marker_slot=3'd5;
            8'd174:marker_slot=3'd6; default:marker_slot=3'd7;
        endcase
    endfunction

    function automatic logic [15:0] score_address(input logic [7:0] offset);
        begin
            if (offset < 8'd160)
                score_address = 16'hbf00 + {8'd0, offset};
            else if (offset < 8'd163)
                score_address = 16'ha007 + {8'd0, (offset - 8'd160)};
            else if (offset == 8'd163)
                score_address = 16'ha027;
            else if (offset < HISCORE_BYTES)
                score_address = 16'hd798 + {8'd0, (offset - 8'd164)};
            else
                score_address = 16'hffff;
        end
    endfunction

    function automatic logic [7:0] score_offset(input logic [15:0] address);
        begin
            if ((address >= 16'hbf00) && (address <= 16'hbf9f))
                score_offset = address[7:0];
            else if ((address >= 16'ha007) && (address <= 16'ha009))
                score_offset = 8'd160 + (address[7:0] - 8'h07);
            else if (address == 16'ha027)
                score_offset = 8'd163;
            else if ((address >= 16'hd798) && (address <= 16'hd7a2))
                score_offset = 8'd164 + (address[7:0] - 8'h98);
            else
                score_offset = 8'hff;
        end
    endfunction

    function automatic logic nvram_markers_valid;
        begin
            nvram_markers_valid =
                (nvram_marker[0] == 8'h00) && (nvram_marker[1] == 8'h33) &&
                (nvram_marker[2] == 8'h00) && (nvram_marker[3] == 8'h05) &&
                (nvram_marker[4] == 8'h23) && (nvram_marker[5] == 8'h30) &&
                (nvram_marker[6] == 8'h30);
        end
    endfunction

    logic [16:0] cpu_sum_next, restore_sum_next;
    always_comb begin
        score_index = score_offset(cpu_address);
        score_old = (score_index < HISCORE_BYTES) ?
                    ((state == HS_COPY_DEFAULT) ? scan_cpu_data : score_cpu_data) : 8'h00;
        cpu_sum_next = {1'b0, current_sum} - {9'd0, score_old} + {9'd0, cpu_write_data};
        restore_value = restore_from_nvram ? nvram_restore_data : score_restore_data;
        restore_sum_next = {1'b0, restore_sum} + {9'd0, restore_value};

        pause_req = (state == HS_WAIT_PAUSE) ||
                    (scan_locked && ((state == HS_SCAN_READ) ||
                     (state == HS_SCAN_CAPTURE) || (state == HS_SCAN_DONE))) ||
                    ((state == HS_COPY_DEFAULT) && scan_locked) || (state == HS_RESTORE);
        if (state == HS_RESTORE)
            mem_address = score_address(restore_index);
        else
            mem_address = score_address(scan_index);
        mem_write = (state == HS_RESTORE) && !reset_game;
        mem_write_data = restore_value;
        ioctl_upload_req = dirty && ready;
        ioctl_din = {((ioctl_addr+27'd1)<27'd175)?score_upload1:8'd0,
                     (ioctl_addr<27'd175)?score_upload0:8'd0};
    end

    always_comb begin
        score_store_write=1'b0;score_store_address=0;score_store_data=0;
        if(!reset_game && state==HS_COPY_DEFAULT && !(cpu_write && score_index<HISCORE_BYTES))begin
            score_store_write=1'b1;score_store_address=copy_index;score_store_data=scan_copy_data;
        end
        if(!reset_game && state==HS_RESTORE)begin
            score_store_write=1'b1;score_store_address=restore_index;score_store_data=restore_value;
        end
        if((state==HS_READY || state==HS_COPY_DEFAULT) && cpu_write && score_index<HISCORE_BYTES && score_old!=cpu_write_data)begin
            score_store_write=1'b1;score_store_address=score_index;score_store_data=cpu_write_data;
        end
    end

    always_comb begin
        scan_store_write=1'b0;scan_store_address=scan_index;scan_store_data=mem_read_data;
        if(!reset_game && state==HS_SCAN_CAPTURE)scan_store_write=1'b1;
        if(state==HS_COPY_DEFAULT && cpu_write && score_index<HISCORE_BYTES)begin
            scan_store_write=1'b1;scan_store_address=score_index;scan_store_data=cpu_write_data;
        end
    end

    // Byte ioctl_addr goes to bank addr[0]; byte addr+1 to the other bank.
    wire [8:0] nvram_next_offset={1'b0,ioctl_addr[7:0]}+9'd1;
    wire nvram_low_write=nvram_download && ioctl_wr && (ioctl_addr < NVRAM_FILE_BYTES) && (ioctl_addr < HISCORE_BYTES);
    wire nvram_high_write=nvram_download && ioctl_wr && (ioctl_addr < NVRAM_FILE_BYTES) && ((ioctl_addr + 27'd1) < HISCORE_BYTES);
    always_comb begin
        if(ioctl_addr[0])begin
            nvram_bank_write[0]=nvram_high_write;nvram_bank_address[0]=nvram_next_offset[7:1];nvram_bank_data[0]=ioctl_dout[15:8];
            nvram_bank_write[1]=nvram_low_write;nvram_bank_address[1]=ioctl_addr[7:1];nvram_bank_data[1]=ioctl_dout[7:0];
        end else begin
            nvram_bank_write[0]=nvram_low_write;nvram_bank_address[0]=ioctl_addr[7:1];nvram_bank_data[0]=ioctl_dout[7:0];
            nvram_bank_write[1]=nvram_high_write;nvram_bank_address[1]=nvram_next_offset[7:1];nvram_bank_data[1]=ioctl_dout[15:8];
        end
    end

    initial begin
        state = HS_WAIT_RESET;
        ready = 1'b0;
        score_valid = 1'b0;
        nvram_download_q = 1'b0;
        nvram_bytes_received = 9'd0;
        nvram_pending = 1'b0;
        retry_timer = 20'd0;
        scan_index = 8'd0;
        copy_index = 8'd0;
        restore_index = 8'd0;
        scan_sum = 16'd0;
        restore_sum = 16'd0;
        current_sum = 16'd0;
        baseline_sum = 16'd0;
        stored_sum = 16'd0;
        markers_good = 1'b0;
        restore_from_nvram = 1'b0;
        for (init_index = 0; init_index < 7; init_index = init_index + 1)
            nvram_marker[init_index] = 8'h00;
    end

    always @(posedge clk_sys) begin
        nvram_download_q <= nvram_download;
        if (!nvram_download_q && nvram_download) begin
            nvram_bytes_received <= 9'd0;
            nvram_pending <= 1'b0;
        end
        if (nvram_download && ioctl_wr && (ioctl_addr < NVRAM_FILE_BYTES)) begin
            if (marker_slot(ioctl_addr[7:0]) != 3'd7)
                nvram_marker[marker_slot(ioctl_addr[7:0])] <= ioctl_dout[7:0];
            if (((ioctl_addr + 27'd1) < HISCORE_BYTES) && (marker_slot(ioctl_addr[7:0] + 8'd1) != 3'd7))
                nvram_marker[marker_slot(ioctl_addr[7:0] + 8'd1)] <= ioctl_dout[15:8];
            nvram_bytes_received <= ioctl_addr[8:0] + 9'd2;
        end
        if (nvram_download_q && !nvram_download) begin
            if ((nvram_bytes_received >= HISCORE_BYTES) && nvram_markers_valid())
                nvram_pending <= 1'b1;
            else
                nvram_pending <= 1'b0;
        end

        if (reset_game) begin
            scan_locked <= 1'b0;
            scan_write_seen <= 1'b0;
            state <= HS_WAIT_RESET;
            ready <= 1'b0;
            retry_timer <= 20'd0;
        end else begin
            case (state)
                HS_WAIT_RESET: begin
                    retry_timer <= RETRY_CYCLES;
                    state <= HS_DELAY;
                end
                HS_DELAY: begin
                    // Readiness polling uses the independent RAM port and
                    // must not steal CPU/audio cycles every 20 ms. A positive
                    // observation is rechecked under BUSACK before any copy.
                    if (retry_timer == 20'd0) begin
                        scan_locked <= 1'b0;
                        scan_write_seen <= 1'b0;
                        scan_index <= 8'd0;
                        scan_sum <= 16'd0;
                        markers_good <= 1'b1;
                        state <= HS_SCAN_READ;
                    end
                    else
                        retry_timer <= retry_timer - 20'd1;
                end
                HS_WAIT_PAUSE: begin
                    if (pause_ack) begin
                        scan_locked <= 1'b1;
                        scan_write_seen <= 1'b0;
                        scan_index <= 8'd0;
                        scan_sum <= 16'd0;
                        markers_good <= 1'b1;
                        state <= HS_SCAN_READ;
                    end
                end
                HS_SCAN_READ: state <= HS_SCAN_CAPTURE;
                HS_SCAN_CAPTURE: begin
                    scan_sum <= scan_sum + {8'd0, mem_read_data};
                    case (scan_index)
                        8'd0:   if (mem_read_data != 8'h00) markers_good <= 1'b0;
                        8'd159: if (mem_read_data != 8'h33) markers_good <= 1'b0;
                        8'd160: if (mem_read_data != 8'h00) markers_good <= 1'b0;
                        8'd162: if (mem_read_data != 8'h05) markers_good <= 1'b0;
                        8'd163: if (mem_read_data != 8'h23) markers_good <= 1'b0;
                        8'd164: if (mem_read_data != 8'h30) markers_good <= 1'b0;
                        8'd174: if (mem_read_data != 8'h30) markers_good <= 1'b0;
                        default: ;
                    endcase
                    if (scan_index == 8'd174)
                        state <= HS_SCAN_DONE;
                    else begin
                        scan_index <= scan_index + 8'd1;
                        state <= HS_SCAN_READ;
                    end
                end
                HS_SCAN_DONE: begin
                    if (!markers_good || scan_write_seen ||
                        (cpu_write && score_index < HISCORE_BYTES)) begin
                        scan_locked <= 1'b0;
                        retry_timer <= RETRY_CYCLES;
                        state <= HS_DELAY;
                    end else if (!scan_locked && (nvram_pending || score_valid)) begin
                        state <= HS_WAIT_PAUSE;
                    end else if (nvram_pending || score_valid) begin
                        restore_from_nvram <= nvram_pending;
                        restore_index <= 8'd0;
                        restore_sum <= 16'd0;
                        if (!score_valid)
                            baseline_sum <= scan_sum;
                        state <= HS_RESTORE;
                    end else begin
                        copy_index <= 8'd0;
                        baseline_sum <= scan_sum;
                        current_sum <= scan_sum;
                        stored_sum <= scan_sum;
                        dirty <= 1'b0;
                        state <= HS_COPY_DEFAULT;
                    end
                end
                HS_COPY_DEFAULT: begin
                    // A quiet scan is a coherent snapshot. Copy it without
                    // stopping game clocks; prioritize snooped CPU updates.
                    if (!(cpu_write && score_index < HISCORE_BYTES)) begin
                        if (copy_index == 8'd174) begin
                            score_valid <= 1'b1;
                            ready <= 1'b1;
                            state <= HS_READY;
                        end else
                            copy_index <= copy_index + 8'd1;
                    end
                end
                HS_RESTORE: begin
                    restore_sum <= restore_sum_next[15:0];
                    if (restore_index == 8'd174) begin
                        current_sum <= restore_sum_next[15:0];
                        if (restore_from_nvram) begin
                            stored_sum <= restore_sum_next[15:0];
                            dirty <= 1'b0;
                            nvram_pending <= 1'b0;
                        end
                        score_valid <= 1'b1;
                        ready <= 1'b1;
                        state <= HS_READY;
                    end else
                        restore_index <= restore_index + 8'd1;
                end
                HS_READY: ready <= 1'b1;
                default: state <= HS_WAIT_RESET;
            endcase
        end

        if (ioctl_upload) begin
            stored_sum <= current_sum;
            dirty <= 1'b0;
        end
        if ((state == HS_SCAN_READ || state == HS_SCAN_CAPTURE || state == HS_SCAN_DONE) &&
            cpu_write && score_index < HISCORE_BYTES)
            scan_write_seen <= 1'b1;
        if (((state == HS_READY) || (state == HS_COPY_DEFAULT)) && cpu_write && (score_index < HISCORE_BYTES) &&
            (score_old != cpu_write_data)) begin
            current_sum <= cpu_sum_next[15:0];
            if (ioctl_upload) begin
                stored_sum <= cpu_sum_next[15:0];
                dirty <= 1'b0;
            end else if ((cpu_sum_next[15:0] != baseline_sum) &&
                         (cpu_sum_next[15:0] != stored_sum)) begin
                dirty <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
