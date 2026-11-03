module daikaiju_video_timing (
    input  logic       clk_sys,
    output logic       ce_pixel,
    output logic       ce_prepare,
    output logic [8:0] h_count,
    output logic [8:0] v_count,
    output logic       hsync_n,
    output logic       vsync_n,
    output logic       active_video
);
    localparam int PIXEL_DIV = 8;
    localparam int H_TOTAL = 400;
    localparam int V_TOTAL = 250;

    logic [2:0] pixel_phase = '0;
    initial begin
        h_count = '0;
        v_count = '0;
    end

    assign ce_pixel = (pixel_phase == 3'(PIXEL_DIV - 1));
    assign ce_prepare = (pixel_phase == 3'(PIXEL_DIV - 2));
    assign active_video = (h_count < 256) && (v_count >= 16) && (v_count < 240);
    assign hsync_n = !((h_count >= 304) && (h_count < 336));
    assign vsync_n = !((v_count >= 244) && (v_count < 247));

    always @(posedge clk_sys) begin
        pixel_phase <= pixel_phase + 1'b1;
        if (ce_pixel) begin
            if (h_count == 9'(H_TOTAL - 1)) begin
                h_count <= '0;
                if (v_count == 9'(V_TOTAL - 1))
                    v_count <= '0;
                else
                    v_count <= v_count + 1'b1;
            end else begin
                h_count <= h_count + 1'b1;
            end
        end
    end
endmodule
