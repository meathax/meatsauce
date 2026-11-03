// S.P.Y. GX857 sound address decoding. All state uses the 48 MHz clock.
module spy_sound_bus(
    input logic clk, reset, irq_reset, pause,
    input logic [15:0] cpu_addr,
    input logic [7:0] cpu_dout,
    input logic mreq_n, iorq_n, m1_n, rd_n, wr_n,
    output logic [7:0] cpu_din,
    output logic wait_n,
    input logic [7:0] main_latch,
    input logic main_irq,
    output logic irq_n,
    output logic rom_req,
    output logic [14:0] rom_addr,
    input logic [7:0] rom_data,
    input logic rom_ok,
    input logic [7:0] ym_data,
    output logic ym_cs, ym_wr,
    output logic [1:0] pcm_cs,
    output logic pcm_wr,
    output logic [7:0] banks,
    output logic debug_wr, debug_rd,
    output logic [15:0] debug_addr,
    output logic [7:0] debug_data
);
    logic [7:0] ram[0:2047];
    logic write_seen, read_seen, main_irq_d, irq_pending;
    wire read_cycle = !mreq_n && !rd_n;
    wire write_cycle = !mreq_n && !wr_n;
    wire write_once = write_cycle && !write_seen && !pause && !reset;
    wire read_once = read_cycle && !read_seen && !pause && !reset;
    wire pcm0 = cpu_addr >= 16'ha000 && cpu_addr <= 16'ha00d;
    wire pcm1 = cpu_addr >= 16'hb000 && cpu_addr <= 16'hb00d;
    wire ym = cpu_addr >= 16'hc000 && cpu_addr <= 16'hc001;
    assign irq_n = !irq_pending;
    assign rom_req = read_cycle && !cpu_addr[15] && !reset;
    assign rom_addr = cpu_addr[14:0];
    assign wait_n = !rom_req || rom_ok;
    assign ym_cs = ym && write_once;
    assign ym_wr = ym_cs;
    // K007232 start registers 5/11 also respond to reads; reads return zero.
    assign pcm_cs = {pcm1,pcm0} & {2{write_once || read_once}};
    assign pcm_wr = write_once;
    assign debug_wr = write_once;
    assign debug_rd = read_once;
    assign debug_addr = cpu_addr;
    assign debug_data = cpu_dout;
    always_comb begin
        cpu_din = 8'hff;
        if (!mreq_n) begin
            if (!cpu_addr[15]) cpu_din = rom_data;
            else if (cpu_addr >= 16'h8000 && cpu_addr <= 16'h87ff)
                cpu_din = ram[cpu_addr[10:0]];
            else if (pcm0 || pcm1) cpu_din = 0;
            else if (ym) cpu_din = ym_data;
            else if (cpu_addr == 16'hd000) cpu_din = main_latch;
        end
        // Floating IM1 vector is FF (RST38); Z80 ignores it in IM1.
    end
    always_ff @(posedge clk) begin
        // The CPU startup hold must not discard a real main-CPU command IRQ.
        // Only the external game/watchdog reset clears the interrupt latch.
        if (irq_reset) begin
            main_irq_d <= 0;
            irq_pending <= 0;
        end else if (!pause) begin
            main_irq_d <= main_irq;
            if (!reset && !iorq_n && !m1_n) irq_pending <= 0;
            if (main_irq && !main_irq_d) irq_pending <= 1;
        end
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            banks <= 0;
            write_seen <= 0;
            read_seen <= 0;
        end else if (!pause) begin
            if (!write_cycle) write_seen <= 0;
            else if (write_once) write_seen <= 1;
            if (!read_cycle) read_seen <= 0;
            else if (read_once) read_seen <= 1;
            if (write_once) begin
                if (cpu_addr >= 16'h8000 && cpu_addr <= 16'h87ff)
                    ram[cpu_addr[10:0]] <= cpu_dout;
                if (cpu_addr == 16'h9000) banks <= cpu_dout;
            end
        end
    end
endmodule
