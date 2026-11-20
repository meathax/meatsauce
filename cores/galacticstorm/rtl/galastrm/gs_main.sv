// SPDX-License-Identifier: GPL-3.0-or-later
// Real main CPU and device front ends. Audio and graphics execution are separate
// pending integrations; this is not yet a complete MiSTer game wrapper.
module gs_main #(
    parameter integer SYS_HZ=32_000_000,
    parameter integer WRAM_WRITE_BUFFER=1,
    parameter integer VIDEO_WRITE_BUFFER=1,
    parameter integer LINE_WRITES=0,
    // 0: legacy 128-word MLAB ROM cache. N>0: M10K line cache of 2**N lines.
    parameter integer ROM_LINE_IW=9,
    // 0: single-line WRAM read cache only. N>0: add a 2**N-line M10K WRAM store.
    parameter integer WRAM_LINE_IW=10
)(
    input logic clk, reset, pause,
    input wire bus_pause,
    input wire cpu_turbo,
    output wire bus_idle,
    input logic [7:0] in0, in2, stick_x, stick_y,
    input logic vblank,
    output logic mem_req,
    output wire [23:0] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0] mem_be,
    output wire mem_write,
    output wire mem_write_line,output wire [63:0] mem_wline,
    input logic mem_ack,
    input logic [15:0] mem_rdata,
    input wire [63:0] mem_rline,
    input logic nvram_ld_wr,
    input logic [5:0] nvram_ld_addr, nvram_sv_addr,
    input logic [15:0] nvram_ld_data,
    output wire [15:0] nvram_sv_data,
    output wire nvram_dirty,
    input logic pixel_ce,
    input logic [11:0] pixel_index,
    output wire [23:0] pixel_rgb,
    output wire [383:0] scp_controls,
    output wire [127:0] scn_controls,
    output wire [255:0] affine_controls,
    output wire debug_req,debug_ack,debug_write,debug_fetch,
    output wire [31:0] debug_addr,
    output wire [15:0] debug_wdata,
    output wire [1:0] debug_be,
    output wire [2:0] debug_fc,debug_irq_n,
    output wire frame_counter,watchdog_kick,
    output wire [3:0] coin_control
);
    wire req,write_bus,fetch_bus;
    wire [31:0] address;
    wire [15:0] wdata,rdata;
    wire [1:0] be;
    wire [2:0] fc,irq_n;
    logic ack;
    wire io_sel = address[23:3]==21'h080000 || address[23:3]==21'h0a0000;
    wire pcr_sel = address[23:2]==22'h240000;
    wire reg_sel = (address[23:0]>=24'h830000 && address[23:0]<=24'h83002f) ||
        address[23:4]==20'hd2000 || address[23:2]==22'h2c0000 || address[23:2]==22'h300000;
    wire storage_sel = address[23:0]<=24'h0fffff ||
        (address[23:0]>=24'h200000 && address[23:0]<=24'h21ffff) ||
        (address[23:0]>=24'h300000 && address[23:0]<=24'h303fff) ||
        (address[23:0]>=24'h600000 && address[23:0]<=24'h6007ff) ||
        (address[23:0]>=24'h800000 && address[23:0]<=24'h80ffff) ||
        (address[23:0]>=24'hd00000 && address[23:0]<=24'hd0ffff);
    wire iack=fc==3'b111;
    wire io_ack,pcr_ack,reg_ack,rom_ack,rom_mem_req;
    wire [15:0] io_data,pcr_data,reg_data,rom_data;
    wire [23:0] rom_mem_addr;
    wire rom_sel=address[23:0]<=24'h0fffff;
    wire live=req && !iack;
    wire cpu_idle,memory_idle;
    logic storage_req;
    wire [23:0] storage_addr;
    wire [15:0] storage_wdata,storage_rdata;
    wire [63:0] storage_rline;
    wire [31:0] next_address;
    wire [1:0] storage_be;
    wire storage_write,storage_ack;
    assign bus_idle=cpu_idle && memory_idle;
    // Request retirement first; keep posted writes clocked until drain is complete.
    // cpu_idle marks a whole native transfer, including all longword beats.
    // Manual/OSD pause must also retire the current whole transfer. Stopping
    // with a pending response prevents the video snapshot from reaching idle.
    wire cpu_pause=(pause || bus_pause) && cpu_idle;

    gs_cpu #(.SYS_HZ(SYS_HZ),.CPU_HZ(16_000_000),.CPU_TYPE(3),
        .RECOVER_STALLS(SYS_HZ==64_000_000),.MAX_RECOVERY_HZ(32_000_000)) cpu (
        .clk(clk),.reset(reset),.pause(cpu_pause),.turbo(cpu_turbo),.bus_idle(cpu_idle),.irq_n(irq_n),.autovector(1'b1),
        .bus_req(req),.bus_addr(address),.bus_wdata(wdata),.bus_be(be),
        .bus_write(write_bus),.bus_fetch(fetch_bus),.bus_fc(fc),
        .bus_ack(ack),.bus_rdata(rdata),.debug_addr(next_address),.debug_busstate(),.debug_advance()
    );
    gs_io #(.SYS_HZ(SYS_HZ)) io (
        .clk(clk),.reset(reset),.pause(pause),.cpu_req(live && io_sel),
        .cpu_write(write_bus),.cpu_addr(address[23:0]),.cpu_be(be),.cpu_wdata(wdata),
        .cpu_ack(io_ack),.cpu_rdata(io_data),.in0(in0),.in2(in2),.stick_x(stick_x),.stick_y(stick_y),
        .vblank(vblank),.iack5(req && ack && iack && address[3:1]==5),
        .irq_n(irq_n),.frame_counter(frame_counter),.watchdog_kick(watchdog_kick),.coin_control(coin_control),
        .nvram_ld_wr(nvram_ld_wr),.nvram_ld_addr(nvram_ld_addr),.nvram_ld_data(nvram_ld_data),
        .nvram_sv_addr(nvram_sv_addr),.nvram_sv_data(nvram_sv_data),.nvram_dirty(nvram_dirty)
    );
    gs_tc0110pcr pcr (
        .clk(clk),.reset(reset),.cpu_req(live && pcr_sel),.cpu_write(write_bus),
        .cpu_reg(address[1]),.cpu_be(be),.cpu_wdata(wdata),.cpu_ack(pcr_ack),.cpu_rdata(pcr_data),
        .pixel_ce(pixel_ce),.pixel_index(pixel_index),.pixel_rgb(pixel_rgb)
    );
    gs_video_regs regs (
        .clk(clk),.reset(reset),.cpu_req(live && reg_sel),.cpu_write(write_bus),
        .cpu_addr(address[23:0]),.cpu_be(be),.cpu_wdata(wdata),.cpu_ack(reg_ack),.cpu_rdata(reg_data),
        .scp_controls(scp_controls),.scn_controls(scn_controls),.affine_controls(affine_controls)
    );
    // Preserve original ROM timing while qualifying spatial WRAM reads.
    // Real native task/event timing must qualify this source before acceptance.
    generate if(ROM_LINE_IW>0) begin : rom_lines
        // Line fills use the aligned 64-bit SDRAM burst already fetched for
        // each read; the RAM is addressed one edge early by the CPU's next
        // bus address so hits keep the legacy one-edge registered reply.
        gs_main_rom_cache #(.IW(ROM_LINE_IW)) rom_cache (
            .clk(clk),.reset(reset),.cpu_req(live && rom_sel),.cpu_write(write_bus),
            .cpu_addr(address[23:0]),.look_valid(!req),.look_addr(next_address[23:0]),
            .cpu_ack(rom_ack),.cpu_rdata(rom_data),
            .mem_req(rom_mem_req),.mem_addr(rom_mem_addr),.mem_ack(storage_ack),.mem_rline(storage_rline)
        );
    end else begin : rom_words
        gs_rom_cache #(.FAST_MISS(0)) rom_cache (
            .clk(clk),.reset(reset),.cpu_req(live && rom_sel),.cpu_write(write_bus),
            .cpu_addr(address[23:0]),.cpu_ack(rom_ack),.cpu_rdata(rom_data),
            .mem_req(rom_mem_req),.mem_addr(rom_mem_addr),.mem_ack(storage_ack),.mem_rdata(storage_rdata)
        );
    end endgenerate
    always_comb begin
        storage_req=rom_mem_req || (live && storage_sel && !rom_sel);
        ack=0;
        if(req) begin
            if(iack) ack=1;
            else if(io_sel) ack=io_ack;
            else if(pcr_sel) ack=pcr_ack;
            else if(reg_sel) ack=reg_ack;
            else if(rom_sel) ack=rom_ack;
            else if(storage_sel) ack=storage_ack;
            else ack=1; // MAME's unmapped bus: writes ignored, reads all ones
        end
    end
    assign rdata=iack ? 16'hffff : io_sel ? io_data : pcr_sel ? pcr_data :
        reg_sel ? reg_data : rom_sel ? rom_data : storage_sel ? storage_rdata : 16'hffff;
    assign storage_addr=rom_mem_req ? rom_mem_addr : address[23:0];
    assign storage_wdata=wdata;
    assign storage_be=be;
    assign storage_write=rom_mem_req ? 1'b0 : write_bus;

`ifdef VERILATOR
    // Timing-proof monitor for the ROM-cache miss path.  An outstanding ROM
    // request must remain the selected CPU transaction until the cache's
    // registered response arrives; the shared WRAM ACK must never bypass it.
    logic rom_wait_d;
    logic [23:0] rom_wait_addr_d;
    always_ff @(posedge clk) begin
        if (reset) begin
            rom_wait_d <= 1'b0;
            rom_wait_addr_d <= '0;
        end else begin
            if (rom_mem_req) begin
                assert(req && rom_sel && !write_bus)
                    else $error("ROM cache pending without a held ROM read request");
                assert(ack == rom_ack)
                    else $error("WRAM/shared-memory ACK selected during a ROM cache miss");
            end
            if (rom_wait_d) begin
                assert(req && rom_sel && address == rom_wait_addr_d)
                    else $error("CPU ROM request/address changed before cache ACK");
            end
            rom_wait_d <= rom_mem_req && !rom_ack;
            rom_wait_addr_d <= address;
        end
    end
`endif

    generate if(WRAM_WRITE_BUFFER) begin : buffered_wram
        // Native qualification candidate: four-word private WRAM reads.
        // Ordinary main ROM latency is restored so this experiment is isolated.
        // Keep queue admission registered at the CPU boundary. A same-cycle
        // private-WRAM ACK creates a long address-decode -> CPU-advance path.
        gs_wram_write_buffer #(.VIDEO_WRITES(VIDEO_WRITE_BUFFER),.LINE_WRITES(LINE_WRITES),.LINE_READS(1),.FAST_WRITE_ACK(0),.ROM_LINES(ROM_LINE_IW>0),.WRAM_LINE_IW(WRAM_LINE_IW)) buffer (
            .clk(clk),.reset(reset),.up_req(storage_req),.up_write(storage_write),.look_addr(next_address[23:0]),
            .up_addr(storage_addr),.up_be(storage_be),.up_wdata(storage_wdata),
            .up_ack(storage_ack),.up_rdata(storage_rdata),.up_rline(storage_rline),
            .down_req(mem_req),.down_write(mem_write),.down_addr(mem_addr),
            .down_be(mem_be),.down_wdata(mem_wdata),.down_write_line(mem_write_line),.down_wline(mem_wline),.down_ack(mem_ack),.down_rdata(mem_rdata),.down_rline(mem_rline),
            .idle(memory_idle)
        );
    end else begin : direct_storage
        assign mem_req=storage_req;
        assign mem_addr=storage_addr;
        assign mem_be=storage_be;
        assign mem_wdata=storage_wdata;
        assign mem_write=storage_write;
        assign mem_write_line=0;assign mem_wline=0;
        assign storage_ack=mem_ack;
        assign storage_rdata=mem_rdata;
        assign storage_rline=mem_rline;
        assign memory_idle=1'b1;
    end endgenerate
    assign debug_req=req;
    assign debug_ack=ack;
    assign debug_addr=address;
    assign debug_wdata=wdata;
    assign debug_be=be;
    assign debug_write=write_bus;
    assign debug_fetch=fetch_bus;
    assign debug_fc=fc;
    assign debug_irq_n=irq_n;
endmodule
