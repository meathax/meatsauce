// Reset generations invalidate cache entries without a parallel reset vector.
// Generation wrap sweeps the RAM before ready reasserts; zero is never valid.
module gaiapolis_cache_epoch_ram #(parameter AW=11)(
    input wire clk,rst,we,re,
    input wire [AW-1:0] write_addr,read_addr,
    output wire valid,ready
);
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] stamp [0:(1<<AW)-1];
    reg [7:0] generation,read_stamp;
    reg rst_seen,clearing,read_valid;
    reg [AW-1:0] clear_addr;
    integer n;
    initial begin
        generation=8'd1;rst_seen=0;clearing=0;clear_addr=0;read_valid=0;
        for(n=0;n<(1<<AW);n=n+1) stamp[n]=0;
    end
    always @(posedge clk) begin
        rst_seen<=rst;
        if(rst || clearing) read_valid<=0;
        else if(re) read_valid<=1;
        if(rst && !rst_seen && !clearing) begin
            if(generation==8'hff) begin
                generation<=8'd1;clearing<=1;clear_addr<=0;
            end else generation<=generation+8'd1;
        end
        if(clearing) begin
            if(&clear_addr) clearing<=0;
            else clear_addr<=clear_addr+1'b1;
        end
    end
    always @(posedge clk) begin
        if(clearing) stamp[clear_addr]<=8'd0;
        else if(we && !rst) stamp[write_addr]<=generation;
        if(re) read_stamp<=stamp[read_addr];
    end
    assign ready=!rst && !clearing;
    assign valid=ready && read_valid && read_stamp==generation;
endmodule
