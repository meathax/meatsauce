`ifndef ARGUS_TEST_ENTRY_FEATURE
`define ARGUS_TEST_ENTRY_FEATURE
// Establish the cabinet pin before reset, then retain it until the actual
// accepted SYSTEM read. Test mode suppresses persistence until normal reset.
module argus_test_entry #(parameter integer RESET_CYCLES=54000)(
    input logic clk_sys,session_reset,normal_reset,test_request,
    input logic [1:0] game_id,
    input logic input_read,
    input logic [15:0] input_addr,
    input logic [7:0] input_data,
    output logic test_hold,test_reset,test_mode
);
    localparam integer CW=$clog2(RESET_CYCLES+1);
    logic arm;
    logic [CW-1:0] ticks;
    wire cabinet_seen=game_id==2 && input_read &&
                      input_addr==16'hc000 && !input_data[5];
    assign test_reset=ticks!=0;
    initial begin arm=0;ticks=0;test_hold=0;test_mode=0;end
    always_ff @(posedge clk_sys) begin
        if(session_reset || normal_reset) begin
            arm<=0;ticks<=0;test_hold<=0;test_mode<=0;
        end else begin
            if(ticks!=0)ticks<=ticks-1'b1;
            if(arm)begin arm<=0;ticks<=CW'(RESET_CYCLES);end
            if(test_request && game_id==2)begin
                test_hold<=1;test_mode<=1;arm<=1;
            end
            if(test_hold && !arm && ticks==0 && cabinet_seen)test_hold<=0;
        end
    end
endmodule
`endif
