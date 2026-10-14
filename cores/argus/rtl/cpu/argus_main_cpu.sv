// MAME 0.289 argus.cpp maps and HOLD_LINE/RST-vector semantics.
// Work RAM is deliberately not cleared by reset; software initializes it.
module argus_main_cpu (
    input  logic        clk_sys,
    input  logic        reset,
    input  logic        ce_main,
    input  logic        pause_game,
    input  logic [1:0]  game_id,
    input  logic [7:0]  system_in,
    input  logic [7:0]  p1_in,
    input  logic [7:0]  p2_in,
    input  logic [7:0]  dip1,
    input  logic [7:0]  dip2,
    input  logic [8:0]  ref_scanline,
    input  logic        ref_line_tick,
    output wire         rom_req,
    output wire [23:0]  rom_addr,
    input  logic        rom_ready,
    input  logic [7:0]  rom_rdata,
    output wire         vreq,
    output wire         vwe,
    output wire [15:0]  vaddr,
    output wire [7:0]   vwdata,
    input  logic        vready,
    input  logic [7:0]  vrdata,
    output logic [7:0]  sound_cmd,
    output logic        sound_cmd_we,
    input  logic        ram_req,
    input  logic        ram_we,
    input  logic [15:0] ram_addr,
    input  logic [7:0]  ram_wdata,
    input  logic        ram_grant,
    output logic        ram_ack,
    output logic [7:0]  ram_rdata,
    output logic [15:0] pc,
    // Native observation: pc is an opcode-fetch address, not internal TV80 PC.
    output wire [2:0]   debug_bank,
    output wire         debug_irq_n,
    output wire         debug_irq_ack,
    output wire [7:0]   debug_irq_vector,
    output logic        debug_input_read,
    output logic [15:0] debug_input_addr,
    output logic [7:0]  debug_input_data,
    output wire         debug_bus_quiescent,
    output wire         debug_ram_busy,
    output wire         debug_cpu_ram_write,
    output wire [15:0]  debug_cpu_ram_addr,
    output wire [7:0]   debug_cpu_ram_wdata
);
`include "rtl/cpu/argus_main_rom_layout.svh"

    wire [15:0] cpu_addr;
    wire [7:0] cpu_dout;
    logic [7:0] cpu_di;
    wire m1_n, mreq_n, iorq_n, rd_n, wr_n, rfsh_n, halt_n;
    wire cpu_ce = ce_main && !pause_game;
    wire memory_cycle = !mreq_n && rfsh_n && (!rd_n || !wr_n);
    wire memory_read = memory_cycle && !rd_n;
    wire memory_write = memory_cycle && !wr_n;
    wire irq_ack_cycle = !m1_n && !iorq_n;
    logic bus_done, work_read_pending;
    logic [7:0] bus_data;
    logic [2:0] bank;
    logic irq_pending, irq_ack_seen;
    logic [7:0] irq_vector, ack_vector;
    wire wait_n = !memory_cycle || bus_done;
    assign debug_cpu_ram_write = cpu_work_write && !borrow_port;
    assign debug_cpu_ram_addr = cpu_addr;
    assign debug_cpu_ram_wdata = cpu_dout;
    assign debug_bank = bank;
    assign debug_irq_n = ~irq_pending;
    assign debug_irq_ack = irq_ack_cycle;
    assign debug_irq_vector = irq_ack_cycle ? cpu_di : irq_vector;
    assign debug_bus_quiescent = !reset && pause_game &&
        (!memory_cycle || bus_done) && !work_read_pending &&
        (!irq_ack_cycle || irq_ack_seen) && !sound_cmd_we;

    argus_main_z80 z80 (
        .clk_sys(clk_sys), .reset(reset), .ce(cpu_ce), .wait_n(wait_n),
        .int_n(~irq_pending), .di(cpu_di), .a(cpu_addr), .dout(cpu_dout),
        .m1_n(m1_n), .mreq_n(mreq_n), .iorq_n(iorq_n), .rd_n(rd_n),
        .wr_n(wr_n), .rfsh_n(rfsh_n), .halt_n(halt_n)
    );

    function automatic logic work_address(input logic [15:0] address);
        if (game_id == 2'd2)
            work_address = address >= 16'he000 &&
                           !(address >= 16'hf000 && address <= 16'hf67f);
        else if (game_id < 2'd2)
            work_address = address >= 16'he000 &&
                           !(address >= 16'hf200 && address <= 16'hf7ff);
        else work_address = 1'b0;
    endfunction

    // Exact mapped RAM ranges; write-only controls are not readable RAM.
    function automatic logic video_address(input logic [15:0] address,
                                            input logic writing);
        logic scroll_ram, control;
        begin
            scroll_ram = (address >= 16'hc308 && address <= 16'hc30b);
            control = address == 16'hc201 || address == 16'hc30c;
            if (game_id == 2'd0) begin
                scroll_ram = scroll_ram ||
                    (address >= 16'hc300 && address <= 16'hc303);
                video_address = scroll_ram || (writing && control) ||
                    (address >= 16'hc400 && address <= 16'hdfff) ||
                    (address >= 16'hf200 && address <= 16'hf7ff);
            end else if (game_id == 2'd1) begin
                control = control || address == 16'hc300 || address == 16'hc30d;
                video_address = scroll_ram || (writing && control) ||
                    (address >= 16'hc400 && address <= 16'hdfff) ||
                    (address >= 16'hf200 && address <= 16'hf7ff);
            end else if (game_id == 2'd2) begin
                scroll_ram = scroll_ram ||
                    (address >= 16'hc300 && address <= 16'hc303);
                control = control || address == 16'hc100 ||
                          address == 16'hc203 || address == 16'hc304;
                video_address = scroll_ram || (writing && control) ||
                    (address >= 16'hc400 && address <= 16'hdfff) ||
                    (address >= 16'hf000 && address <= 16'hf67f);
            end else video_address = 1'b0;
        end
    endfunction

    wire work_hit = work_address(cpu_addr);
    wire video_hit = video_address(cpu_addr, memory_write);
    wire rom_hit = cpu_addr < 16'hc000 && game_id != 2'd3;
    wire [23:0] rom_offset = cpu_addr[15] ?
        (24'h010000 + {7'd0, bank, cpu_addr[13:0]}) : {8'd0, cpu_addr};
    wire rom_present = rom_offset < main_rom_bytes(game_id);
    assign rom_addr = main_rom_base(game_id) + rom_offset;
    assign rom_req = !reset && memory_read && rom_hit && rom_present && !bus_done;
    assign vreq = !reset && memory_cycle && video_hit && !bus_done;
    assign vwe = memory_write;
    assign vaddr = cpu_addr;
    assign vwdata = cpu_dout;

    always_comb begin
        // Keep the accepted vector stable if the next raster IRQ arrives while
        // the previous IACK pins are still asserted.
        if (irq_ack_cycle) cpu_di = irq_ack_seen ? ack_vector : irq_vector;
        else if (!iorq_n) cpu_di = 8'hff;
        else cpu_di = bus_data;
    end

    logic [7:0] work_ram [0:8191];
    logic [7:0] work_q;
    logic borrow_pending, borrow_done;
    logic [15:0] borrow_addr;
    logic [7:0] borrow_data;
    logic borrow_we;
    wire cpu_work_unfinished = memory_cycle && work_hit && !bus_done;
    wire borrow_access = debug_bus_quiescent && ram_grant && ram_req &&
                         work_address(ram_addr);
    wire borrow_start = borrow_access && !borrow_done && !borrow_pending;
    // A borrowed write commits at acknowledgement, after rechecking authority
    // and held payload. Revocation/abort cannot produce a late ack or write.
    wire borrow_complete = borrow_pending && borrow_access &&
        ram_addr == borrow_addr && ram_we == borrow_we &&
        (!borrow_we || ram_wdata == borrow_data);
    wire borrow_port = borrow_start || borrow_complete;
    wire [12:0] work_index = borrow_port ?
        (borrow_pending ? borrow_addr[12:0] : ram_addr[12:0]) : cpu_addr[12:0];
    wire borrow_write = borrow_complete && borrow_we;
    assign debug_ram_busy = borrow_pending || ram_ack ||
        (pause_game && ram_grant && ram_req && work_address(ram_addr));
    wire cpu_work_write = !reset && cpu_work_unfinished && memory_write;
    wire work_we = borrow_write || cpu_work_write;
    wire [7:0] work_din = borrow_write ? borrow_data : cpu_dout;

    // One synchronous single-port BRAM. Pause/grant arbitrates the borrowed
    // port after an in-flight CPU work-RAM transaction has completed.
    always_ff @(posedge clk_sys) begin
        work_q <= work_ram[work_index];
        if (work_we) work_ram[work_index] <= work_din;
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            borrow_pending <= 1'b0;
            borrow_done <= 1'b0;
            ram_ack <= 1'b0;
            ram_rdata <= 8'h00;
            borrow_addr <= 16'h0000;
            borrow_data <= 8'h00;
            borrow_we <= 1'b0;
        end else begin
            ram_ack <= 1'b0;
            if (!ram_req) borrow_done <= 1'b0;
            if (borrow_start) begin
                borrow_pending <= 1'b1;
                borrow_addr <= ram_addr;
                borrow_data <= ram_wdata;
                borrow_we <= ram_we;
            end
            if (borrow_pending) begin
                borrow_pending <= 1'b0;
                borrow_done <= 1'b1;
                if (borrow_complete) begin
                    ram_rdata <= work_q;
                    ram_ack <= 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            bank <= 3'd0;
            bus_done <= 1'b0;
            bus_data <= 8'hff;
            work_read_pending <= 1'b0;
            sound_cmd <= 8'h00;
            sound_cmd_we <= 1'b0;
            pc <= 16'h0000;
            debug_input_read <= 1'b0;
            debug_input_addr <= 16'h0000;
            debug_input_data <= 8'hff;
        end else begin
            sound_cmd_we <= 1'b0;
            debug_input_read <= 1'b0;
            if (!memory_cycle) begin
                bus_done <= 1'b0;
                work_read_pending <= 1'b0;
            end else if (!bus_done) begin
                if (rom_hit && memory_read) begin
                    if (!rom_present) begin
                        // No request outside the allocated source region.
                        bus_data <= main_rom_fill(game_id);
                        bus_done <= 1'b1;
                    end else if (rom_ready) begin
                        bus_data <= rom_rdata;
                        bus_done <= 1'b1;
                    end
                end else if (video_hit) begin
                    if (vready) begin
                        bus_data <= vrdata;
                        bus_done <= 1'b1;
                    end
                end else if (work_hit) begin
                    if (memory_write) bus_done <= 1'b1;
                    else if (work_read_pending) begin
                        bus_data <= work_q;
                        bus_done <= 1'b1;
                        work_read_pending <= 1'b0;
                    end else work_read_pending <= 1'b1;
                end else begin
                    bus_data <= 8'hff;
                    bus_done <= 1'b1;
                    if (memory_read) begin
                        case (cpu_addr)
                            16'hc000: bus_data <= system_in;
                            16'hc001: bus_data <= p1_in;
                            16'hc002: bus_data <= p2_in;
                            16'hc003: bus_data <= dip1;
                            16'hc004: bus_data <= dip2;
                            default: ;
                        endcase
                        if (cpu_addr >= 16'hc000 && cpu_addr <= 16'hc004 &&
                            game_id != 2'd3) begin
                            debug_input_read <= 1'b1;
                            debug_input_addr <= cpu_addr;
                            case (cpu_addr)
                                16'hc000: debug_input_data <= system_in;
                                16'hc001: debug_input_data <= p1_in;
                                16'hc002: debug_input_data <= p2_in;
                                16'hc003: debug_input_data <= dip1;
                                16'hc004: debug_input_data <= dip2;
                                default: debug_input_data <= 8'hff;
                            endcase
                        end
                    end else if (memory_write) begin
                        if (cpu_addr == 16'hc202) bank <= cpu_dout[2:0];
                        if (cpu_addr == 16'hc200) begin
                            sound_cmd <= cpu_dout;
                            sound_cmd_we <= 1'b1;
                        end
                    end
                end
                // TV80 has no public PC port. Expose the last opcode-fetch
                // address; the simulation adapter may inspect internal PC.
                if (!m1_n && memory_read) pc <= cpu_addr;
            end
        end
    end

    always_ff @(posedge clk_sys) begin
        if (reset) begin
            irq_pending <= 1'b0;
            irq_vector <= 8'hcf;
            ack_vector <= 8'hcf;
            irq_ack_seen <= 1'b0;
        end else begin
            if (!irq_ack_cycle) irq_ack_seen <= 1'b0;
            else if (!irq_ack_seen) begin
                ack_vector <= irq_vector;
                irq_pending <= 1'b0;
                irq_ack_seen <= 1'b1;
            end
            if (ref_line_tick && !pause_game && game_id != 2'd3) begin
                if (ref_scanline == (game_id == 2'd2 ? 9'd8 : 9'd16)) begin
                    irq_pending <= 1'b1;
                    irq_vector <= 8'hcf;
                end
                if (ref_scanline == (game_id == 2'd2 ? 9'd248 : 9'd240)) begin
                    irq_pending <= 1'b1;
                    irq_vector <= 8'hd7;
                end
            end
        end
    end
endmodule
