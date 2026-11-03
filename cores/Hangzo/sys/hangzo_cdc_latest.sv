// SPDX-License-Identifier: GPL-3.0-or-later
// One acknowledged, coherent packet. Source retains ownership until ACK.
// There is deliberately no game reset: independently resetting one side must
// not forget an accepted packet. FPGA configuration initializes both sides.
module hangzo_cdc_latest #(parameter WIDTH=1)(
    input wire src_clk,src_valid,
    input wire [WIDTH-1:0] src_data,
    output wire src_ready,
    input wire dst_clk,dst_ready,
    (* preserve, dont_merge *) output reg [WIDTH-1:0] dst_data='0,
    output reg dst_strobe=0
);
    (* preserve, dont_merge *) reg [WIDTH-1:0] held='0;
    (* preserve, dont_merge *) reg send=0,ack=0;
    (* preserve, dont_merge, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg ack_meta=0,ack_sync=0;
    (* preserve, dont_merge, altera_attribute="-name SYNCHRONIZER_IDENTIFICATION FORCED" *) reg send_meta=0,send_sync=0;
    assign src_ready=ack_sync==send;
    always @(posedge src_clk) begin
        ack_meta<=ack;
        ack_sync<=ack_meta;
        if(src_valid && src_ready) begin
            held<=src_data;
            send<=~send;
        end
    end
    always @(posedge dst_clk) begin
        send_meta<=send;
        send_sync<=send_meta;
        dst_strobe<=0;
        if(send_sync!=ack && dst_ready) begin
            dst_data<=held;
            dst_strobe<=1;
            ack<=send_sync;
        end
    end
endmodule
