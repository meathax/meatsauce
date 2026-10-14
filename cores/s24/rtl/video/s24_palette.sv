// 315-5242 palette: nonzero shade levels retain the MAME-derived table;
// the zero-component gate follows SiliconRE M71064 die-traced evidence.
module s24_palette (
    input  logic [15:0] palette_word,
    input  logic        shadow_bank,
    output logic [7:0]  red,
    output logic [7:0]  green,
    output logic [7:0]  blue
);
    function automatic [7:0] expand5(input [4:0] c);
        expand5 = {c, c[4:2]};
    endfunction

    function automatic [7:0] shade_value(
        input logic [4:0] component,
        input logic        highlight
    );
        case (component)
            5'd0: shade_value = 8'd0;
            5'd1: shade_value = highlight ? 8'd106 : 8'd4;
            5'd2: shade_value = highlight ? 8'd111 : 8'd9;
            5'd3: shade_value = highlight ? 8'd116 : 8'd14;
            5'd4: shade_value = highlight ? 8'd121 : 8'd19;
            5'd5: shade_value = highlight ? 8'd126 : 8'd24;
            5'd6: shade_value = highlight ? 8'd131 : 8'd29;
            5'd7: shade_value = highlight ? 8'd136 : 8'd34;
            5'd8: shade_value = highlight ? 8'd141 : 8'd39;
            5'd9: shade_value = highlight ? 8'd146 : 8'd44;
            5'd10: shade_value = highlight ? 8'd151 : 8'd49;
            5'd11: shade_value = highlight ? 8'd156 : 8'd54;
            5'd12: shade_value = highlight ? 8'd161 : 8'd59;
            5'd13: shade_value = highlight ? 8'd166 : 8'd64;
            5'd14: shade_value = highlight ? 8'd171 : 8'd69;
            5'd15: shade_value = highlight ? 8'd175 : 8'd73;
            5'd16: shade_value = highlight ? 8'd181 : 8'd79;
            5'd17: shade_value = highlight ? 8'd186 : 8'd84;
            5'd18: shade_value = highlight ? 8'd190 : 8'd88;
            5'd19: shade_value = highlight ? 8'd195 : 8'd93;
            5'd20: shade_value = highlight ? 8'd201 : 8'd99;
            5'd21: shade_value = highlight ? 8'd205 : 8'd103;
            5'd22: shade_value = highlight ? 8'd210 : 8'd108;
            5'd23: shade_value = highlight ? 8'd215 : 8'd113;
            5'd24: shade_value = highlight ? 8'd220 : 8'd118;
            5'd25: shade_value = highlight ? 8'd225 : 8'd123;
            5'd26: shade_value = highlight ? 8'd230 : 8'd128;
            5'd27: shade_value = highlight ? 8'd235 : 8'd133;
            5'd28: shade_value = highlight ? 8'd240 : 8'd138;
            5'd29: shade_value = highlight ? 8'd245 : 8'd143;
            5'd30: shade_value = highlight ? 8'd250 : 8'd148;
            default: shade_value = highlight ? 8'd255 : 8'd153;
        endcase
    endfunction

    logic [4:0] r5, g5, b5;
    logic [7:0] r0, g0, b0;
    always_comb begin
        r5 = {palette_word[3:0],  palette_word[12]};
        g5 = {palette_word[7:4],  palette_word[13]};
        b5 = {palette_word[11:8], palette_word[14]};
        r0 = expand5(r5);
        g0 = expand5(g5);
        b0 = expand5(b5);
        if (shadow_bank) begin
            red   = shade_value(r5,palette_word[15]);
            green = shade_value(g5,palette_word[15]);
            blue  = shade_value(b5,palette_word[15]);
        end else begin
            red = r0; green = g0; blue = b0;
        end
    end
endmodule

// One physical 8Kx16 palette copy. Both RAM ports belong to video on ce_pixel;
// port B serves one CPU access in the intervening clk cycles. This keeps CPU
// traffic structurally disjoint from video reads, so mixed-port OLD_DATA
// behavior is preserved without a same-edge CPU/video collision.
module s24_palette_ram (
    input  logic        clk,
    input  logic        reset,
    input  logic        ce_pixel,
    input  logic [13:0] mixed,
    input  logic [13:0] mixed_alt,
    input  logic        blend,
    input  logic        display_blank,
    output logic [15:0] video_word,
    output logic [15:0] video_word_alt,
    output logic        shadow_bank,
    output logic        shadow_bank_alt,
    output logic        blend_q,
    output logic        display_blank_q,

    input  logic        cpu_req,
    input  logic        cpu_write,
    input  logic [12:0] cpu_addr,
    input  logic [15:0] cpu_wdata,
    input  logic [1:0]  cpu_be,
    output logic [15:0] cpu_rdata,
    output logic        cpu_done
);
    (* ramstyle="M10K, no_rw_check" *) logic [15:0] mem [0:8191];
    logic cpu_busy;
    integer palette_init;

    initial begin
        // Quartus 17 rejects a single elaboration loop above 5000 iterations.
        for (palette_init=0; palette_init<4096; palette_init=palette_init+1)
            mem[palette_init] = 16'h0000;
        for (palette_init=4096; palette_init<8192; palette_init=palette_init+1)
            mem[palette_init] = 16'h0000;
    end

    // Read-only port A: primary video lookup.
    always_ff @(posedge clk) begin
        if (ce_pixel)
            video_word <= mem[mixed[12:0]];
    end

    // Port B: alternate video lookup has priority on every pixel edge; CPU
    // accesses are accepted only in a gap. Byte writes retain the untouched
    // lane, matching the physical palette's UDS/LDS behavior.
    always_ff @(posedge clk) begin
        if (reset) begin
            cpu_done <= 1'b0;
            cpu_busy <= 1'b0;
        end else begin
            cpu_done <= 1'b0;
            if (!cpu_req)
                cpu_busy <= 1'b0;

            if (ce_pixel) begin
                video_word_alt <= mem[mixed_alt[12:0]];
                shadow_bank <= mixed[13];
                shadow_bank_alt <= mixed_alt[13];
                blend_q <= blend;
                display_blank_q <= display_blank;
            end else if (cpu_req && !cpu_busy) begin
                cpu_rdata <= mem[cpu_addr];
                if (cpu_write && cpu_be[0])
                    mem[cpu_addr][7:0] <= cpu_wdata[7:0];
                if (cpu_write && cpu_be[1])
                    mem[cpu_addr][15:8] <= cpu_wdata[15:8];
                cpu_done <= 1'b1;
                cpu_busy <= 1'b1;
            end
        end
    end
endmodule
