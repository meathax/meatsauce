// SPDX-License-Identifier: BSD-3-Clause
// Held front-word dual-clock FIFO. Gray pointers cross through two registers;
// Whole-word writes and the synchronous next-pointer read infer block RAM.
// Storage is selectable without changing the synchronous held-front-word contract.
module gs_async_fifo #(parameter DW=32,AW=3,parameter RAMSTYLE="MLAB, no_rw_check")(
    input wire wr_clk,wr_reset,wr_en,input wire [DW-1:0] wr_data,output wire full,
    input wire rd_clk,rd_reset,rd_en,output wire [DW-1:0] rd_data,output wire empty,
    output wire [AW:0] rd_level
);
    (* ramstyle=RAMSTYLE, max_depth=256 *) reg [DW-1:0] memory[0:(1<<AW)-1];
    reg [DW-1:0] q;
    reg [AW:0] write_binary,write_gray,read_binary,read_gray;
    (* altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg [AW:0] read_s1,read_s2,write_s1,write_s2;
    wire push=wr_en && !full,pop=rd_en && !empty;
    wire [AW:0] next_write=write_binary+push,next_read=read_binary+pop;
    wire [AW:0] next_write_gray=(next_write>>1)^next_write;
    wire [AW:0] next_read_gray=(next_read>>1)^next_read;
    assign full=write_gray=={~read_s2[AW:AW-1],read_s2[AW-2:0]};
    assign empty=read_gray==write_s2;
    assign rd_data=q;
    function automatic [AW:0] ungray(input [AW:0] gray);
        integer bit_number;
        begin
            ungray[AW]=gray[AW];
            for(bit_number=AW-1;bit_number>=0;bit_number=bit_number-1)ungray[bit_number]=ungray[bit_number+1]^gray[bit_number];
        end
    endfunction
    assign rd_level=ungray(write_s2)-read_binary;
    always @(posedge wr_clk)begin
        if(push)memory[write_binary[AW-1:0]]<=wr_data;
        write_binary<=next_write;write_gray<=next_write_gray;
        read_s1<=read_gray;read_s2<=read_s1;
        if(wr_reset)begin write_binary<=0;write_gray<=0;read_s1<=0;read_s2<=0;end
    end
    always @(posedge rd_clk)begin
        q<=memory[next_read[AW-1:0]];
        read_binary<=next_read;read_gray<=next_read_gray;
        write_s1<=write_gray;write_s2<=write_s1;
        if(rd_reset)begin read_binary<=0;read_gray<=0;write_s1<=0;write_s2<=0;end
    end
endmodule
