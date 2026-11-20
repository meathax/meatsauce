// SPDX-License-Identifier: GPL-3.0-or-later
// Taito En sound-board CPU and address frontend for Galactic Storm.
// Chip request port must be connected to real ES5505/ES5510/MB87078 devices.
module gs_sound #(parameter integer SYS_HZ=32000000)(
    input logic clk, reset, pause,
    output logic mem_req, mem_write,
    output logic [23:0] mem_addr,
    output logic [15:0] mem_wdata,
    output logic [1:0] mem_be,
    input logic mem_ack,
    input logic [15:0] mem_rdata,
    output logic chip_req, chip_write,
    output logic [23:0] chip_addr,
    output logic [15:0] chip_wdata,
    output logic [1:0] chip_be,
    input logic chip_ack,
    input logic [15:0] chip_rdata,
    output logic dsp_halt,
    output logic running,
    output logic debug_req, debug_ack, debug_write, debug_fetch,
    output logic [31:0] debug_addr,
    output logic [15:0] debug_wdata,
    output logic [1:0] debug_be,
    output logic [2:0] debug_fc,
    output logic debug_irq
);
    logic cpu_req, cpu_write, cpu_fetch, cpu_ack;
    logic [31:0] cpu_addr;
    logic [15:0] cpu_wdata,cpu_rdata;
    logic [1:0] cpu_be;
    logic [2:0] cpu_fc;
    logic du_req,du_ack,du_irq;
    logic [7:0] du_data,du_vector,du_out;
    logic [1:0] boot_word;
    logic [15:0] boot_data;
    typedef enum logic [2:0] {COPY_READ,COPY_GAP,COPY_WRITE,COPY_NEXT,READY} boot_t;
    boot_t boot;
    assign running=boot==READY;
    generate if(SYS_HZ==64000000)begin: cycle_exact_sound
    gs_sound_cpu_fx #(.SYS_HZ(SYS_HZ),.CPU_HZ(15238090)) cpu(
        .clk(clk),.reset(reset || !running),.pause(pause),
        .irq_n(du_irq ? 3'b001 : 3'b111),
        .bus_req(cpu_req),.bus_addr(cpu_addr),.bus_wdata(cpu_wdata),
        .bus_be(cpu_be),.bus_write(cpu_write),.bus_fetch(cpu_fetch),.bus_fc(cpu_fc),
        .bus_ack(cpu_ack),.bus_rdata(cpu_rdata),
        .bus_external_wait(running && cpu_req && !iack &&
                           (rom_select || ram_select)),
        .paused(),.bus_idle(),.phi1(),.phi2(),.debt(),.earned(),.repaid(),.nominal(),.fault(),
        .raw_addr(),.raw_fc(),.raw_as_n(),.raw_uds_n(),.raw_lds_n(),.raw_rw_n());
    end else begin: legacy_sound_reference
    gs_cpu #(.CPU_TYPE(0),.SYS_HZ(SYS_HZ),.CPU_HZ(15238090)) cpu(.turbo(1'b0),
        .clk(clk),.reset(reset || !running),.pause(pause),
        .irq_n(du_irq ? 3'b001 : 3'b111),.autovector(1'b0),
        .bus_req(cpu_req),.bus_addr(cpu_addr),.bus_wdata(cpu_wdata),
        .bus_be(cpu_be),.bus_write(cpu_write),.bus_fetch(cpu_fetch),.bus_fc(cpu_fc),
        .bus_ack(cpu_ack),.bus_rdata(cpu_rdata),
        .debug_addr(),.debug_busstate(),.debug_advance()
    );
    end endgenerate
    wire iack=cpu_fc==3'b111;
    wire ram_select=cpu_addr[23:18]==0 || cpu_addr[23:16]==8'hff;
    wire rom_select=cpu_addr[23:19]==5'b11000;
    wire dp_select=cpu_addr[23:12]==12'h140;
    wire du_select=cpu_addr[23:5]==19'h14000;
    wire chip_select=cpu_addr[23:5]==19'h10000 ||
        cpu_addr[23:9]==15'h1300 || cpu_addr[23:6]==18'hc000 ||
        cpu_addr[23:2]==22'hd0000;
    logic rom_mem_req,rom_ack;
    logic [15:0] rom_data;
    gs_sound_ram_cache #(.AW(18),.IW(11),.READ_ONLY(1)) program_cache(
        .clk(clk),.reset(reset),.cpu_req(running && cpu_req && rom_select && !iack),
        .cpu_write(cpu_write),.cpu_addr(cpu_addr[18:1]),.cpu_wdata(cpu_wdata),.cpu_be(cpu_be),
        .cpu_ack(rom_ack),.cpu_rdata(rom_data),.mem_req(rom_mem_req),
        .mem_ack(mem_ack && running && rom_select),.mem_rdata(mem_rdata)
    );
    logic ram_mem_req,ram_ack;
    logic [15:0] ram_data;
    gs_sound_ram_cache #(.AW(15),.IW(11)) work_ram_cache(
        .clk(clk),.reset(reset),.cpu_req(running && cpu_req && ram_select && !iack),
        .cpu_write(cpu_write),.cpu_addr(cpu_addr[15:1]),.cpu_wdata(cpu_wdata),.cpu_be(cpu_be),
        .cpu_ack(ram_ack),.cpu_rdata(ram_data),.mem_req(ram_mem_req),
        .mem_ack(mem_ack && running && ram_select),.mem_rdata(mem_rdata)
    );
    assign du_req=running && cpu_req && !iack && du_select && cpu_be[0];
    gs_duart #(.SYS_HZ(SYS_HZ)) duart(.clk(clk),.reset(reset),.pause(pause),
        .req(du_req),.write(cpu_write),.reg_a(cpu_addr[4:1]),
        .wdata(cpu_wdata[7:0]),.ack(du_ack),.rdata(du_data),
        .irq(du_irq),.vector(du_vector),.outport(du_out));
    assign dsp_halt=du_out[6];
    assign debug_req=cpu_req;
    assign debug_ack=cpu_ack;
    assign debug_addr=cpu_addr;
    assign debug_wdata=cpu_wdata;
    assign debug_be=cpu_be;
    assign debug_write=cpu_write;
    // In 68000 mode the kernel uses ordinary read state for program prefetch.
    assign debug_fetch=cpu_fetch || (!cpu_write && (cpu_fc==3'd6 || cpu_fc==3'd2));
    assign debug_fc=cpu_fc;
    assign debug_irq=du_irq;
    always_comb begin
        mem_req=0; mem_write=cpu_write; mem_addr=cpu_addr[23:0];
        mem_wdata=cpu_wdata; mem_be=cpu_be;
        chip_req=0; chip_write=cpu_write; chip_addr=cpu_addr[23:0];
        chip_wdata=cpu_wdata; chip_be=cpu_be;
        cpu_ack=0; cpu_rdata=16'hffff;
        if (!running) begin
            mem_req=boot==COPY_READ || boot==COPY_WRITE;
            mem_addr=boot==COPY_WRITE ? {21'd0,boot_word,1'b0} : {21'h180000,boot_word,1'b0};
            mem_write=boot==COPY_WRITE; mem_be=2'b11; mem_wdata=boot_data;
        end else if (cpu_req) begin
            if(iack) begin cpu_ack=1; cpu_rdata={8'hff,du_vector}; end
            else if(rom_select) begin
                mem_req=rom_mem_req;mem_addr=cpu_addr[23:0];mem_write=0;
                cpu_ack=rom_ack;cpu_rdata=rom_data;
            end else if(ram_select) begin
                mem_req=ram_mem_req; mem_addr={8'd0,cpu_addr[15:0]};
                cpu_ack=ram_ack; cpu_rdata=ram_data;
            end else if(dp_select) begin
                mem_req=1; cpu_ack=mem_ack; cpu_rdata=mem_rdata;
            end else if(du_select && cpu_be[0]) begin
                cpu_ack=du_ack; cpu_rdata={8'hff,du_data};
            end else if(chip_select) begin
                chip_req=1; cpu_ack=chip_ack; cpu_rdata=chip_rdata;
            end else cpu_ack=1;
        end
    end
    always_ff @(posedge clk) begin
        if(reset) begin boot<=COPY_READ; boot_word<=0; boot_data<=0; end
        else begin
            case(boot)
                COPY_READ: if(mem_ack) begin boot_data<=mem_rdata; boot<=COPY_GAP; end
                COPY_GAP: boot<=COPY_WRITE;
                COPY_WRITE: if(mem_ack) boot<=COPY_NEXT;
                COPY_NEXT: begin
                    if(boot_word==3) boot<=READY;
                    else begin boot_word<=boot_word+1'b1; boot<=COPY_READ; end
                end
                default: ;
            endcase
        end
    end
endmodule
