module daikaiju_video_geometry (
    input  logic signed [4:0] hsize,
    input  logic signed [6:0] hposition,
    input  logic signed [4:0] vposition,
    input  logic              adjust_enable,
    input  logic [8:0]        h_counter,
    input  logic [8:0]        v_counter,
    output logic [8:0]        display_x,
    output logic [8:0]        display_y,
    output logic              display_valid,
    output logic [8:0]        prefetch_y
);
    logic [8:0] width_px;
    logic signed [10:0] h_start;
    logic [8:0] h_distance;
    logic [9:0] source_x;
    logic signed [10:0] v_start;
    logic [9:0] next_line;
    logic signed [10:0] next_source_y;
    logic signed [10:0] source_y_calc;
    wire [9:0] sample_center = {h_distance,1'b1};
    // Exact for every odd sample_center value 1..1023.
    wire [20:0] scaled_192 = sample_center * 11'd1366;
    wire [21:0] scaled_224 = sample_center * 12'd2341;
    wire [21:0] scaled_288 = sample_center * 12'd3641;
    wire [20:0] scaled_320 = sample_center * 11'd1639;

    always_comb begin
        width_px = 256;
        h_start = 0;
        if (adjust_enable) begin
            if (hsize < -2) width_px = 192;
            else if (hsize == -2) width_px = 192;
            else if (hsize == -1) width_px = 224;
            else if (hsize == 0) width_px = 256;
            else if (hsize == 1) width_px = 288;
            else width_px = 320;

            // Keep the picture centered as its width changes, then apply the
            // user's position offset. The window wraps only through blanking.
            h_start = $signed(hposition) - ($signed(hsize) * 11'sd16);
            if (h_start < 0) h_start = h_start + 400;
            if (h_start >= 400) h_start = h_start - 400;
        end

        if (h_counter >= h_start) h_distance = h_counter - h_start;
        else h_distance = h_counter + 400 - h_start;

        source_x = h_distance;
        if (adjust_enable) begin
            case (hsize)
                -5'sd2: source_x = scaled_192 >> 11;
                -5'sd1: source_x = scaled_224 >> 12;
                 5'sd1: source_x = scaled_288 >> 13;
                 5'sd2: source_x = scaled_320 >> 12;
                default: source_x = h_distance;
            endcase
        end

        v_start = 16 + (adjust_enable ? $signed(vposition) : 0);
        display_valid = 1'b0;
        display_x = 9'd256;
        display_y = v_counter;
        source_y_calc = v_counter;
        if (adjust_enable) begin
            if ((h_distance < width_px) && (v_counter >= v_start) &&
                (v_counter < v_start + 224)) begin
                display_valid = 1'b1;
                display_x = source_x[8:0];
                source_y_calc = v_counter;
                source_y_calc = source_y_calc - $signed(vposition);
                display_y = source_y_calc[8:0];
            end
        end else if ((h_counter < 9'd256) && (v_counter >= 9'd16) &&
                     (v_counter < 9'd240)) begin
            display_valid = 1'b1;
            display_x = h_counter;
            display_y = v_counter;
        end

        next_line = (v_counter == 9'd249) ? 0 : v_counter + 1;
        next_source_y = next_line;
        if (adjust_enable && (next_line >= v_start) &&
            (next_line < v_start + 224))
            next_source_y = $signed({1'b0,next_line}) - $signed(vposition);
        prefetch_y = next_source_y[8:0];
    end
endmodule
