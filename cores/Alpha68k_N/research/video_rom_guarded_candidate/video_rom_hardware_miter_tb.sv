module video_rom_miter_tb;
    reg clk=0,load_wr=0;
    reg [24:0] load_addr=0;
    reg [15:0] load_data=0;
    reg [12:0] color_addr=0,debug_addr=0;
    reg [8:0] pen=0;
    reg [7:0] background=0;
    reg [3:0] debug_kind=0;
    wire [7:0] expected_color,actual_color;
    wire [23:0] expected_rgb,actual_rgb;
    wire [15:0] expected_debug,actual_debug;
    reg [31:0] rng=32'h6850f00d;
    integer i,bank,checks=0,collisions=0;
    original_video_rom reference(.clk(clk),.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),.color_addr(color_addr),.color_data(expected_color),.pen(pen),.background(background),.rgb(expected_rgb),.debug_kind(debug_kind),.debug_addr(debug_addr),.debug_data(expected_debug));
    alpha68kn_video_rom candidate(.clk(clk),.load_wr(load_wr),.load_addr(load_addr),.load_data(load_data),.color_addr(color_addr),.color_data(actual_color),.pen(pen),.background(background),.rgb(actual_rgb),.debug_kind(debug_kind),.debug_addr(debug_addr),.debug_data(actual_debug));
    task tick(input bit verify);
        begin
            #5 clk=1;
            #1;
            if(verify) begin
                if({actual_color,actual_rgb,actual_debug} !== {expected_color,expected_rgb,expected_debug})
                    $fatal(1,"Cycle %0d mismatch color %h/%h RGB %h/%h debug %h/%h", checks,actual_color,expected_color,actual_rgb,expected_rgb,actual_debug,expected_debug);
                if((^expected_color)===1'bx || (^expected_rgb)===1'bx || (^expected_debug)===1'bx)
                    $fatal(1,"Unknown output after complete initialization at %0d",checks);
                checks=checks+1;
            end
            #4 clk=0;
        end
    endtask
    task load_bank(input integer base,input integer bytes);
        integer a;
        begin
            for(a=0;a<bytes;a=a+2) begin
                rng=rng*32'd1664525+32'd1013904223;
                load_wr=1;load_addr=base+a;load_data=rng[23:8];
                tick(0);
            end
        end
    endtask
    initial begin
        load_bank('h30100,256);load_bank('h30200,256);load_bank('h30300,256);
        load_bank('h30400,256);load_bank('h30500,256);load_bank('h31000,8192);
        load_wr=0;debug_kind=0;
        tick(0);tick(0);tick(0);
        for(i=0;i<131072;i=i+1) begin
            rng=rng*32'd1664525+32'd1013904223;
            color_addr=i[12:0];pen=i[8:0]^rng[20:12];background=rng[7:0];
            debug_kind=0;debug_addr=i[12:0];load_wr=(i%7)==0;
            if(load_wr) begin
                bank=(i/7)%6;load_data=rng[31:16];
                case(bank)
                    0:load_addr='h30100+{reference.indirect[7:1],1'b0};
                    1:load_addr='h30200+{reference.indirect[7:1],1'b0};
                    2:load_addr='h30300+{reference.indirect[7:1],1'b0};
                    3:load_addr='h30400+{pen[7:1],1'b0};
                    4:load_addr='h30500+{pen[7:1],1'b0};
                    5:load_addr='h31000+{color_addr[12:1],1'b0};
                endcase
                collisions=collisions+1;
            end
            tick(1);
        end
        $display("PASS video ROM cycle miter 131072, runtime collisions %0d",collisions);
        $finish;
    end
endmodule
