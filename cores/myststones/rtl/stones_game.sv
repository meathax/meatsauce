// Framework-independent game assembly. Download addresses: CPU 00000-0ffff,
// FG/sprites 10000-1bfff, BG 20000-2bfff, palette PROM 30000-3001f.
module stones_game (
    input wire clk, reset,
    input wire [7:0] in0, in1, dsw0, dsw1,
    input wire coin,
    input wire pause_req,
    output wire paused,
    input wire hs_access, hs_write,
    input wire [12:0] hs_addr,
    input wire [7:0] hs_din,
    output wire [7:0] hs_dout,
    input wire dl_wr,
    input wire [17:0] dl_addr,
    input wire [7:0] dl_data,
    output wire ce_pixel,
    output reg [7:0] red, green, blue,
    output wire hblank, vblank, hs, vs,
    output wire [15:0] audio,
    output wire video_overrun,
    output wire [8:0] pixel_x, pixel_y,
    output wire [15:0] cpu_addr,
    output wire [7:0] cpu_data,
    output wire cpu_read, cpu_sync, ce_cpu
);
    wire [9:0] fg_addr,bg_addr;
    wire [7:0] fg_code,fg_attr,bg_code,bg_attr,control,scroll,ay_data,palette_data;
    wire [4:0] sprite_addr;
    wire [31:0] sprite_data;
    wire [1:0] ay_wr,ay_address;
    wire raw_ce,raw_hb,raw_vb;
    wire [8:0] h,v;
    wire [5:0] pen;
    stones_board board(
        .clk(clk),.reset(reset),.in0(in0),.in1(in1),.dsw0(dsw0),.dsw1(dsw1),.coin(coin),
        .pause_req(pause_req),.paused(paused),.hs_access(hs_access),.hs_write(hs_write),.hs_addr(hs_addr),.hs_din(hs_din),.hs_dout(hs_dout),
        .rom_wr(dl_wr && dl_addr[17:16]==0),.rom_addr(dl_addr[15:0]),.rom_data(dl_data),
        .fg_addr(fg_addr),.bg_addr(bg_addr),.fg_code(fg_code),.fg_attr(fg_attr),.bg_code(bg_code),.bg_attr(bg_attr),
        .sprite_addr(sprite_addr),.sprite_data(sprite_data),.palette_addr(pen[4:0]),.palette_data(palette_data),
        .video_control(control),.scroll(scroll),.ay_data(ay_data),.ay_wr(ay_wr),.ay_address(ay_address),
        .ce_pixel(raw_ce),.ce_cpu(ce_cpu),.h(h),.v(v),.hblank(raw_hb),.vblank(raw_vb),.irq(),
        .cpu_addr(cpu_addr),.cpu_data(cpu_data),.cpu_read(cpu_read),.cpu_sync(cpu_sync)
    );
    stones_video video(
        .clk(clk),.reset(reset),.ce_pixel(raw_ce),.h(h),.v(v),.video_control(control),.scroll(scroll),.flip_dip(dsw1[5]),
        .fg_addr(fg_addr),.bg_addr(bg_addr),.fg_code(fg_code),.fg_attr(fg_attr),.bg_code(bg_code),.bg_attr(bg_attr),
        .sprite_addr(sprite_addr),.sprite_data(sprite_data),
        .gfx_wr(dl_wr && (dl_addr[17:16]==1 || dl_addr[17:16]==2)),
        .gfx_addr({dl_addr[17],dl_addr[15:0]}),.gfx_data(dl_data),.pen(pen),.overrun(video_overrun)
    );

    reg [7:0] prom[0:31] /* verilator public_flat_rw */;
    reg [7:0] prom_q;
    reg prom_select;
    wire [7:0] color = prom_select ? prom_q : palette_data;
    // Rounded resistor network transfer, same common autoscale as MAME:
    // R/G 4700,3300,1500 ohms; B 3300,1500; 4700-ohm pull-ups.
    function automatic [7:0] rg(input [2:0] value);
        case(value)
            0:rg=0; 1:rg=60; 2:rg=72; 3:rg=132;
            4:rg=123; 5:rg=183; 6:rg=195; 7:rg=255;
        endcase
    endfunction
    function automatic [7:0] bb(input [1:0] value);
        case(value) 0:bb=0; 1:bb=85; 2:bb=145; 3:bb=231; endcase
    endfunction
    reg [2:0] ce_delay,hb_delay,vb_delay,hs_delay,vs_delay;
    reg [8:0] x_delay[0:2],y_delay[0:2];
    assign ce_pixel=ce_delay[2];
    assign hblank=hb_delay[2]; assign vblank=vb_delay[2];
    assign hs=hs_delay[2]; assign vs=vs_delay[2];
    assign pixel_x=x_delay[2]; assign pixel_y=y_delay[2];
    integer n;
    always @(posedge clk) begin
        if(dl_wr && dl_addr[17:5]==13'h1800) prom[dl_addr[4:0]]<=dl_data;
        prom_q<=prom[pen[4:0]];
        prom_select<=pen[5];
        red<=rg(color[2:0]); green<=rg(color[5:3]); blue<=bb(color[7:6]);
        ce_delay<={ce_delay[1:0],raw_ce};
        hb_delay<={hb_delay[1:0],raw_hb}; vb_delay<={vb_delay[1:0],raw_vb};
        // Porches preserve the measured raw totals. Exact PCB sync pulse
        // widths are not documented by MAME and remain separately qualified.
        hs_delay<={hs_delay[1:0],h>=280 && h<312};
        vs_delay<={vs_delay[1:0],v>=256 && v<260};
        x_delay[0]<=h; y_delay[0]<=v;
        for(n=1;n<3;n=n+1) begin x_delay[n]<=x_delay[n-1]; y_delay[n]<=y_delay[n-1]; end
        if(reset) begin ce_delay<=0; hb_delay<=7; vb_delay<=7; hs_delay<=0; vs_delay<=0; end
    end

    wire [4:0] ay_level[0:5];
    reg [3:0] ay_reg[0:1];
    always @(posedge clk) begin
        if(reset) begin ay_reg[0]<=0; ay_reg[1]<=0; end
        else begin
            if(ay_wr[0] && ay_address[0]) ay_reg[0]<=ay_data[3:0];
            if(ay_wr[1] && ay_address[1]) ay_reg[1]<=ay_data[3:0];
        end
    end
    jt49 #(.MUTE_NULL_PERIOD(0)) ay0(.rst_n(~reset),.clk(clk),.clk_en(ce_cpu && !paused),.addr(ay_reg[0]),.cs_n(1'b0),
        .wr_n(~(ay_wr[0] && !ay_address[0])),.din(ay_data),.sel(1'b1),.dout(),.sound(),
        .LOG_A(ay_level[0]),.LOG_B(ay_level[1]),.LOG_C(ay_level[2]),
        .A(),.B(),.C(),.sample(),.IOA_in(8'hff),.IOA_out(),.IOA_oe(),.IOB_in(8'hff),.IOB_out(),.IOB_oe());
    jt49 #(.MUTE_NULL_PERIOD(0)) ay1(.rst_n(~reset),.clk(clk),.clk_en(ce_cpu && !paused),.addr(ay_reg[1]),.cs_n(1'b0),
        .wr_n(~(ay_wr[1] && !ay_address[1])),.din(ay_data),.sel(1'b1),.dout(),.sound(),
        .LOG_A(ay_level[3]),.LOG_B(ay_level[4]),.LOG_C(ay_level[5]),
        .A(),.B(),.C(),.sample(),.IOA_in(8'hff),.IOA_out(),.IOA_oe(),.IOB_in(8'hff),.IOB_out(),.IOB_oe());
    // MAME AY8910 resistor curve, legacy normalization and 0.30 route gain:
    // round(normalized_level * 0.5 * 0.30 * 32768), without constant DC.
    // JT49's 32-step envelope becomes the AY's 16 steps through raw[4:1].
    // Its fixed-volume encoding maps through the same bits without loss.
    function automatic [15:0] ay_level_pcm(input [4:0] raw_level);
        case(raw_level[4:1])
             0: ay_level_pcm=0;     1: ay_level_pcm=67;
             2: ay_level_pcm=87;    3: ay_level_pcm=113;
             4: ay_level_pcm=154;   5: ay_level_pcm=214;
             6: ay_level_pcm=288;   7: ay_level_pcm=468;
             8: ay_level_pcm=577;   9: ay_level_pcm=946;
            10: ay_level_pcm=1309; 11: ay_level_pcm=1738;
            12: ay_level_pcm=2323; 13: ay_level_pcm=2943;
            14: ay_level_pcm=3895; 15: ay_level_pcm=4915;
        endcase
    endfunction
    // Six simultaneous maximum channels total 29490, so no clipping occurs.
    assign audio=reset ? 16'd0 : ay_level_pcm(ay_level[0])+ay_level_pcm(ay_level[1])+
        ay_level_pcm(ay_level[2])+ay_level_pcm(ay_level[3])+
        ay_level_pcm(ay_level[4])+ay_level_pcm(ay_level[5]);
endmodule
