// Mysterious Stones board bus and timing. MAME 0.289 mystston.cpp is the
// behavioral reference; T65 remains the separately attributed CPU donor.
// One 48 MHz clock domain, 6 MHz pixels and 1.5 MHz CPU clock enables.
module stones_board (
    input wire clk, reset,
    input wire [7:0] in0, in1, dsw0, dsw1,
    input wire coin,
    input wire pause_req,
    output reg paused,
    input wire hs_access, hs_write,
    input wire [12:0] hs_addr,
    input wire [7:0] hs_din,
    output reg [7:0] hs_dout,
    input wire rom_wr,
    input wire [15:0] rom_addr,
    input wire [7:0] rom_data,
    input wire [9:0] fg_addr, bg_addr,
    output reg [7:0] fg_code, fg_attr, bg_code, bg_attr,
    input wire [4:0] sprite_addr,
    output reg [31:0] sprite_data,
    input wire [4:0] palette_addr,
    output reg [7:0] palette_data,
    output reg [7:0] video_control, scroll,
    output reg [7:0] ay_data,
    output reg [1:0] ay_wr, ay_address,
    output wire ce_pixel, ce_cpu,
    output reg [8:0] h, v,
    output wire hblank, vblank,
    output wire irq,
    output wire [15:0] cpu_addr,
    output wire [7:0] cpu_data,
    output wire cpu_read, cpu_sync
);
    reg [4:0] divider;
    assign ce_pixel = divider[2:0] == 3'd7;
    assign ce_cpu = divider == 5'd31;
    assign hblank = h >= 9'd256;
    assign vblank = v < 9'd8 || v >= 9'd248;
    reg irq_latch;
    assign irq = irq_latch;
    reg [7:0] ay_select;
    wire [23:0] address;
    assign cpu_addr = address[15:0];
    wire [7:0] cpu_di;
    T65 cpu (
        .Mode(2'b00), .BCD_en(1'b1), .Res_n(~reset), .Enable(ce_cpu && !paused),
        .Clk(clk), .Rdy(1'b1), .Abort_n(1'b1), .IRQ_n(~irq_latch),
        .NMI_n(~coin), .SO_n(1'b1), .DI(cpu_di), .DO(cpu_data),
        .R_W_n(cpu_read), .Sync(cpu_sync), .A(address),
        .EF(), .MF(), .XF(), .ML_n(), .VP_n(), .VDA(), .VPA(),
        .Regs(), .DEBUG_I(), .DEBUG_A(), .DEBUG_X(), .DEBUG_Y(),
        .DEBUG_S(), .DEBUG_P(), .NMI_ack()
    );

    // Independent synchronous CPU and video ports infer dual-port memories.
    reg [7:0] program_rom [0:49151] /* verilator public_flat_rw */;
    reg [7:0] ram [0:4095];
    reg [7:0] fg_low [0:1023], fg_high [0:1023];
    reg [7:0] bg_low [0:1023], bg_high [0:1023];
    reg [31:0] sprites [0:23];
    reg [7:0] palette [0:31];
    reg [7:0] q_rom, q_ram, q_fg_low, q_fg_high, q_bg_low, q_bg_high, q_palette;
    wire hs_granted = paused && hs_access;
    wire [15:0] memory_addr = hs_granted ? {3'd0,hs_addr} : cpu_addr;
    wire [7:0] memory_data = hs_granted ? hs_din : cpu_data;
    wire [9:0] bg_cpu_addr = {memory_addr[10],memory_addr[8:0]};
    wire write_cycle = ce_cpu && !cpu_read && !reset && !paused;
    wire memory_write = !reset && (hs_granted ? hs_write : write_cycle);

    always @(posedge clk) begin
        if (rom_wr && rom_addr >= 16'h4000)
            program_rom[rom_addr - 16'h4000] <= rom_data;
        if (cpu_addr >= 16'h4000) q_rom <= program_rom[cpu_addr - 16'h4000];
        q_ram <= ram[memory_addr[11:0]];
        q_fg_low <= fg_low[memory_addr[9:0]];
        q_fg_high <= fg_high[memory_addr[9:0]];
        q_bg_low <= bg_low[bg_cpu_addr];
        q_bg_high <= bg_high[bg_cpu_addr];
        q_palette <= palette[cpu_addr[4:0]];
        fg_code <= fg_low[fg_addr];
        fg_attr <= fg_high[fg_addr];
        bg_code <= bg_low[bg_addr];
        bg_attr <= bg_high[bg_addr];
        sprite_data <= sprite_addr < 24 ? sprites[sprite_addr] : 32'd0;
        palette_data <= palette[palette_addr];
        if (memory_write) begin
            if (memory_addr < 16'h1000) begin
                ram[memory_addr[11:0]] <= memory_data;
                if (memory_addr >= 16'h0780 && memory_addr < 16'h07e0)
                    sprites[memory_addr[6:2]][memory_addr[1:0]*8 +: 8] <= memory_data;
            end else if (memory_addr < 16'h1800) begin
                if (memory_addr[10]) fg_high[memory_addr[9:0]] <= memory_data;
                else fg_low[memory_addr[9:0]] <= memory_data;
            end else if (memory_addr < 16'h2000) begin
                if (memory_addr[9]) bg_high[bg_cpu_addr] <= memory_data;
                else bg_low[bg_cpu_addr] <= memory_data;
            end else if (memory_addr < 16'h4000 && memory_addr[6:5] == 2'b11)
                palette[cpu_addr[4:0]] <= cpu_data;
        end
    end

    reg [7:0] read_data;
    always @* begin
        if (hs_addr < 13'h1000) hs_dout = q_ram;
        else if (hs_addr < 13'h1800) hs_dout = hs_addr[10] ? q_fg_high : q_fg_low;
        else hs_dout = hs_addr[9] ? q_bg_high : q_bg_low;
    end
    always @(posedge clk) begin
        if (reset) paused <= 0;
        else if (ce_cpu) paused <= pause_req;
    end
    always @* begin
        if (cpu_addr >= 16'h4000) read_data = q_rom;
        else if (cpu_addr < 16'h1000) read_data = q_ram;
        else if (cpu_addr < 16'h1800) read_data = cpu_addr[10] ? q_fg_high : q_fg_low;
        else if (cpu_addr < 16'h2000) read_data = cpu_addr[9] ? q_bg_high : q_bg_low;
        else case (cpu_addr[6:4])
            3'd0: read_data = in0;
            3'd1: read_data = in1;
            3'd2: read_data = dsw0;
            3'd3: read_data = {~vblank, dsw1[6:0]};
            3'd6,3'd7: read_data = q_palette;
            default: read_data = 8'hff;
        endcase
    end
    // T65 requires its write data fed back into DI on write cycles.
    assign cpu_di = cpu_read ? read_data : cpu_data;

    always @(posedge clk) begin
        ay_wr <= 2'b00;
        if (reset) begin
            divider <= 0;
            h <= 0;
            v <= 248;
            irq_latch <= 0;
            video_control <= 0;
            scroll <= 0;
            ay_data <= 0;
            ay_select <= 0;
            ay_address <= 0;
        end else begin
            divider <= divider + 1'b1;
            if (ce_pixel) begin
                if (h == 383) begin
                    h <= 0;
                    v <= v == 271 ? 9'd0 : v + 1'b1;
                end else h <= h + 1'b1;
                // Assert at H256, on lines 7,23,...,247; retain until ack.
                if (h == 255 && v <= 247 && v[3:0] == 7) irq_latch <= 1;
            end
            if (write_cycle && cpu_addr >= 16'h2000 && cpu_addr < 16'h4000) begin
                case (cpu_addr[6:4])
                    3'd0: video_control <= cpu_data;
                    3'd1: irq_latch <= 0;
                    3'd2: scroll <= cpu_data;
                    3'd3: ay_data <= cpu_data;
                    3'd4: begin
                        ay_wr <= {ay_select[7] & ~cpu_data[7], ay_select[5] & ~cpu_data[5]};
                        ay_address <= {ay_select[6], ay_select[4]};
                        ay_select <= cpu_data;
                    end
                    default: begin end
                endcase
            end
        end
    end
endmodule
