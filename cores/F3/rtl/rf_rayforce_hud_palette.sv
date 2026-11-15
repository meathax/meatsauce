// Ray Force deliberately alternates these HUD palette colours each frame.
// The requested steady presentation uses their component-wise mean.
// Evidence and limits: docs/RAYFORCE_HUD_STABILITY.md.
module rf_rayforce_hud_palette (
    input wire enable,
    input wire [12:0] index,
    input wire [23:0] rgb_in,
    output logic [23:0] rgb_out
);
    always_comb begin
        rgb_out = rgb_in;
        if (enable) begin
            case (index)
                13'h222, 13'h223:
                    if (rgb_in == 24'h000000 || rgb_in == 24'h444400)
                        rgb_out = 24'h222200;
                13'h224, 13'h22a:
                    if (rgb_in == 24'h908400 || rgb_in == 24'hc0b000)
                        rgb_out = 24'ha89a00;
                13'h225, 13'h22b:
                    if (rgb_in == 24'ha09000 || rgb_in == 24'hcab83a)
                        rgb_out = 24'hb5a41d;
                13'h226, 13'h22c:
                    if (rgb_in == 24'hb0a800 || rgb_in == 24'hd4ca48)
                        rgb_out = 24'hc2b924;
                13'h227, 13'h22d:
                    if (rgb_in == 24'hcab800 || rgb_in == 24'he8de60)
                        rgb_out = 24'hd9cb30;
                13'h228, 13'h22e:
                    if (rgb_in == 24'hded400 || rgb_in == 24'he8f26c)
                        rgb_out = 24'he3e336;
                13'h229, 13'h22f:
                    if (rgb_in == 24'hfcf22e || rgb_in == 24'hffff8a)
                        rgb_out = 24'hfdf85c;
                13'h232, 13'h233:
                    if (rgb_in == 24'h000000 || rgb_in == 24'h440000)
                        rgb_out = 24'h220000;
                13'h234, 13'h23a:
                    if (rgb_in == 24'h985400 || rgb_in == 24'hde842e)
                        rgb_out = 24'hbb6c17;
                13'h235, 13'h23b:
                    if (rgb_in == 24'ha86000 || rgb_in == 24'hde902e)
                        rgb_out = 24'hc37817;
                13'h236, 13'h23c:
                    if (rgb_in == 24'hb86c00 || rgb_in == 24'he8a82e)
                        rgb_out = 24'hd08a17;
                13'h237, 13'h23d:
                    if (rgb_in == 24'hca7800 || rgb_in == 24'hf2c034)
                        rgb_out = 24'hde9c1a;
                13'h238, 13'h23e:
                    if (rgb_in == 24'hde8400 || rgb_in == 24'hfcde34)
                        rgb_out = 24'hedb11a;
                13'h239, 13'h23f:
                    if (rgb_in == 24'hf2902e || rgb_in == 24'hfffc3a)
                        rgb_out = 24'hf8c634;
                13'h31b, 13'h32b:
                    if (rgb_in == 24'h006600 || rgb_in == 24'h4eb854)
                        rgb_out = 24'h278f2a;
                13'h31c, 13'h32c:
                    if (rgb_in == 24'h44a844 || rgb_in == 24'h78e878)
                        rgb_out = 24'h5ec85e;
                13'h31d, 13'h32d:
                    if (rgb_in == 24'h66ff66 || rgb_in == 24'hcaffb0)
                        rgb_out = 24'h98ff8b;
                13'h31e, 13'h32e:
                    if (rgb_in == 24'h8aff8a || rgb_in == 24'hd4ffd4)
                        rgb_out = 24'hafffaf;
                default: ;
            endcase
        end
    end
endmodule
