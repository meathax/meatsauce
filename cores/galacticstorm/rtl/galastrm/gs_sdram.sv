// SPDX-License-Identifier: GPL-3.0-or-later
// Held CPU/graphics clients around the pinned F3/Sorgelig controller with documented DQ capture adaptation.
// All ports here use the 64MHz RAM clock; cross CPU clocks before this boundary.
module gs_sdram #(parameter CACHE_RESET_SEPARATE=0,WRITE_LINES=0)(
    input wire clk,reset,cache_reset,
    input wire [3:0] req,
    input wire cpu_write,
    input wire [24:0] cpu_addr,
    input wire [15:0] cpu_wdata,
    input wire [1:0] cpu_bytes,
    input wire cpu_write_line,
    input wire [63:0] cpu_wline,
    input wire [20:0] scp_addr,
    input wire [21:0] sprite_addr,
    input wire [17:0] map_word_addr,
    output wire [3:0] ack,      // [2]: sprite request accepted (split transaction)
    output wire sprite_rvalid,  // sprite reply, in accept order
    output reg [15:0] cpu_rdata,
    output reg [63:0] cpu_rline,
    output wire [15:0] map_rdata,
    output reg [63:0] scp_rdata,
    output wire [63:0] sprite_rdata,
    inout wire [15:0] SDRAM_DQ,
    output wire [12:0] SDRAM_A,
    output wire [1:0] SDRAM_BA,
    output wire SDRAM_DQML,SDRAM_DQMH,SDRAM_nCS,SDRAM_nWE,
    output wire SDRAM_nRAS,SDRAM_nCAS,SDRAM_CKE,SDRAM_CLK
);
    localparam IDLE=0,WAIT=1,REPLY=2,RETIRE=3;
    reg [1:0] state[0:3];
    reg [25:0] address[0:3];
    reg saved_write,saved_write_line;
    reg [63:0] saved_wline;
    reg [15:0] saved_data;
    reg [1:0] saved_bytes;
    wire [3:0] ready;
    wire [63:0] cpu_data,scp_data,sprite_data,map_data;
    wire map_cache_ack,map_raw_req;
    wire [18:0] map_raw_address;
    wire [63:0] map_cached_data;
    reg [63:0] map_reply;
    // Sprite rows are latency bound: split request/reply with up to two reads in
    // flight. Each request is a fresh edge into the controller; its address is
    // held until the controller reports the request taken.
    reg sprite_issue;
    reg [1:0] sprite_inflight;
    wire sprite_taken;
    wire sprite_accept=req[2] && !sprite_issue && sprite_inflight!=2;
    assign sprite_rdata=sprite_data;
    assign sprite_rvalid=ready[2];
    wire [3:0] internal_req={map_raw_req,req[2:0]};
    gs_rom64_cache #(.ADDR_BITS(19),.INDEX_BITS(6)) map_cache(
        .clk(clk),.reset(CACHE_RESET_SEPARATE ? cache_reset : reset),.req(req[3]),.address({map_word_addr[17:2],3'b0}),
        .ack(map_cache_ack),.data(map_cached_data),.raw_req(map_raw_req),
        .raw_address(map_raw_address),.raw_ack(state[3]==REPLY && map_raw_req),.raw_data(map_reply));
    assign map_rdata=map_cached_data>>(map_word_addr[1:0]*16);
    assign ack={map_cache_ack,sprite_accept,state[1]==REPLY && req[1],state[0]==REPLY && req[0]};
    // Emergency refresh is maintained by the derived controller every 480 clocks even
    // under load; no frame/blanking-only refresh assumption is required.
    sdram controller(
        .init(reset),.clk(clk),.doRefresh(1'b0),
        .SDRAM_DQ(SDRAM_DQ),.SDRAM_A(SDRAM_A),.SDRAM_BA(SDRAM_BA),
        .SDRAM_DQML(SDRAM_DQML),.SDRAM_DQMH(SDRAM_DQMH),.SDRAM_nCS(SDRAM_nCS),
        .SDRAM_nWE(SDRAM_nWE),.SDRAM_nRAS(SDRAM_nRAS),.SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE(SDRAM_CKE),.SDRAM_CLK(SDRAM_CLK),
        .ch1_addr(address[1]),.ch1_req(state[1]==WAIT),.ch1_ready(ready[1]),.ch1_dout(scp_data),
        .ch2_addr(address[2]),.ch2_req(sprite_issue),.ch2_ready(ready[2]),.ch2_taken(sprite_taken),.ch2_dout(sprite_data),
        .ch3_addr(address[0]),.ch3_req(state[0]==WAIT),.ch3_ready(ready[0]),.ch3_dout(cpu_data),
        .ch3_din(saved_data),.ch3_be(saved_bytes),.ch3_rnw(!saved_write),
        .ch3_write_line(saved_write_line),.ch3_wline(saved_wline),
        .ch4_addr(address[3]),.ch4_req(state[3]==WAIT),.ch4_ready(ready[3]),.ch4_dout(map_data),
        .ch5_addr(26'b0),.ch5_req(1'b0),.ch5_ready(),.ch5_dout(),
        .ch6_addr(26'b0),.ch6_req(1'b0),.ch6_ready(),.ch6_dout(),
        .ch7_addr(26'b0),.ch7_req(1'b0),.ch7_ready(),.ch7_dout(),
        .ch8_addr(26'b0),.ch8_req(1'b0),.ch8_ready(),.ch8_dout(),.ch8_din(16'b0),.ch8_be(2'b0),.ch8_rnw(1'b1));
`ifndef SYNTHESIS
    always @(posedge clk) if(!reset && WRITE_LINES && state[0]==IDLE && req[0] && cpu_write_line)
        assert(cpu_write && cpu_bytes==3 && cpu_addr[2:0]==0 && cpu_wdata==cpu_wline[15:0])
            else $fatal(1,"Invalid aligned full-word SDRAM line write");
`endif
    integer i;
    always @(posedge clk) begin
        if(sprite_accept) begin address[2]<=26'h200000+{5'b0,sprite_addr[21:1]};sprite_issue<=1;end
        if(sprite_issue && sprite_taken) sprite_issue<=0;
        sprite_inflight<=sprite_inflight+{1'b0,sprite_accept}-{1'b0,ready[2]};
        if(reset) begin sprite_issue<=0;sprite_inflight<=0;address[2]<=0;end
        for(i=0;i<4;i=i+1) if(i!=2) begin
            case(state[i])
            IDLE: if(internal_req[i]) begin
                state[i]<=WAIT;
                case(i)
                0: begin address[0]<={2'b0,cpu_addr[24:1]};saved_write<=cpu_write;saved_data<=cpu_wdata;saved_bytes<=cpu_bytes;
                    saved_write_line<=WRITE_LINES && cpu_write_line;
                    saved_wline<=WRITE_LINES ? cpu_wline : 64'b0;end
                1: address[1]<=26'h100000+{6'b0,scp_addr[20:1]};
                3: address[3]<=26'h0c0000+{8'b0,map_raw_address[18:1]};
                endcase
            end
            WAIT: if(ready[i]) begin
                state[i]<=REPLY;
                case(i)
                0: begin cpu_rdata<=cpu_data[15:0];cpu_rline<=cpu_data;end
                1: scp_rdata<=scp_data;
                3: map_reply<=map_data;
                endcase
            end
            REPLY: state[i]<=RETIRE;
            RETIRE: if(!internal_req[i]) state[i]<=IDLE;
            endcase
            if(reset) begin state[i]<=IDLE;address[i]<=0;end
        end
        if(reset) begin cpu_rdata<=0;cpu_rline<=0;scp_rdata<=0;map_reply<=0;saved_write<=0;saved_write_line<=0;saved_wline<=0;saved_data<=0;saved_bytes<=0;end
    end
endmodule
