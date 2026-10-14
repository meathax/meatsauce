// SPDX-License-Identifier: GPL-3.0-or-later
// Production-default CPU, control/timers, DMA/GPU/SPU and shared memory bus.
module cs_boot_probe (
    input logic clk, reset, ce,
    input logic [3:0] cart_banks, // MRA board record: populated flash chips (0 = legacy 3)
    input logic rtc_seed_valid, input logic [55:0] rtc_seed_bcd, // DS1302 time from MiSTer RTC (DS1302 register order)
    input logic pic_enable, pic_load_we, input logic [13:0] pic_load_address, input logic [15:0] pic_load_data, // protection PIC (MRA index 3)
    input logic video_flip, // OSD Orientation Flipped: native 180-degree scanout (all video outputs)
    input logic [31:0] p1_p2_n,p3_p4_n,
    input logic [7:0] system_n,dips_n,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_offset, req_data,
    output logic [3:0] req_target, req_strobe,
    output logic req_write,
    output logic [2:0] req_client,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error,
    output logic fault,
    output logic [31:0] fault_pc,
    output logic [15:0] fault_opcode,
    output logic retire,
    output logic [31:0] retire_pc,
    output logic [15:0] retire_opcode,
    output logic [7:0][31:0] registers,
    output logic [31:0] pc, sr, sp, er,
    output logic [2:0] flash_bank,
    output logic mmio_valid, mmio_ready, mmio_write,
    output logic [31:0] mmio_address, mmio_data,
    output logic [3:0] mmio_strobe,
    output logic mmio_rsp_valid, mmio_rsp_error,
    output logic [31:0] mmio_rsp_data,
    output logic cpu_irq_ack, cpu_event,
    output logic [7:0] cpu_event_code, irq_vector,
    output logic dma_fault,
    output logic [31:0] dma_fault_address,
    output logic gpu_fault,
    output logic [31:0] gpu_fault_address, gpu_packets, gpu_pixels,
    output logic audio_valid,
    output logic signed [15:0] audio_left, audio_right,
    output logic audio_underrun, audio_fault,
    output logic [6:0] audio_unsupported_modes,
    output logic audio_unsupported_reverb,
    output logic video_tick, video_de, video_hsync, video_vsync, video_hblank, video_vblank,
    output logic [11:0] video_x, video_y,
    output logic [7:0] video_r, video_g, video_b,
    output logic video_armed, video_underrun, video_fault, video_unsupported_geometry,
    output logic [31:0] video_fault_address, video_words,
    output logic cpu_trace_valid, cpu_trace_ready, cpu_trace_write,
    output logic [31:0] cpu_trace_address, cpu_trace_data,
    output logic [3:0] cpu_trace_strobe,
    output logic cpu_trace_rsp_valid, cpu_trace_rsp_error,
    output logic [31:0] cpu_trace_rsp_data,
    output logic cp_req_valid, cp_req_ready, cp_req_write,
    output logic [1:0] cp_req_id, output logic [2:0] cp_req_register,
    output logic [31:0] cp_req_data,
    output logic cp_rsp_valid, cp_rsp_ready, cp_rsp_error,
    output logic [31:0] cp_rsp_data,
    // GPU 32-byte line burst port (to cs_memory_fabric / cs_sdram_backend).
    output logic gpu_burst_valid, gpu_burst_write, gpu_burst_region,
    output logic gpu_burst_urgent, // the burst on the port is a display line fetch
    output logic [17:0] gpu_burst_line,
    output logic [7:0][31:0] gpu_burst_wdata,
    output logic [7:0][3:0] gpu_burst_wstrobe,
    input logic gpu_burst_ready, gpu_burst_done,
    input logic [7:0][31:0] gpu_burst_rdata,
    input logic gpu_snoop_valid,
    input logic [17:0] gpu_snoop_line,
    output logic cache_enabled, cache_invalidating,
    output logic [31:0] cache_hits, cache_misses, cache_invalidations, cache_writes
);
    logic cpu_valid, cpu_ready, cpu_write, cpu_rsp_valid, cpu_rsp_error;
    logic [31:0] cpu_address, cpu_data, cpu_rsp_data, cpu_offset;
    logic [3:0] cpu_strobe, cpu_target;
    logic control_valid, control_ready, control_rsp_valid, control_rsp_error;
    logic [31:0] control_rsp_data;
    logic control_mmio_pending,control_device_ready,control_device_write;
    logic [22:0] control_device_address;
    logic [31:0] control_device_data;
    logic [3:0] control_device_strobe;
    assign control_ready=!control_mmio_pending;
    logic dma_reg_valid, dma_reg_ready, dma_reg_rsp_valid, dma_reg_rsp_error;
    logic [31:0] dma_reg_rsp_data;
    logic irq;
    logic [1:0] dma_completion;
    logic [4:0] clients_valid, clients_ready, clients_write, clients_rsp_valid;
    logic [4:0][31:0] clients_address, clients_data;
    logic [4:0][3:0] clients_strobe;
    logic [31:0] clients_rsp_data;
    logic clients_rsp_error;
    logic gpio_reg_valid,gpio_reg_ready,gpio_reg_rsp_valid,gpio_reg_rsp_error;
    logic [31:0] gpio_reg_rsp_data;
    logic board_reg_valid,board_reg_ready,board_reg_rsp_valid,board_reg_rsp_error;
    logic [31:0] board_reg_rsp_data,board_interrupts;
    wire board_access = cpu_target==9 || cpu_target==10 || cpu_target==11;
    logic gpu_reg_valid,gpu_reg_ready,gpu_reg_rsp_valid,gpu_reg_rsp_error;
    logic [31:0] gpu_reg_rsp_data;
    logic crtc_reg_valid,crtc_reg_ready,crtc_reg_rsp_valid;
    logic [31:0] crtc_reg_rsp_data;
    logic spu_reg_valid,spu_reg_ready,spu_reg_rsp_valid,spu_irq,spu_irq_event;
    logic [31:0] spu_reg_read_data,spu_reg_rsp_data;
    logic spu_mmio_pending,spu_device_ready,spu_device_write;
    logic [11:0] spu_device_address;
    logic [31:0] spu_device_data;
    logic [3:0] spu_device_strobe;
    assign spu_reg_ready=!spu_mmio_pending;
    wire sound_access = cpu_address[31:12] == 20'h04800;
    logic vblank, crtc_irq;
    logic raster_restart,raster_tick,raster_de,raster_blank,raster_hsync,raster_vsync,raster_hblank,raster_vblank;
    logic [11:0] raster_x,raster_y,raster_width,raster_height;
    logic [22:0] gpu_display_address;
    wire video_access = cpu_address[31:16] == 16'h0300;
    wire soc_access = cpu_address[31:23] == 9'h003;
    wire dma_register = soc_access && cpu_address[22:5] == 18'h40;
    wire gpio_register = soc_access && (cpu_address[22:0]==23'h2004 || cpu_address[22:0]==23'h2008);
    wire crtc_register = soc_access && cpu_address[22:10] == 13'h00d;
    // These aligned MMIO apertures use address low bits directly. Selection
    // gates each peripheral; avoid routing unrelated map/offset arithmetic.
    cs_address_decode cpu_map (.address(cpu_address), .flash_bank, .target(cpu_target), .offset(cpu_offset));
    // Decode each requester before arbitration. The selected address previously
    // passed through a second full map decode after the priority/grant network.
    // Select predecoded metadata with the same locked one-hot payload grant;
    // request, response ownership and all bus cycles remain unchanged.
    logic a_valid, a_ready, a_write, a_rsp_valid, a_rsp_error;
    logic f_drain, front_wr, front_set, drain_ok, texq_empty;
    logic [15:0] front_wr_val, front_set_val;
    logic [31:0] f_offset;
    logic [31:0] a_address, a_data, a_rsp_data;
    logic [3:0] a_strobe;
    logic [2:0] a_client;
    logic [4:0] shared_grant;
    logic [4:0][3:0] mapped_target;
    logic [4:0][31:0] mapped_offset;
    genvar m;
    generate for (m=0;m<5;m=m+1) begin : requester_map
        cs_address_decode map (.address(clients_address[m]), .flash_bank,
            .target(mapped_target[m]), .offset(mapped_offset[m]));
    end endgenerate
    logic [3:0] a_target;
    logic [31:0] a_offset;
    always_comb begin
        a_target = 0; a_offset = 0;
        for (int m=0;m<5;m=m+1) begin
            a_target |= mapped_target[m] & {4{shared_grant[m]}};
            a_offset |= mapped_offset[m] & {32{shared_grant[m]}};
        end
    end
    logic flash_reg_valid, flash_reg_ready, flash_reg_rsp_valid;
    logic [31:0] flash_reg_rsp_data, flash_command, previous_flash_command;
    logic flash_read_override;
    wire flashcmd_access = cpu_address==32'h05000000 && (cpu_write || flash_read_override);
    cs_flash_cmd flash_commands (.clk, .reset, .cart_banks, .flash_bank,
        .reg_valid(flash_reg_valid), .reg_ready(flash_reg_ready), .reg_write(cpu_write), .reg_data(cpu_data),
        .reg_rsp_valid(flash_reg_rsp_valid), .reg_rsp_data(flash_reg_rsp_data),
        .read_override(flash_read_override), .command(flash_command));
    logic shared_snoop;
    logic [31:0] shared_snoop_address;
    logic [2:0] previous_flash_bank;
    always_ff @(posedge clk) begin
        if (reset) begin shared_snoop <= 0; shared_snoop_address <= 0; previous_flash_bank <= 0; previous_flash_command <= 32'hff; end
        else begin
            previous_flash_bank <= flash_bank; previous_flash_command <= flash_command;
            if (req_valid && req_ready) begin
                shared_snoop <= req_write && req_client != 0;
                shared_snoop_address <= req_address;
            end else if (rsp_valid) shared_snoop <= 0;
        end
    end
    // Work RAM is mirrored by address bit 23. Cache tags and completed
    // external-write snoops must use the same physical address for both views.
    wire [31:0] cpu_cache_address = cpu_trace_address[31:24]==8'h02 ?
        {cpu_trace_address[31:24],1'b0,cpu_trace_address[22:0]} : cpu_trace_address;
    wire [31:0] cache_snoop_address = shared_snoop_address[31:24]==8'h02 ?
        {shared_snoop_address[31:24],1'b0,shared_snoop_address[22:0]} : shared_snoop_address;
    logic cpu_cacheable;
    cs_cache_policy cache_policy (.address(cpu_trace_address), .write(cpu_trace_write),
        .flash_read_override, .cacheable(cpu_cacheable));
    vr0_cp0 #(.CACHE_WHILE_DISABLED(1'b1),.POSTED_WRITES(1'b1)) cp0 (.clk, .reset,
        .cp_req_valid, .cp_req_ready, .cp_req_write, .cp_req_id, .cp_req_register, .cp_req_data,
        .cp_rsp_valid, .cp_rsp_ready, .cp_rsp_data, .cp_rsp_error,
        .req_valid(cpu_trace_valid), .req_ready(cpu_trace_ready), .req_address(cpu_cache_address),
        .req_data(cpu_trace_data), .req_strobe(cpu_trace_strobe), .req_write(cpu_trace_write),
        // cs_cache_policy: only work RAM, BIOS reads and normal-mode cartridge reads
        // are cacheable; ROM writes bypass. Cabinet I/O must never allocate a line.
        .req_cacheable(cpu_cacheable),
        .rsp_valid(cpu_trace_rsp_valid), .rsp_data(cpu_trace_rsp_data), .rsp_error(cpu_trace_rsp_error),
        .mem_req_valid(cpu_valid), .mem_req_ready(cpu_ready), .mem_req_address(cpu_address),
        .mem_req_data(cpu_data), .mem_req_strobe(cpu_strobe), .mem_req_write(cpu_write),
        .mem_rsp_valid(cpu_rsp_valid), .mem_rsp_data(cpu_rsp_data), .mem_rsp_error(cpu_rsp_error),
        .snoop_valid(shared_snoop && rsp_valid && !rsp_error), .snoop_address(cache_snoop_address),
        .invalidate_all(flash_bank != previous_flash_bank || flash_command[7:0] != previous_flash_command[7:0]),
        .cache_enabled, .invalidation_busy(cache_invalidating),
        .hits(cache_hits), .misses(cache_misses), .invalidations(cache_invalidations), .forwarded_writes(cache_writes));
    se3208 #(.INVALID_OP_NOP(1'b1),.CE_CATCHUP(1'b1),.FETCH_PAIR(1'b1),.FAST_BUS(1'b1),.PREFETCH(1'b1)) cpu (.clk, .reset, .ce,
        .cp_req_valid, .cp_req_ready, .cp_req_write, .cp_req_id, .cp_req_register, .cp_req_data,
        .cp_rsp_valid, .cp_rsp_ready, .cp_rsp_data, .cp_rsp_error,
        .req_valid(cpu_trace_valid), .req_ready(cpu_trace_ready),
        .req_address(cpu_trace_address), .req_data(cpu_trace_data), .req_strobe(cpu_trace_strobe), .req_write(cpu_trace_write),
        .rsp_valid(cpu_trace_rsp_valid), .rsp_data(cpu_trace_rsp_data), .rsp_error(cpu_trace_rsp_error),
        .irq, .nmi(1'b0), .irq_vector, .irq_ack(cpu_irq_ack), .machine_event(cpu_event), .machine_code(cpu_event_code),
        .fault, .fault_pc, .fault_opcode, .retire, .retire_pc, .retire_opcode, .registers, .pc, .sr, .sp, .er,
        .state_load(1'b0), .state_registers('0), .state_pc(32'b0), .state_sr(32'b0), .state_sp(32'b0), .state_er(32'b0));
    always_comb begin
        flash_reg_valid = cpu_valid && flashcmd_access;
        control_valid = cpu_valid && soc_access && !dma_register && !gpio_register && !crtc_register;
        crtc_reg_valid = cpu_valid && crtc_register;
        gpio_reg_valid = cpu_valid && gpio_register;
        dma_reg_valid = cpu_valid && dma_register;
        board_reg_valid = cpu_valid && board_access;
        gpu_reg_valid = cpu_valid && video_access;
        spu_reg_valid = cpu_valid && sound_access;
        cpu_ready = flashcmd_access ? flash_reg_ready : sound_access ? spu_reg_ready : board_access ? board_reg_ready : video_access ? gpu_reg_ready : soc_access ? (dma_register ? dma_reg_ready : crtc_register ? crtc_reg_ready : gpio_register ? gpio_reg_ready : control_ready) : clients_ready[0];
        cpu_rsp_valid = flash_reg_rsp_valid || spu_reg_rsp_valid || crtc_reg_rsp_valid || gpio_reg_rsp_valid || board_reg_rsp_valid || control_rsp_valid || dma_reg_rsp_valid || gpu_reg_rsp_valid || clients_rsp_valid[0];
        cpu_rsp_data = flash_reg_rsp_valid ? flash_reg_rsp_data : spu_reg_rsp_valid ? spu_reg_rsp_data : crtc_reg_rsp_valid ? crtc_reg_rsp_data : gpio_reg_rsp_valid ? gpio_reg_rsp_data : board_reg_rsp_valid ? board_reg_rsp_data : gpu_reg_rsp_valid ? gpu_reg_rsp_data : control_rsp_valid ? control_rsp_data : dma_reg_rsp_valid ? dma_reg_rsp_data : clients_rsp_data;
        cpu_rsp_error = flash_reg_rsp_valid ? 1'b0 : spu_reg_rsp_valid ? 1'b0 : crtc_reg_rsp_valid ? 1'b0 : gpio_reg_rsp_valid ? gpio_reg_rsp_error : board_reg_rsp_valid ? board_reg_rsp_error : gpu_reg_rsp_valid ? gpu_reg_rsp_error : control_rsp_valid ? control_rsp_error : dma_reg_rsp_valid ? dma_reg_rsp_error : clients_rsp_error;
        clients_valid[0] = cpu_valid && !soc_access && !video_access && !board_access && !sound_access && !flashcmd_access;
        clients_address[0] = cpu_address; clients_data[0] = cpu_data;
        clients_strobe[0] = cpu_strobe; clients_write[0] = cpu_write;
        // MMIO observation follows device acceptance. The architectural CPU
        // request remains separately visible on cpu_trace_* before this bridge.
        mmio_valid = spu_mmio_pending || control_mmio_pending || (cpu_valid && !control_valid && (soc_access || video_access || board_access || flashcmd_access));
        mmio_ready = spu_mmio_pending ? spu_device_ready : control_mmio_pending ? control_device_ready : cpu_ready;
        mmio_address = cpu_address; mmio_data = cpu_data; mmio_strobe = cpu_strobe; mmio_write = cpu_write;
        if(spu_mmio_pending) begin
            mmio_address={20'h04800,spu_device_address};mmio_data=spu_device_data;
            mmio_strobe=spu_device_strobe;mmio_write=spu_device_write;
        end
        else if(control_mmio_pending) begin
            mmio_address={9'h003,control_device_address};mmio_data=control_device_data;
            mmio_strobe=control_device_strobe;mmio_write=control_device_write;
        end
        mmio_rsp_valid = flash_reg_rsp_valid || spu_reg_rsp_valid || crtc_reg_rsp_valid || gpio_reg_rsp_valid || board_reg_rsp_valid || control_rsp_valid || dma_reg_rsp_valid || gpu_reg_rsp_valid;
        mmio_rsp_data = flash_reg_rsp_valid ? flash_reg_rsp_data : spu_reg_rsp_valid ? spu_reg_rsp_data : crtc_reg_rsp_valid ? crtc_reg_rsp_data : gpio_reg_rsp_valid ? gpio_reg_rsp_data : board_reg_rsp_valid ? board_reg_rsp_data : gpu_reg_rsp_valid ? gpu_reg_rsp_data : control_rsp_valid ? control_rsp_data : dma_reg_rsp_data;
        mmio_rsp_error = flash_reg_rsp_valid ? 1'b0 : spu_reg_rsp_valid ? 1'b0 : crtc_reg_rsp_valid ? 1'b0 : gpio_reg_rsp_valid ? gpio_reg_rsp_error : board_reg_rsp_valid ? board_reg_rsp_error : gpu_reg_rsp_valid ? gpu_reg_rsp_error : control_rsp_valid ? control_rsp_error : dma_reg_rsp_error;
    end
    // A registered owned command keeps CP0 request-state fanout out of timer
    // reload arithmetic. MMIO tracing follows the actual child acceptance.
    always_ff @(posedge clk) begin
        if(reset) begin
            control_mmio_pending<=0;control_device_write<=0;control_device_address<=0;
            control_device_data<=0;control_device_strobe<=0;
        end else begin
            if(control_mmio_pending && control_device_ready) control_mmio_pending<=0;
            if(control_valid && control_ready) begin
                control_mmio_pending<=1;control_device_write<=cpu_write;
                control_device_address<=cpu_address[22:0];control_device_data<=cpu_data;
                control_device_strobe<=cpu_strobe;
            end
        end
    end
    vr0_control control (.clk, .reset, .req_valid(control_mmio_pending), .req_ready(control_device_ready),
        .req_address(control_device_address), .req_data(control_device_data), .req_strobe(control_device_strobe), .req_write(control_device_write),
        .rsp_valid(control_rsp_valid), .rsp_data(control_rsp_data), .rsp_error(control_rsp_error),
        .interrupt_events({23'b0,dma_completion,7'b0}|board_interrupts|{7'b0,crtc_irq,24'b0}|{29'b0,spu_irq_event,2'b0}), .irq, .irq_vector,
        .interrupt_enable(), .interrupt_status(), .timer_active(), .timer_control(), .timer_count(),
        .pll_control(), .pll_program());
    vr0_dma dma (.clk, .reset, .reg_valid(dma_reg_valid), .reg_ready(dma_reg_ready),
        .reg_address(cpu_address[4:0]), .reg_data(cpu_data), .reg_strobe(cpu_strobe), .reg_write(cpu_write),
        .reg_rsp_valid(dma_reg_rsp_valid), .reg_rsp_data(dma_reg_rsp_data), .reg_rsp_error(dma_reg_rsp_error),
        .req_valid(clients_valid[1]), .req_ready(clients_ready[1]), .req_address(clients_address[1]),
        .req_data(clients_data[1]), .req_strobe(clients_strobe[1]), .req_write(clients_write[1]),
        .rsp_valid(clients_rsp_valid[1]), .rsp_data(clients_rsp_data), .rsp_error(clients_rsp_error),
        .completion(dma_completion), .busy(), .fault(dma_fault), .fault_channel(),
        .fault_address(dma_fault_address), .remaining());
    vr0_crtc crtc (.clk,.reset,.reg_valid(crtc_reg_valid),.reg_ready(crtc_reg_ready),
        .reg_address(cpu_address[9:0]),.reg_data(cpu_data),.reg_strobe(cpu_strobe),.reg_write(cpu_write),
        .reg_response(crtc_reg_rsp_valid),.reg_result(crtc_reg_rsp_data),.external_pixel_tick(1'b0),
        .pixel_tick(raster_tick),.display_enable(raster_de),.screen_blank(raster_blank),.hsync(raster_hsync),.vsync(raster_vsync),.hblank(raster_hblank),.vblank(raster_vblank),
        .vblank_start(),.flip_tick(vblank),.irq_vblank(crtc_irq),.frame_start(),
        .pixel_x(raster_x),.pixel_y(raster_y),.frame_number(),.horizontal_total(),.vertical_total(),
        .horizontal_visible(raster_width),.vertical_visible(raster_height),.pixel_period(),.interlaced(),.unsupported_timing(),.timing_changed(raster_restart));
    vr0_gpio gpio (.clk,.initialize(reset),.reset,.reg_valid(gpio_reg_valid),.reg_ready(gpio_reg_ready),
        .reg_address(cpu_address[3:0]),.reg_data(cpu_data),.reg_strobe(cpu_strobe),.reg_write(cpu_write),
        .reg_rsp_valid(gpio_reg_rsp_valid),.reg_rsp_data(gpio_reg_rsp_data),.reg_rsp_error(gpio_reg_rsp_error),
        .seed_valid(rtc_seed_valid),.seed_bcd(rtc_seed_bcd),.restore_valid(1'b0),.state_address(6'd0),
        .restore_data(8'd0),.state_data(),.state_changed(),.latched_output(),
        .pic_enable,.pic_load_we,.pic_load_address,.pic_load_data);
    cs_board_io board_io (.clk,.reset,.p1_p2_n,.p3_p4_n,.system_n,.dips_n,
        .reg_valid(board_reg_valid),.reg_ready(board_reg_ready),.reg_address(cpu_address),
        .reg_data(cpu_data),.reg_strobe(cpu_strobe),.reg_write(cpu_write),
        .reg_rsp_valid(board_reg_rsp_valid),.reg_rsp_data(board_reg_rsp_data),.reg_rsp_error(board_reg_rsp_error),
        .flash_bank,.lamps(),.coin_counter_lines(),.coin_counts(),.interrupt_events(board_interrupts));
    // GPU and display share the backend line-burst port (cs_burst_mux below).
    logic gpu_b_valid, gpu_b_write, gpu_b_region, gpu_b_ready, gpu_b_done;
    logic [17:0] gpu_b_line;
    logic [7:0][31:0] gpu_b_wdata;
    logic [7:0][3:0] gpu_b_wstrobe;
    logic scan_b_valid, scan_b_ready, scan_b_done;
    logic [17:0] scan_b_line;
    vr0_gpu #(.SNOOP_COHERENT(1'b1),.ORDERED_FRONT(1'b1)) gpu (.clk, .reset, .reg_valid(gpu_reg_valid), .reg_ready(gpu_reg_ready),
        .reg_address(cpu_address[15:0]), .reg_data(cpu_data), .reg_strobe(cpu_strobe), .reg_write(cpu_write),
        .reg_rsp_valid(gpu_reg_rsp_valid), .reg_rsp_data(gpu_reg_rsp_data), .reg_rsp_error(gpu_reg_rsp_error), .vblank,
        .req_valid(clients_valid[2]), .req_ready(clients_ready[2]), .req_address(clients_address[2]),
        .req_data(clients_data[2]), .req_strobe(clients_strobe[2]), .req_write(clients_write[2]),
        .rsp_valid(clients_rsp_valid[2]), .rsp_data(clients_rsp_data), .rsp_error(clients_rsp_error),
        .queue_front(), .queue_rear(), .front_wr, .front_wr_val, .front_set, .front_set_val, .drain_ok, .flip_count(), .display_bank(), .flip_sync(), .busy(),
        .fault(gpu_fault), .fault_address(gpu_fault_address), .display_address(gpu_display_address), .draw_address(),
        .packets_completed(gpu_packets), .pixels_written(gpu_pixels),
        .burst_valid(gpu_b_valid), .burst_write(gpu_b_write), .burst_region(gpu_b_region),
        .burst_line(gpu_b_line), .burst_wdata(gpu_b_wdata), .burst_wstrobe(gpu_b_wstrobe),
        .burst_ready(gpu_b_ready), .burst_done(gpu_b_done), .burst_error(1'b0), .burst_rdata(gpu_burst_rdata),
        .snoop_valid(gpu_snoop_valid), .snoop_line(gpu_snoop_line));
    always_ff @(posedge clk) begin
        if(reset) begin
            spu_reg_rsp_valid<=0;spu_reg_rsp_data<=0;spu_mmio_pending<=0;
            spu_device_write<=0;spu_device_address<=0;spu_device_data<=0;spu_device_strobe<=0;
        end
        else begin
            // One registered command, one owned reply. Acknowledge the CPU
            // when captured; respond only after the SPU accepts the command.
            spu_reg_rsp_valid<=spu_mmio_pending && spu_device_ready;
            if(spu_mmio_pending && spu_device_ready) begin
                spu_reg_rsp_data<=spu_reg_read_data;spu_mmio_pending<=0;
            end
            if(spu_reg_valid && spu_reg_ready) begin
                spu_mmio_pending<=1;spu_device_write<=cpu_write;
                spu_device_address<=cpu_address[11:0];spu_device_data<=cpu_data;spu_device_strobe<=cpu_strobe;
            end
        end
    end
    vr0_spu spu (.clk,.reset,.reg_valid(spu_mmio_pending),.reg_write(spu_device_write),
        .reg_address(spu_device_address),.reg_data(spu_device_data),.reg_strobe(spu_device_strobe),
        .reg_ready(spu_device_ready),.reg_read_data(spu_reg_read_data),.irq(spu_irq),.irq_event(spu_irq_event),
        .sample_valid(audio_valid),.sample_left(audio_left),.sample_right(audio_right),
        .underrun(audio_underrun),.memory_fault(audio_fault),.unsupported_modes(audio_unsupported_modes),
        .unsupported_reverb(audio_unsupported_reverb),
        .req_valid(clients_valid[3]),.req_ready(clients_ready[3]),.req_address(clients_address[3]),
        .req_data(clients_data[3]),.req_strobe(clients_strobe[3]),.req_write(clients_write[3]),
        .rsp_valid(clients_rsp_valid[3]),.rsp_data(clients_rsp_data),.rsp_error(clients_rsp_error));
    // Display line bursts are served ahead of GPU bursts on the one backend burst port.
    cs_burst_mux burst_mux (.clk, .reset,
        .a_valid(scan_b_valid), .a_region(1'b1), .a_line(scan_b_line), .a_ready(scan_b_ready), .a_done(scan_b_done),
        .b_valid(gpu_b_valid), .b_write(gpu_b_write), .b_region(gpu_b_region), .b_line(gpu_b_line),
        .b_wdata(gpu_b_wdata), .b_wstrobe(gpu_b_wstrobe), .b_ready(gpu_b_ready), .b_done(gpu_b_done),
        .burst_valid(gpu_burst_valid), .burst_write(gpu_burst_write), .burst_region(gpu_burst_region),
        .burst_line(gpu_burst_line), .burst_wdata(gpu_burst_wdata), .burst_wstrobe(gpu_burst_wstrobe),
        .burst_ready(gpu_burst_ready), .burst_done(gpu_burst_done));
    assign gpu_burst_urgent = scan_b_valid;
    vr0_scanout #(.LINE_BURST(1)) scanout (.clk,.reset,.flip(video_flip),.restart(raster_restart),.pixel_tick(raster_tick),.display_enable(raster_de),.screen_blank(raster_blank),
        .hsync(raster_hsync),.vsync(raster_vsync),.hblank(raster_hblank),.vblank(raster_vblank),
        .pixel_x(raster_x),.pixel_y(raster_y),.visible_width(raster_width),.visible_height(raster_height),
        .display_address(gpu_display_address),.video_tick,.video_de,.video_hsync,.video_vsync,.video_hblank,.video_vblank,
        .video_x,.video_y,.video_r,.video_g,.video_b,.armed(video_armed),.underrun(video_underrun),
        .memory_fault(video_fault),.unsupported_geometry(video_unsupported_geometry),
        .fault_address(video_fault_address),.words_fetched(video_words),.line_valid(),
        .req_valid(clients_valid[4]),.req_ready(clients_ready[4]),.req_address(clients_address[4]),
        .req_data(clients_data[4]),.req_strobe(clients_strobe[4]),.req_write(clients_write[4]),
        .rsp_valid(clients_rsp_valid[4]),.rsp_data(clients_rsp_data),.rsp_error(clients_rsp_error),
        .burst_valid(scan_b_valid),.burst_line(scan_b_line),.burst_ready(scan_b_ready),.burst_done(scan_b_done),.burst_rdata(gpu_burst_rdata));
    // Scanout has bounded line-prefetch work with a fixed raster deadline.
    // Alternate display/sound service and reserve bounded background turns.
    cs_bus_arbiter #(.CLIENTS(5),.PRIORITY_CLIENT(4),.SECOND_PRIORITY_CLIENT(3),.PRIORITY_BURST(4),.REGISTER_GRANT(1),.PREEMPT_AGE(24)) arbiter (.clk, .reset, .client_valid(clients_valid), .client_ready(clients_ready), .req_grant(shared_grant),
        .client_address(clients_address), .client_data(clients_data), .client_strobe(clients_strobe),
        .client_write(clients_write), .client_rsp_valid(clients_rsp_valid), .client_rsp_data(clients_rsp_data),
        .client_rsp_error(clients_rsp_error), .req_valid(a_valid), .req_ready(a_ready), .req_address(a_address), .req_data(a_data),
        .req_strobe(a_strobe), .req_write(a_write), .rsp_valid(a_rsp_valid), .rsp_data(a_rsp_data), .rsp_error(a_rsp_error), .req_client(a_client));
    // Ordered texture write queue between the arbiter and the memory fabric (see cs_texq).
    cs_texq #(.AW(12)) texq (.clk, .reset,
        .b_valid(a_valid), .b_ready(a_ready), .b_target(a_target), .b_offset(a_offset), .b_data(a_data), .b_strobe(a_strobe),
        .b_write(a_write), .b_realtime(a_client == 3'd3), .rt_waiting(clients_valid[3]), .b_rsp_valid(a_rsp_valid), .b_rsp_data(a_rsp_data), .b_rsp_error(a_rsp_error),
        .f_valid(req_valid), .f_ready(req_ready), .f_target(req_target), .f_offset(f_offset), .f_data(req_data),
        .f_strobe(req_strobe), .f_write(req_write), .f_drain,
        .f_rsp_valid(rsp_valid), .f_rsp_data(rsp_data), .f_rsp_error(rsp_error),
        .front_wr, .front_wr_val, .front_set, .front_set_val, .drain_ok, .empty(texq_empty));
    assign req_offset = f_offset;
    assign req_address = f_drain ? (32'h03800000 | f_offset) : a_address;
    assign req_client = f_drain ? 3'd0 : a_client;
endmodule
