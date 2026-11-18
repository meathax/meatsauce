// One 48 MHz master; three 2 MHz sound chips use the same enable.
// Address/data strobes are captured on master edges, as required by the donors.
module alpha68kn_soundchips (
    input wire clk,reset,io_wr,io_rd,
    input wire [7:0] io_addr,io_data,read_addr,
    output wire [7:0] read_data,
    output wire signed [15:0] fm,
    output wire [9:0] ym_psg,ay1_psg,ay2_psg,
    output wire [7:0] ay1_a,ay1_b,ay1_c,ay2_a,ay2_b,ay2_c,
    output wire ym_irq_n,ym_sample,
    output reg [31:0] ym_writes,ay1_writes,ay2_writes
);
    reg [4:0] phase;
    wire cen=phase==0;
    reg [3:0] ay1_addr,ay2_addr;
    wire [7:0] ym_dout,ay1_dout,ay2_dout;
    wire ym_write=io_wr && io_addr[7:1]==7'h08;
    wire ym_read=io_rd && read_addr[7:1]==7'h08;
    wire ay1_write=io_wr && io_addr==8'h80;
    wire ay2_write=io_wr && io_addr==8'h90;
    // Data readback uses the live query address, independently of last writes.
    assign read_data=read_addr[7:1]==7'h08 ? ym_dout :
                     read_addr==8'h80 ? ay1_dout : read_addr==8'h90 ? ay2_dout : 8'hff;
    always @(posedge clk) begin
        if(reset) begin
            phase<=0;ay1_addr<=0;ay2_addr<=0;
            ym_writes<=0;ay1_writes<=0;ay2_writes<=0;
        end else begin
            phase<=phase==23 ? 0 : phase+1'b1;
            if(io_wr && io_addr==8'h81) ay1_addr<=io_data[3:0];
            if(io_wr && io_addr==8'h91) ay2_addr<=io_data[3:0];
            if(ym_write) ym_writes<=ym_writes+1'b1;
            if(ay1_write || (io_wr && io_addr==8'h81)) ay1_writes<=ay1_writes+1'b1;
            if(ay2_write || (io_wr && io_addr==8'h91)) ay2_writes<=ay2_writes+1'b1;
        end
    end
    // YM2203 preserves its donor's own embedded YM SSG and clock division.
    jt03 #(.SSG_COMP(3'd5)) ym (
        .rst(reset),.clk(clk),.cen(cen),.din(io_data),.addr(io_wr ? io_addr[0] : read_addr[0]),
        .cs_n(!(ym_write || ym_read)),.wr_n(!ym_write),.dout(ym_dout),.irq_n(ym_irq_n),
        .IOA_in(8'hff),.IOB_in(8'hff),.IOA_out(),.IOB_out(),.IOA_oe(),.IOB_oe(),
        .psg_A(),.psg_B(),.psg_C(),.fm_snd(fm),.psg_snd(ym_psg),
        .snd(),.snd_sample(ym_sample),.debug_view()
    );
    // MUTE_NULL_PERIOD=0 is AY period-zero-as-one; SEL=1 gives AY /8 tone clock.
    // Namespaced external core quantizes envelopes to AY16 and uses AY transfer.
    a68n_ay49 #(.MUTE_NULL_PERIOD(0),.CLKDIV(3),.COMP(0),.YM2203_LUMPED(0)) ay1 (
        .rst_n(!reset),.clk(clk),.clk_en(cen),.addr(ay1_addr),.cs_n(!ay1_write),
        .wr_n(!ay1_write),.din(io_data),.sel(1'b1),.dout(ay1_dout),.sound(ay1_psg),
        .A(ay1_a),.B(ay1_b),.C(ay1_c),.sample(),
        .IOA_in(8'hff),.IOB_in(8'hff),.IOA_out(),.IOB_out(),.IOA_oe(),.IOB_oe()
    );
    a68n_ay49 #(.MUTE_NULL_PERIOD(0),.CLKDIV(3),.COMP(0),.YM2203_LUMPED(0)) ay2 (
        .rst_n(!reset),.clk(clk),.clk_en(cen),.addr(ay2_addr),.cs_n(!ay2_write),
        .wr_n(!ay2_write),.din(io_data),.sel(1'b1),.dout(ay2_dout),.sound(ay2_psg),
        .A(ay2_a),.B(ay2_b),.C(ay2_c),.sample(),
        .IOA_in(8'hff),.IOB_in(8'hff),.IOA_out(),.IOB_out(),.IOA_oe(),.IOB_oe()
    );
endmodule
