// Raw download bytes are preserved. Swap physical address bits 0 and 3 so
// the two bytes of one eight-pixel plane row occupy a single SDRAM word.
module alpha68kn_gfxmem (
    input wire clk,reset,load_wr,
    input wire [18:0] load_addr,
    input wire [15:0] load_data,
    output wire load_wait,load_busy,initialized,
    output reg [31:0] loaded_words,
    input wire refresh,read_req,
    input wire [18:0] read_addr,
    output wire read_ack,read_ready,
    output wire [15:0] read_data,
    inout wire [15:0] sdram_dq,
`ifdef VERILATOR
    output wire [15:0] sdram_din,
`endif
    output wire [12:0] sdram_a,
    output wire [1:0] sdram_ba,
    output wire sdram_dqml,sdram_dqmh,sdram_nwe,sdram_ncas,sdram_nras,sdram_ncs,sdram_cke
);
    function automatic [18:0] physical(input [18:0] raw);
        physical={raw[18:4],raw[0],raw[2:1],raw[3]};
    endfunction
    reg [34:0] fifo[0:15];
    reg [3:0] wp,rp;
    reg [4:0] count;
    reg [1:0] state;
    reg [18:0] current_addr;
    reg [15:0] current_data;
    reg byte_index,prog_wr;
    wire init,prog_ack,prog_rdy;
    wire push=load_wr;
    wire pop=initialized && state==0 && count!=0;
    wire [18:0] raw_byte=current_addr+{18'd0,byte_index};
    wire [18:0] phy_byte=physical(raw_byte);
    wire [18:0] phy_read=physical(read_addr);
    wire [7:0] byte_data=byte_index ? current_data[15:8] : current_data[7:0];
    wire [3:0] ack,rdy;
    assign initialized=!init && !reset;
    assign load_busy=count!=0 || state!=0 || load_wr;
    // Two beats of headroom cover the board's registered forwarding pulse.
    assign load_wait=!initialized || count>=14;
    assign read_ack=ack[0];
    assign read_ready=rdy[0];
    always @(posedge clk) begin
        if(reset) begin
            wp<=0;rp<=0;count<=0;state<=0;prog_wr<=0;
            byte_index<=0;current_addr<=0;current_data<=0;loaded_words<=0;
        end else begin
            if(push) begin fifo[wp]<={load_addr,load_data};wp<=wp+1'b1;end
            if(pop) begin
                {current_addr,current_data}<=fifo[rp];rp<=rp+1'b1;
                byte_index<=0;prog_wr<=1;state<=1;
            end
            case({push,pop})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:;
            endcase
            if(state==1) begin
                if(prog_ack) prog_wr<=0;
                if(prog_rdy) begin
                    prog_wr<=0;
                    if(!byte_index) begin byte_index<=1;state<=2;end
                    else begin state<=0;loaded_words<=loaded_words+1'b1;end
                end
            end
            if(state==2) begin prog_wr<=1;state<=1;end
`ifdef VERILATOR
            if(push && count==16 && !pop) $fatal(1,"graphics download FIFO overflow");
            if(load_wr && (load_addr[0] || load_addr>=19'h60000))
                $fatal(1,"invalid graphics download address");
`endif
        end
    end
    jtframe_sdram64 #(.AW(22),.HF(1),.SHIFTED(0),
        .BA0_LEN(16),.BA1_LEN(16),.BA2_LEN(16),.BA3_LEN(16),.PROG_LEN(16),
        .BA0_WEN(0),.BA1_WEN(0),.BA2_WEN(0),.BA3_WEN(0),.RFSHCNT(9)
    ) controller (
        .rst(reset),.clk(clk),.init(init),
        .ba0_addr({4'd0,phy_read[18:1]}),.ba1_addr(22'd0),.ba2_addr(22'd0),.ba3_addr(22'd0),
        .rd({3'd0,read_req && !load_busy}),.wr(4'd0),
        .ba0_din(16'd0),.ba1_din(16'd0),.ba2_din(16'd0),.ba3_din(16'd0),
        .ba0_dsn(2'b11),.ba1_dsn(2'b11),.ba2_dsn(2'b11),.ba3_dsn(2'b11),
        .prog_en(load_busy),.prog_addr({4'd0,phy_byte[18:1]}),
        .prog_rd(1'b0),.prog_wr(prog_wr),.prog_din({byte_data,byte_data}),
        .prog_dsn(phy_byte[0] ? 2'b01 : 2'b10),.prog_ba(2'd0),
        .prog_dst(),.prog_dok(),.prog_rdy(prog_rdy),.prog_ack(prog_ack),
        .rfsh(refresh),.ack(ack),.dst(),.dok(),.rdy(rdy),.dout(read_data),
        .sdram_dq(sdram_dq),
`ifdef VERILATOR
        .sdram_din(sdram_din),
`endif
        .sdram_a(sdram_a),.sdram_ba(sdram_ba),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_nwe(sdram_nwe),.sdram_ncas(sdram_ncas),.sdram_nras(sdram_nras),
        .sdram_ncs(sdram_ncs),.sdram_cke(sdram_cke)
    );
endmodule
