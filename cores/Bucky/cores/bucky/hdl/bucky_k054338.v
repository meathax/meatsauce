/*
 * Konami 054338 color-math core.
 *
 * Derived from the SiliconRE reconstructed pinout/schematic and README at
 * commit bf17e0275f06df1c78f3cdcba770f0cc6cce6397. There is no upstream HDL
 * for this device. Channel arithmetic is shared here, while palette storage
 * and layer priority remain in the surrounding GX173 video system.
 */
module bucky_k054338(
    input             rst,
    input             clk,
    input             cen,

    input             reg_cs,
    input             reg_we,
    input      [ 3:0] reg_addr,
    input      [15:0] reg_din,
    input      [ 1:0] reg_dsn,
    output     [15:0] reg_dout,

    input      [23:0] front_bgr,
    input      [23:0] back_bgr,
    input      [ 1:0] mix_code,
    input      [ 1:0] shadow_code,
    input      [ 1:0] brightness_code,
    output reg [23:0] color_bgr,
    output reg [ 7:0] brightness
);

reg [15:0] regs[0:15];
reg [ 1:0] mix_d, shadow_d, brightness_d;
integer i;

always @(posedge clk, posedge rst) begin
    if (rst) begin
        for (i=0;i<16;i=i+1) regs[i] <= 16'd0;
        mix_d <= 0;
        shadow_d <= 0;
        brightness_d <= 0;
    end else begin
        if (reg_cs && reg_we) begin
            if (!reg_dsn[1]) regs[reg_addr][15:8] <= reg_din[15:8];
            if (!reg_dsn[0]) regs[reg_addr][ 7:0] <= reg_din[ 7:0];
        end
        if (cen) begin
            mix_d       <= mix_code;
            shadow_d    <= shadow_code;
            brightness_d<= brightness_code;
        end
    end
end

assign reg_dout = regs[reg_addr];

wire [1:0] mix_sel = regs[15][1] ? mix_d : mix_code;
wire [1:0] shd_sel  = regs[15][2] ? shadow_d : shadow_code;
wire [1:0] bri_sel  = regs[15][3] ? brightness_d : brightness_code;

reg       mix_mode;
reg [4:0] mix_level;
always @* begin
    mix_mode  = 1'b0;
    mix_level = 5'd0;
    case (mix_sel)
        2'd1: begin mix_mode=regs[13][5];  mix_level=regs[13][4:0];  end
        2'd2: begin mix_mode=regs[14][13]; mix_level=regs[14][12:8]; end
        2'd3: begin mix_mode=regs[14][5];  mix_level=regs[14][4:0];  end
        default: ;
    endcase
end

function [7:0] mix_channel;
    input [7:0] front;
    input [7:0] back;
    input [4:0] level;
    input       additive;
    reg  [13:0] product;
    reg  [ 9:0] value;
    reg  [ 5:0] inverse_level;
    begin
        // Keep the products explicitly 14 bits.  Verilog's expression sizing
        // rules are easy to misread for packed multiply/add expressions; the
        // silicon's 8x5 products plus their sum need 14 bits before the >>5.
        inverse_level = 6'd32 - {1'b0,level};
        if (!additive) begin
            // SiliconRE: 8x5 multiply/add interpolation, taking the scaled
            // high eight bits. Level 0 selects B; increasing level selects A.
            product = {6'd0,front} * {9'd0,level} +
                      {6'd0,back}  * {8'd0,inverse_level};
            // product[13:5] is the mathematically defined scaled result;
            // make the zero extension explicit instead of relying on the
            // destination width to truncate the shift expression.
            value   = {1'b0,product[13:5]};
        end else begin
            // Documented additive mode: A + B*(32-level)/32.
            product = {6'd0,back} * {8'd0,inverse_level};
            value   = {2'd0,front} + {1'b0,product[13:5]};
        end
        mix_channel = (value>10'd255) ? 8'hff : value[7:0];
    end
endfunction

reg signed [9:0] shd_b, shd_g, shd_r;
always @* begin
    shd_r = 0; shd_g = 0; shd_b = 0;
    case (shd_sel)
        2'd1: begin shd_r=$signed({regs[2][8],regs[2][8:0]}); shd_g=$signed({regs[3][8],regs[3][8:0]}); shd_b=$signed({regs[4][8],regs[4][8:0]}); end
        2'd2: begin shd_r=$signed({regs[5][8],regs[5][8:0]}); shd_g=$signed({regs[6][8],regs[6][8:0]}); shd_b=$signed({regs[7][8],regs[7][8:0]}); end
        2'd3: begin shd_r=$signed({regs[8][8],regs[8][8:0]}); shd_g=$signed({regs[9][8],regs[9][8:0]}); shd_b=$signed({regs[10][8],regs[10][8:0]}); end
        default: ;
    endcase
end

function [7:0] add_shadow;
    input [7:0] component;
    input signed [9:0] delta;
    input noclip;
    reg signed [10:0] value;
    begin
        value = $signed({3'b000,component}) + $signed({delta[9],delta});
        if (noclip) add_shadow = value[7:0];
        else if (value < 0) add_shadow = 8'h00;
        else if (value > 255) add_shadow = 8'hff;
        else add_shadow = value[7:0];
    end
endfunction

wire [23:0] background_bgr = {regs[1][7:0],regs[1][15:8],regs[0][7:0]};
wire [ 7:0] mixed_b = mix_channel(front_bgr[23:16],back_bgr[23:16],mix_level,mix_mode);
wire [ 7:0] mixed_g = mix_channel(front_bgr[15: 8],back_bgr[15: 8],mix_level,mix_mode);
wire [ 7:0] mixed_r = mix_channel(front_bgr[ 7: 0],back_bgr[ 7: 0],mix_level,mix_mode);
wire [23:0] selected_bgr = !regs[15][0] ? background_bgr :
                           mix_sel==0    ? front_bgr     : {mixed_b,mixed_g,mixed_r};
wire [23:0] shadowed_bgr = {
    add_shadow(selected_bgr[23:16],shd_b,regs[15][5]),
    add_shadow(selected_bgr[15: 8],shd_g,regs[15][5]),
    add_shadow(selected_bgr[ 7: 0],shd_r,regs[15][5])
};

reg [7:0] brightness_next;
always @* begin
    case (bri_sel)
        2'd1: brightness_next = regs[11][7:0];
        2'd2: brightness_next = regs[12][15:8];
        2'd3: brightness_next = regs[12][7:0];
        default: brightness_next = 8'hff;
    endcase
end

always @(posedge clk, posedge rst) begin
    if (rst) begin
        color_bgr <= 0;
        brightness <= 8'hff;
    end else if (cen) begin
        color_bgr <= shadowed_bgr;
        brightness <= brightness_next;
    end
end

endmodule
