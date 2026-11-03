// SPDX-License-Identifier: GPL-3.0-or-later
// Dedicated graphics SDRAM; program/sample/work DDR transport. No sys edits.
module penguin_memory(
    input logic clk,clk_forward,clk_capture,cold_reset,warm_reset,
    output wire core_hold,phase_reset,
    input logic download,load_wr,input logic [26:0] load_addr,input logic [7:0] load_data,
    output wire load_wait,rom_ready,load_error,fast_loading,
    input logic [20:0] rom_addr,input logic rom_req,output wire [15:0] rom_dout,output wire rom_ack,
    input logic [20:0] sample_addr,input logic sample_req,output wire [7:0] sample_dout,output wire sample_ack,
    input logic [24:0] gfx_addr,input logic gfx_req,output wire [63:0] gfx_dout,output wire gfx_ack,
    input logic [17:0] ram_addr,input logic ram_req,ram_write,input logic [15:0] ram_data,input logic [1:0] ram_be,
    output logic [15:0] ram_dout,output logic ram_ack,
    input logic fb_we,input logic [28:0] fb_addr,input logic [63:0] fb_data,input logic [7:0] fb_be,
    output wire fb_busy,
    output wire DDRAM_CLK,input logic DDRAM_BUSY,output wire [7:0] DDRAM_BURSTCNT,
    output wire [28:0] DDRAM_ADDR,input logic [63:0] DDRAM_DOUT,input logic DDRAM_DOUT_READY,
    output wire DDRAM_RD,output wire [63:0] DDRAM_DIN,output wire [7:0] DDRAM_BE,output wire DDRAM_WE,
    inout wire [15:0] SDRAM_DQ,output wire [12:0] SDRAM_A,output wire [1:0] SDRAM_BA,
    output wire SDRAM_CLK,SDRAM_CKE,SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,SDRAM_nCAS,SDRAM_nRAS,
    output logic [15:0] max_gfx_cycles,output logic [31:0] graphics_requests
);
    wire ddr_load_wr,ddr_load_wait,ddr_load_idle,ddr_transaction_idle,sdram_ready;
    wire transport_idle,rom_init_busy,work_init_busy;
    wire replay_download,replay_wr,replay_wait,replay_ready,replay_error,loader_error;
    wire [26:0] replay_addr;wire [7:0] replay_data;
    wire [25:0] preload_addr;wire preload_req,preload_ack;wire [63:0] preload_data;
    assign rom_ready=replay_ready&&!replay_error;
    assign load_error=loader_error||replay_error;
    assign ddr_transaction_idle=transport_idle&&!rom_init_busy&&!work_init_busy;
    typedef enum logic [2:0] {RUN,DRAIN,RESET_PHASE,WAIT_SDRAM,HOLD_RESET} reset_state_t;
    reset_state_t reset_state=HOLD_RESET;
    logic [20:0] frozen_rom_addr=0,frozen_sample_addr=0;
    logic [24:0] frozen_gfx_addr=0;logic [17:0] frozen_ram_addr=0;
    logic frozen_rom_req=0,frozen_sample_req=0,frozen_gfx_req=0,frozen_ram_req=0,frozen_ram_write=0;
    logic [15:0] frozen_ram_data=0;logic [1:0] frozen_ram_be=0;
    // Same-edge copies of NEXT state's live level; never a delayed RUN flag.
    (* preserve, dont_merge *) logic [3:0] live_copies=4'b0000;
    always_ff @(posedge clk)begin
        if(cold_reset)live_copies<=4'b0000;
        else case(reset_state)
            RUN:if(warm_reset)live_copies<=4'b0000;else live_copies<=4'b1111;
            HOLD_RESET:if(!warm_reset&&sdram_ready&&!rom_init_busy&&!work_init_busy)
                live_copies<=4'b1111;else live_copies<=4'b0000;
            default:live_copies<=4'b0000;
        endcase
    end
    wire live=live_copies[0],drain=reset_state==DRAIN;
    wire [20:0] bus_rom_addr=live?rom_addr:frozen_rom_addr,bus_sample_addr=live_copies[1]?sample_addr:frozen_sample_addr;
    wire [24:0] bus_gfx_addr=live?gfx_addr:frozen_gfx_addr;
    wire [17:0] bus_ram_addr=live?ram_addr:frozen_ram_addr;
    wire bus_rom_req=live?rom_req:(drain?frozen_rom_req:1'b0),bus_sample_req=live_copies[1]?sample_req:(drain?frozen_sample_req:1'b0);
    wire bus_gfx_req=live?gfx_req:(drain?frozen_gfx_req:1'b0),bus_ram_req=live?ram_req:(drain?frozen_ram_req:1'b0);
    wire bus_ram_write=live?ram_write:frozen_ram_write;
    wire [15:0] bus_ram_data=live?ram_data:frozen_ram_data;
    wire [1:0] bus_ram_be=live?ram_be:frozen_ram_be;
    assign core_hold=!live_copies[2]||rom_init_busy||work_init_busy;
    assign phase_reset=reset_state==RESET_PHASE;
    wire load_allowed=(live_copies[3]&&!warm_reset)||(reset_state==HOLD_RESET);
    wire controllers_reset=cold_reset||phase_reset;
    // Capture before reset changes any client toggle or payload. Keep the old
    // epoch stable until its accepted physical transactions have completed.
    always_ff @(posedge clk)begin
        if(cold_reset)reset_state<=HOLD_RESET;
        else case(reset_state)
            RUN:if(warm_reset)begin
                frozen_rom_addr<=rom_addr;frozen_rom_req<=rom_req;
                frozen_sample_addr<=sample_addr;frozen_sample_req<=sample_req;
                frozen_gfx_addr<=gfx_addr;frozen_gfx_req<=gfx_req;
                frozen_ram_addr<=ram_addr;frozen_ram_req<=ram_req;frozen_ram_write<=ram_write;frozen_ram_data<=ram_data;frozen_ram_be<=ram_be;
                reset_state<=DRAIN;
            end
            DRAIN:if(frozen_rom_req==rom_ack&&frozen_sample_req==sample_ack&&frozen_gfx_req==gfx_ack&&frozen_ram_req==ram_ack&&
                !work_busy&&ddr_transaction_idle&&!read_outstanding&&!DDRAM_BUSY&&loader_gfx_req==loader_gfx_ack&&mem_req==mem_ack&&dma_req==dma_ack)reset_state<=RESET_PHASE;
            RESET_PHASE:reset_state<=WAIT_SDRAM;
            WAIT_SDRAM:if(sdram_ready)reset_state<=HOLD_RESET;
            HOLD_RESET:if(!warm_reset&&sdram_ready&&!rom_init_busy&&!work_init_busy)reset_state<=RUN;
            default:reset_state<=HOLD_RESET;
        endcase
    end
    wire [25:0] ddr_load_addr;wire [7:0] ddr_load_data;
    wire [24:0] loader_gfx_addr;wire [63:0] loader_gfx_data;wire loader_gfx_req,loader_gfx_ack;
    penguin_fast_rom fast_rom(.clk,.reset(cold_reset),.phase_reset,.hps_download(download),.hps_wr(load_wr),
        .hps_addr(load_addr),.hps_data(load_data),.hps_wait(load_wait),.busy(fast_loading),
        .download(replay_download),.wr(replay_wr),.addr(replay_addr),.data(replay_data),
        .core_wait(replay_wait),.image_ready(replay_ready),.load_error(loader_error),
        .port_ready(sdram_ready&&load_allowed&&!controllers_reset),.error(replay_error),
        .preload_addr,.preload_req,.preload_data,.preload_ack);
    penguin_rom_loader loader(.clk,.reset(cold_reset),.phase_reset,.download(replay_download),.wr(replay_wr),.addr(replay_addr),.data(replay_data),
        .wait_request(replay_wait),.ready(replay_ready),.error(loader_error),.ddr_wr(ddr_load_wr),.ddr_addr(ddr_load_addr),
        .ddr_data(ddr_load_data),.ddr_wait(ddr_load_wait),.ddr_idle(ddr_load_idle),
        .gfx_addr(loader_gfx_addr),.gfx_data(loader_gfx_data),.gfx_req(loader_gfx_req),.gfx_ack(loader_gfx_ack),.memory_ready(sdram_ready&&load_allowed));
    wire [24:0] mem_addr,dma_addr;wire [15:0] mem_din,mem_dout;
    wire [1:0] mem_be;wire mem_burst,mem_rnw,mem_req,mem_ack,dma_req,dma_ack;
    wire [63:0] mem_burst_data,dma_data;
    penguin_gfx_arbiter #(.CACHE_INDEX_BITS(11)) graphics_cache(.clk,.reset(controllers_reset),.cache_flush(download),
        .loader_addr(loader_gfx_addr),.loader_din(16'd0),.loader_be(2'b11),.loader_burst(1'b1),
        .loader_burst_data(loader_gfx_data),.loader_rnw(1'b0),.loader_req(loader_gfx_req),.loader_dout(),.loader_ack(loader_gfx_ack),
        .renderer_addr(bus_gfx_addr),.renderer_req(bus_gfx_req),.renderer_dout(gfx_dout),.renderer_ack(gfx_ack),
        .mem_addr,.mem_din,.mem_be,.mem_burst,.mem_burst_data,.mem_rnw,.mem_req,.mem_dout,.mem_ack,
        .dma_addr,.dma_req,.dma_data,.dma_ack);
    penguin_memory_sdram graphics_sdram(.clk,.clk_forward,.clk_capture,.reset(controllers_reset),
        .SDRAM_DQ,.SDRAM_A,.SDRAM_BA,.SDRAM_CLK,.SDRAM_CKE,.SDRAM_DQML,.SDRAM_DQMH,.SDRAM_nCS,.SDRAM_nWE,.SDRAM_nCAS,.SDRAM_nRAS,
        .mem_addr,.mem_din,.mem_be,.mem_burst,.mem_burst_data,.mem_rnw,.mem_req,.mem_dout,.mem_ack,
        .video_dma_req(dma_req),.video_dma_addr(dma_addr),.video_dma_ack(dma_ack),.video_dma_data(dma_data),.ready(sdram_ready));
    // The game RAM client keeps its request phase through the DDR work cache.
    logic work_busy=0,work_phase=0,work_req=0;
    logic [17:0] work_addr=0;logic [15:0] work_data=0;logic [1:0] work_be=0;logic work_write=0;
    wire work_ack;wire [15:0] work_dout;
    always_ff @(posedge clk)begin
        if(controllers_reset)begin work_busy<=0;work_req<=0;ram_ack<=0;ram_dout<=0;end
        else if(!work_busy)begin
            if(bus_ram_req!=ram_ack)begin
                work_phase<=bus_ram_req;work_addr<=bus_ram_addr;work_data<=bus_ram_data;work_be<=bus_ram_be;work_write<=bus_ram_write;
                work_req<=~work_req;work_busy<=1;
            end
        end else if(work_ack==work_req)begin
            ram_ack<=work_phase;ram_dout<=work_dout;
            work_busy<=0;
        end
    end
    wire memory_rd,memory_we,memory_busy,audio_guard;wire [28:0] memory_addr;wire [63:0] memory_data;wire [7:0] memory_be,memory_burst;
    logic read_outstanding=0;logic[4:0] fb_grants=16;wire prefer_fb=fb_grants!=0;
    wire clients_pending=(bus_rom_req!=rom_ack)||(bus_sample_req!=sample_ack)||(work_req!=work_ack)||ddr_load_wr||(preload_req!=preload_ack);
    // Memory commands take priority once issued; rotation is held during the
    // single outstanding DDR read. FB writes never consume the read return path.
    // A command already issued by the transport wins even if rotation raises
    // WE afterwards. Otherwise both producers could wait on each other while
    // a read stays asserted and is repeatedly accepted by the physical bridge.
    // Bound video service by sixteen pending framebuffer writes per CPU/work
    // physical command. Read latency makes equal command counts insufficient.
    // Audio admission remains strictly governed by audio_guard below.
    // Issued memory commands remain indivisible, including their read return.
    // Stop new rotation writes at reset entry. A previously accepted write is
    // retained by the physical bridge and DDRAM_BUSY participates in draining.
    wire fb_admission=live&&!warm_reset;
    assign memory_busy=DDRAM_BUSY || (fb_admission && !audio_guard && fb_we && (!clients_pending||prefer_fb) && !memory_rd && !memory_we && !read_outstanding);
    assign fb_busy=!fb_admission || audio_guard || DDRAM_BUSY || memory_rd || memory_we || read_outstanding || (clients_pending&&!prefer_fb);
    assign DDRAM_CLK=clk;
    assign DDRAM_RD=memory_rd;
    assign DDRAM_WE=memory_we || (fb_we && !fb_busy);
    assign DDRAM_ADDR=(memory_rd || memory_we)?memory_addr:fb_addr;
    assign DDRAM_DIN=memory_we?memory_data:fb_data;
    assign DDRAM_BE=memory_we?memory_be:fb_be;
    assign DDRAM_BURSTCNT=(memory_rd || memory_we)?memory_burst:8'd1;
    always_ff @(posedge clk)begin
        if(controllers_reset)begin read_outstanding<=0;fb_grants<=16;end
        else begin
            if((memory_rd||memory_we)&&!DDRAM_BUSY
               && !(memory_addr>=29'h06220000&&memory_addr<29'h06260000))fb_grants<=16;
            else if(fb_we&&!fb_busy&&fb_grants!=0)fb_grants<=fb_grants-1'b1;
            if(memory_rd && !DDRAM_BUSY)read_outstanding<=1;
            if(DDRAM_DOUT_READY)read_outstanding<=0;
        end
    end
    wire [20:0] cached_rom_addr;wire cached_rom_req,cached_rom_ack;wire [15:0] cached_rom_dout;
    penguin_rom_cache program_cache(.clk,.reset(controllers_reset),.invalidate(download||ddr_load_wr),
        .cpu_addr(bus_rom_addr),.cpu_req(bus_rom_req),.cpu_dout(rom_dout),.cpu_ack(rom_ack),
        .backend_addr(cached_rom_addr),.backend_req(cached_rom_req),.backend_dout(cached_rom_dout),.backend_ack(cached_rom_ack),
        .init_busy(rom_init_busy),.cache_hits(),.cache_misses(),.fill_words());
    // Cache follows the shared CPU/restore arbiter: every restore write uses
    // the same accepted-write path and byte-coherent resident-line update.
    wire [17:0] cached_work_addr;wire cached_work_req,cached_work_ack,cached_work_write;
    wire [15:0] cached_work_data,cached_work_dout;wire [1:0] cached_work_be;
    penguin_work_cache work_cache(.clk,.reset(controllers_reset),.invalidate(download||ddr_load_wr),
        .cpu_addr(work_addr),.cpu_req(work_req),.cpu_write(work_write),.cpu_data(work_data),.cpu_be(work_be),.cpu_dout(work_dout),.cpu_ack(work_ack),
        .backend_addr(cached_work_addr),.backend_req(cached_work_req),.backend_write(cached_work_write),.backend_data(cached_work_data),.backend_be(cached_work_be),.backend_dout(cached_work_dout),.backend_ack(cached_work_ack),
        .init_busy(work_init_busy),.read_hits(),.read_misses(),.write_hits(),.writes(),.fill_words());
    penguin_memory_ddr transport(.clk,.reset(controllers_reset),.load_wr(ddr_load_wr),.load_addr(ddr_load_addr),.load_data(ddr_load_data),
        .load_wait(ddr_load_wait),.load_idle(ddr_load_idle),.transaction_idle(transport_idle),.audio_guard,.preload_addr,.preload_req,.preload_data,.preload_ack,
        .cpu_addr(cached_rom_addr),.cpu_req(cached_rom_req),.cpu_dout(cached_rom_dout),.cpu_ack(cached_rom_ack),
        .sound_addr(bus_sample_addr),.sound_req(bus_sample_req),.sound_dout(sample_dout),.sound_ack(sample_ack),
        .ram_word_addr(cached_work_addr),.ram_req(cached_work_req),.ram_write(cached_work_write),.ram_data(cached_work_data),.ram_be(cached_work_be),.ram_dout(cached_work_dout),.ram_ack(cached_work_ack),
        .gfx_addr(25'd0),.gfx_req(1'b0),.gfx_dout(),.gfx_ack(),.ddr_clk(),.ddr_busy(memory_busy),.ddr_burstcount(memory_burst),
        .ddr_addr(memory_addr),.ddr_dout(DDRAM_DOUT),.ddr_dout_ready(DDRAM_DOUT_READY),.ddr_rd(memory_rd),
        .ddr_din(memory_data),.ddr_be(memory_be),.ddr_we(memory_we));
    logic [15:0] gfx_cycles=0;logic gfx_tracking=0;
    always_ff @(posedge clk)begin
        if(cold_reset)begin max_gfx_cycles<=0;graphics_requests<=0;gfx_cycles<=0;gfx_tracking<=0;end
        else if(gfx_req!=gfx_ack)begin
            gfx_cycles<=gfx_cycles+1'b1;
            if(!gfx_tracking)begin graphics_requests<=graphics_requests+1'b1;gfx_tracking<=1;end
        end else if(gfx_tracking)begin
            if(gfx_cycles>max_gfx_cycles)max_gfx_cycles<=gfx_cycles;
            gfx_cycles<=0;gfx_tracking<=0;
        end
    end
endmodule
