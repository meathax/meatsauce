// Argus-family sound board bus; reference/mame289/src/mame/jaleco/argus.cpp.
module argus_sound_bus (
    input wire clk_sys, reset, pause_game,
    input wire [1:0] game_id,
    input wire [15:0] cpu_addr,
    input wire [7:0] cpu_dout,
    input wire mreq_n, iorq_n, m1_n, rfsh_n, rd_n, wr_n,
    output reg [7:0] cpu_din,
    output wire cpu_can_advance,
    input wire [7:0] sound_cmd,
    input wire sound_cmd_we,
    output wire rom_req,
    output wire [23:0] rom_addr,
    input wire rom_ready,
    input wire [7:0] rom_rdata,
    output wire [1:0] opn_select,
    output wire opn_addr, opn_we,
    output wire [7:0] opn_wdata,
    input wire [7:0] opn_rdata,
    output wire trace_latch_read, trace_io_read,
    output wire trace_ram_write
);
    wire mem_read = !mreq_n && rfsh_n && !rd_n;
    wire mem_write = !mreq_n && rfsh_n && !wr_n;
    wire io_read = !iorq_n && m1_n && !rd_n;
    wire io_write = !iorq_n && m1_n && !wr_n;
    wire butasan = game_id == 2;
    wire game_valid = game_id != 3;
    wire rom_sel = game_valid && mem_read &&
                   (butasan ? cpu_addr < 16'hc000 : !cpu_addr[15]);
    wire ram_sel = game_valid &&
                   (butasan ? cpu_addr[15:11] == 5'b11000 :
                               cpu_addr[15:11] == 5'b10000);
    wire latch_sel = game_valid &&
                     (cpu_addr == (butasan ? 16'he000 : 16'hc000));
    reg [7:0] latch_data;
    reg [7:0] ram [0:2047]; // Uninitialized board RAM; sound program initializes it.
    reg [7:0] ram_q, rom_q;
    reg rom_valid, write_seen, read_seen;
    wire write_active = io_write || mem_write;
    wire read_active = io_read || mem_read;
    wire write_once = write_active && !write_seen && !pause_game && !reset;
    wire read_once = read_active && !read_seen && !pause_game && !reset;
    wire [23:0] audio_base;

    argus_audio_rom_base u_rom_base (.game_id(game_id), .base(audio_base));
    assign rom_req = !reset && rom_sel && !rom_valid;
    assign rom_addr = audio_base + {8'd0, cpu_addr};
    // Hold CPU state until the response is latched. No repeated requests during a wait.
    assign cpu_can_advance = !reset && (!rom_sel || rom_valid);
    // Global mask ff, exact 00/01 and 80/81 decoding; M1 excludes IRQ acknowledge.
    assign opn_select[0] = game_valid && (io_read || io_write) && cpu_addr[7:1] == 0;
    assign opn_select[1] = (game_id == 1 || game_id == 2) &&
                          (io_read || io_write) && cpu_addr[7:1] == 7'h40;
    assign opn_addr = cpu_addr[0];
    assign opn_wdata = cpu_dout;
    assign opn_we = io_write && write_once && |opn_select;
    assign trace_latch_read = read_once && mem_read && latch_sel;
    assign trace_io_read = read_once && io_read;
    assign trace_ram_write = write_once && mem_write && ram_sel;

    always @(posedge clk_sys) begin
        ram_q <= ram[cpu_addr[10:0]];
        if (reset) begin
            latch_data <= 0;
            rom_q <= 8'hff;
            rom_valid <= 0;
            write_seen <= 0;
            read_seen <= 0;
        end else begin
            if (sound_cmd_we) latch_data <= sound_cmd;
            if (!rom_sel) rom_valid <= 0;
            else if (rom_req && rom_ready) begin
                rom_q <= rom_rdata;
                rom_valid <= 1;
            end
            if (!write_active) write_seen <= 0;
            else if (write_once) write_seen <= 1;
            if (!read_active) read_seen <= 0;
            else if (read_once) read_seen <= 1;
            if (trace_ram_write) ram[cpu_addr[10:0]] <= cpu_dout;
        end
    end

    always @* begin
        cpu_din = 8'hff;
        if (rom_sel) cpu_din = rom_q;
        else if (mem_read && ram_sel) cpu_din = ram_q;
        else if (mem_read && latch_sel) cpu_din = latch_data;
        else if (io_read && |opn_select) cpu_din = opn_rdata;
    end
endmodule
