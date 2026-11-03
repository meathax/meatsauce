// SPDX-License-Identifier: GPL-3.0-or-later
// Five held ROM ports -> one held, aligned four-word SDRAM read.
// All signals are synchronous to clk. mem_data[15:0] is the first physical
// 16-bit word, [31:16] the second, etc. The backend must flush on common reset.
// Main CPU has16direct-mapped8-byte lines; graphics each have one line.
// No inferred clocks or timing cuts.
module madmotor_rom_bridge(
    input tri0 bandit,
    input logic clk,reset,
    input logic main_cs,
    input logic [17:0] main_addr,
    output wire [15:0] main_data,
    output wire main_ok,
    input logic [2:0] tile_cs,
    input logic [16:0] tile_addr [3],
    output wire [31:0] tile_data [3],
    output wire [2:0] tile_ok,
    input logic sprite_cs,
    input logic [17:0] sprite_addr,
    output wire [31:0] sprite_data,
    output wire sprite_ok,
    output wire mem_req,
    output wire [23:0] mem_addr, // physical word16 index; [23:22] is bank
    input logic mem_ok,
    input logic [63:0] mem_data
);
    wire [4:0] cs={sprite_cs,tile_cs,main_cs};
    wire [23:0] address [5];
    // Main 512KiB bank0. Chars128KiB + tiles1 256KiB bank1.
    // Tiles2 512KiB bank2. Sprites1MiB bank3. Unconnected ROM address
    // bits mirror at the actual populated region size, as in the renderer.
    assign address[0]={6'd0,main_addr};
    assign address[1]=24'h400000+{8'd0,tile_addr[0][14:0],1'b0};
    assign address[2]=24'h410000+(bandit?{6'd0,tile_addr[1],1'b0}:{7'd0,tile_addr[1][15:0],1'b0});
    assign address[3]=24'h800000+(bandit?{7'd0,tile_addr[2][15:0],1'b0}:{6'd0,tile_addr[2],1'b0});
    assign address[4]=24'hc00000+(bandit?{6'd0,sprite_addr[16:0],1'b0}:{5'd0,sprite_addr,1'b0});
    logic [4:0] valid;
    logic [21:0] tag [5];
    logic [63:0] line [5];
    logic [15:0] main_valid;
    logic [21:0] main_tag [16];
    (* ramstyle = "logic" *) logic [63:0] main_line [16];
    wire [3:0] main_index=address[0][5:2];
    wire [4:0] hit;
    genvar client_index,tile_index;
    generate
        for(client_index=0;client_index<5;client_index=client_index+1)begin:ports
            if(client_index==0)begin:main_cache
                assign hit[0]=!reset&&cs[0]&&main_valid[main_index]&&main_tag[main_index]==address[0][23:2];
            end else begin:graphics_cache
                assign hit[client_index]=!reset&&cs[client_index]&&valid[client_index]&&tag[client_index]==address[client_index][23:2];
            end
        end
    endgenerate
    assign main_ok=hit[0];assign tile_ok=hit[3:1];assign sprite_ok=hit[4];
    assign main_data=main_line[main_index][16*address[0][1:0]+:16];
    generate
        for(tile_index=0;tile_index<3;tile_index=tile_index+1)begin:tiles
            wire [31:0] pair=line[tile_index+1][32*address[tile_index+1][1]+:32];
            assign tile_data[tile_index]={pair[15:0],pair[31:16]};
        end
    endgenerate
    wire [31:0] object_pair=line[4][32*address[4][1]+:32];
    assign sprite_data={object_pair[15:0],object_pair[31:16]};
    logic busy;
    logic [2:0] owner,round_robin;
    logic [23:0] pending_address;
    assign mem_req=busy&&!reset;
    assign mem_addr=pending_address;
    logic found;
    logic [2:0] selected;
    integer candidate;
    always_comb begin
        found=0;selected=0;candidate=0;
        for(integer step=0;step<5;step=step+1)begin
            candidate=int'(round_robin)+step;
            if(candidate>=5)candidate=candidate-5;
            if(!found&&cs[candidate]&&!hit[candidate])begin
                found=1;selected=3'(candidate);
            end
        end
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            valid<=0;main_valid<=0;busy<=0;owner<=0;round_robin<=0;pending_address<=0;
        end else if(busy)begin
            if(mem_ok)begin
                if(owner==0)begin
                    main_line[pending_address[5:2]]<=mem_data;
                    main_tag[pending_address[5:2]]<=pending_address[23:2];
                    main_valid[pending_address[5:2]]<=1;
                end else begin
                    line[owner]<=mem_data;tag[owner]<=pending_address[23:2];valid[owner]<=1;
                end
                busy<=0;
            end
        end else if(found)begin
            owner<=selected;pending_address<={address[selected][23:2],2'b00};busy<=1;
            round_robin<=selected==4?3'd0:selected+3'd1;
        end
    end
`ifdef VERILATOR
    logic [4:0] previous_cs,previous_hit;
    logic [23:0] previous_address [5];
    always_ff @(posedge clk)begin
        if(reset)begin previous_cs<=0;previous_hit<=0;end
        else begin
            for(integer p=0;p<5;p=p+1)begin
                if(cs[p]&&previous_cs[p])assert(address[p]==previous_address[p])
                    else $fatal(1,"ROM client address changed before release port%0d",p);
                if(busy&&owner==3'(p))assert(cs[p]&&address[p][23:2]==pending_address[23:2])
                    else $fatal(1,"ROM client abandoned outstanding read port%0d",p);
                previous_address[p]<=address[p];
            end
            previous_cs<=cs;previous_hit<=hit;
        end
    end
`endif
endmodule
