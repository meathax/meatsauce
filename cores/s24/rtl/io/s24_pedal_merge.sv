module s24_pedal_merge (
    input  logic       hotrod_io,
    input  logic [3:0] button1,
    input  logic [7:0] paddle0,
    input  logic [7:0] paddle1,
    input  logic [7:0] paddle2,
    input  logic [7:0] paddle3,
    output logic [7:0] pedal0,
    output logic [7:0] pedal1,
    output logic [7:0] pedal2,
    output logic [7:0] pedal3
);
    always_comb begin
        pedal0 = hotrod_io && button1[0] ? 8'hff : paddle0;
        pedal1 = hotrod_io && button1[1] ? 8'hff : paddle1;
        pedal2 = hotrod_io && button1[2] ? 8'hff : paddle2;
        pedal3 = hotrod_io && button1[3] ? 8'hff : paddle3;
    end
endmodule
