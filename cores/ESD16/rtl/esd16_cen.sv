// ESD16 clock enables, all derived from clk_sys = 98 MHz (clock_plan.json; PCB crystals 16 MHz and 14 MHz).
//   68000  : 16 MHz = 16/98 of clk_sys (phase accumulator mod 98, +16 per clk). phi2 follows phi1 by
//            exactly PHI2_DELAY clks, so both phase pairs are at least two clk_sys cycles apart.
//            While the bus waits for SDRAM program-ROM data the CE is frozen (cpu_wait) and the lost
//            phase (16 units per waited clk) is booked in `debt`. While debt > 0 the accumulator advances
//            20/98 (20 MHz peak, +25 %) and debt drains by the 4 extra units per clk, which preserves the
//            16 MHz average across stalls. Debt saturates at a multiple of 4 (over two seconds of stall).
//   Z80/YM3812 : 4 MHz = 2/49 (fractional, spacing 24/25 clk) ; OKI MSM6295 : 1 MHz = 1/98 (integer).
//   NMI 32*60 Hz = 1920 Hz (Bresenham).
// pause freezes every game enable (CPU, sound); the pixel raster is not touched here.
module esd16_cen (
    input      clk,
    input      rst,
    input      pause,
    input      cpu_wait,        // 68000 bus is waiting for program ROM data
    output reg cen_phi1,
    output reg cen_phi2,
    output reg cen_z80,
    output     cen_ym,
    output reg cen_oki,
    output reg nmi_tick,
    output     cpu_recovering   // debug/measurement: running at 20/98
);
    localparam integer CLK_HZ     = 98_000_000;
    localparam [6:0]   CPU_MOD    = 7'd98;      // phase units per clk_sys period group
    localparam [6:0]   CPU_INC    = 7'd16;      // 16 MHz
    localparam [6:0]   CPU_REC    = 7'd20;      // 20 MHz recovery
    localparam [31:0]  DEBT_MAX   = 32'hFFFFFFFC;
    localparam [1:0]   PHI2_DELAY = 2'd2;

    wire run = ~pause;

    // 4 MHz: 2/49
    reg [5:0] zacc;
    wire [6:0] zsum = {1'b0, zacc} + 7'd2;
    always @(posedge clk) begin
        cen_z80 <= 1'b0;
        if (rst) zacc <= 6'd0;
        else if (run) begin
            if (zsum >= 7'd49) begin zacc <= zsum[5:0] - 6'd49; cen_z80 <= 1'b1; end
            else zacc <= zsum[5:0];
        end
    end
    assign cen_ym = cen_z80;

    // 1 MHz: 1/98
    reg [6:0] odiv;
    always @(posedge clk) begin
        cen_oki <= 1'b0;
        if (rst) odiv <= 7'd0;
        else if (run) begin
            if (odiv == 7'd97) begin odiv <= 7'd0; cen_oki <= 1'b1; end
            else odiv <= odiv + 7'd1;
        end
    end

    reg  [6:0]  acc;
    reg  [31:0] debt;
    reg  [1:0]  phi2_cnt;       // 0 = no phi2 pending
    wire        recov = (debt != 32'd0);
    assign cpu_recovering = recov;
    wire [7:0]  sum = {1'b0, acc} + {1'b0, recov ? CPU_REC : CPU_INC};

    always @(posedge clk) begin
        cen_phi1 <= 1'b0;
        cen_phi2 <= 1'b0;
        if (rst) begin
            acc <= 7'd0; debt <= 32'd0; phi2_cnt <= 2'd0;
        end else begin
            if (phi2_cnt != 2'd0) begin
                phi2_cnt <= phi2_cnt - 2'd1;
                if (phi2_cnt == 2'd1) cen_phi2 <= 1'b1;
            end
            if (run) begin
                if (cpu_wait) begin
                    debt <= (debt > DEBT_MAX - 32'd16) ? DEBT_MAX : debt + 32'd16;
                end else if (sum >= {1'b0, CPU_MOD}) begin
                    // A phi1 needs the previous phi2 issued; the max rate (20/98) keeps phi1 >= 4 clks apart.
                    if (phi2_cnt == 2'd0) begin
                        acc       <= sum[6:0] - CPU_MOD;
                        cen_phi1  <= 1'b1;
                        phi2_cnt  <= PHI2_DELAY;
                        if (recov) debt <= (debt <= 32'd4) ? 32'd0 : debt - 32'd4;
                    end
                end else begin
                    acc <= sum[6:0];
                    if (recov) debt <= (debt <= 32'd4) ? 32'd0 : debt - 32'd4;
                end
            end
        end
    end

    // 1920 Hz tick
    reg [26:0] nacc;
    wire [26:0] nsum = nacc + 27'd1920;
    always @(posedge clk) begin
        nmi_tick <= 1'b0;
        if (rst) nacc <= 27'd0;
        else if (run) begin
            if (nsum >= 27'(CLK_HZ)) begin nacc <= nsum - 27'(CLK_HZ); nmi_tick <= 1'b1; end
            else nacc <= nsum;
        end
    end
endmodule
