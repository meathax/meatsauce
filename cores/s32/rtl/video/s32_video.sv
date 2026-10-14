//============================================================================
//  System 32 video top: CRT timing (DESIGN.md §6.8) + pipeline orchestration.
//  416x224 in 512x262 @ ~60.04 Hz (dot CE = MAIN/4 = 8.054 MHz), or
//  320x224 in 410x262 (dot CE = MAIN/5).  Mode from sprite control reg 6.
//============================================================================

module s32_video (
    input             clk,          // clk_sys (48.3 MHz)
    input             rst,
    input             mode_416,

    output reg        ce_pix,
    output reg        mode_active,
    output reg  [8:0] hcnt,
    output reg  [8:0] vcnt,
    output reg        hblank,
    output reg        vblank,
    output reg        hsync,
    output reg        vsync,
    output            vblank_start, // pulse: line 224 start (IRQ source 0)
    output            vblank_end    // pulse: line 0 start   (IRQ source 1)
);

// dot clock CE: /6 of 48.317307 = 8.054 (416 mode); /7.5 -> approximate /15 of
// 96.6 for 320 mode; here fractional accumulator for exactness.
reg [7:0] ce_acc;
wire [7:0] ce_add = mode_active ? 8'd40 : 8'd32; // 40/240=1/6 ; 32/240=/7.5
always @(posedge clk) begin
    if (rst) begin ce_acc <= 0; ce_pix <= 0; end
    else begin
        logic [8:0] s;
        s = ce_acc + ce_add;
        ce_pix <= (s >= 9'd240);
        // s is at most 279, so the wrapped result is 0..39.  Work on the
        // explicit low byte to avoid an implicit 9-to-8-bit truncation.
        ce_acc <= (s >= 9'd240) ? (s[7:0] - 8'd240) : s[7:0];
    end
end

wire [8:0] htotal = mode_active ? 9'd511 : 9'd409;
wire [8:0] hdisp  = mode_active ? 9'd415 : 9'd319;
localparam [8:0] VTOTAL = 9'd261;
localparam [8:0] VDISP  = 9'd223;

reg vb_start_r, vb_end_r;
assign vblank_start = vb_start_r;
assign vblank_end   = vb_end_r;

// VSync pulse starts 10 lines after VDISP, i.e. lines 234-236.
localparam [8:0] VS_OFF = 9'd10;

always @(posedge clk) begin
    if (rst) begin
        mode_active <= mode_416;
        hcnt <= 0; vcnt <= 0;
        hblank <= 0; vblank <= 0; hsync <= 0; vsync <= 0;
        vb_start_r <= 0; vb_end_r <= 0;
    end
    else begin
        vb_start_r <= 0;
        vb_end_r   <= 0;
        if (ce_pix) begin
            if (hcnt == htotal) begin
                hcnt <= 0;
                hblank <= 0;
                if (vcnt == VTOTAL) begin
                    vcnt <= 0;
                    vblank <= 0;
                    vb_end_r <= 1'b1;
                    // Width affects dot cadence and horizontal totals.  Apply
                    // it only between complete frames so a live register
                    // write cannot truncate or stretch the current line.
                    mode_active <= mode_416;
                end
                else begin
                    vcnt <= vcnt + 1'd1;
                    if (vcnt == VDISP) begin
                        vblank <= 1'b1;
                        vb_start_r <= 1'b1;
                    end
                end
            end
            else begin
                hcnt <= hcnt + 1'd1;
                if (hcnt == hdisp) hblank <= 1'b1;
            end
            // syncs in blanking region
            hsync <= (hcnt >= hdisp + 9'd24) && (hcnt < hdisp + 9'd56);
            vsync <= (vcnt >= VDISP + VS_OFF) && (vcnt < VDISP + VS_OFF + 9'd3);
        end
    end
end

endmodule
