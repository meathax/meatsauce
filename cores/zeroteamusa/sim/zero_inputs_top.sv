module zero_inputs_top (
    input wire clk,reset,
    input wire [10:0] ps2_key,
    input wire [15:0] pad0,pad1,pad2,pad3,system_config,
    output wire [7:0] p1,p2,p3,p4,coin,
    output wire [15:0] system_port
);
    wire [15:0] k0,k1,k2,k3;
    wire [15:0] j0=pad0|k0,j1=pad1|k1,j2=pad2|k2,j3=pad3|k3;
    wire [15:0] all_joy=j0|j1|j2|j3;
    ZeroTeam_keyboard keyboard (.clk(clk),.reset(reset),.ps2_key(ps2_key),
        .joy0(k0),.joy1(k1),.joy2(k2),.joy3(k3));
    ZeroTeam_inputs ports (.joy0(j0),.joy1(j1),.joy2(j2),.joy3(j3),
        .system_config(system_config),.service_credit(all_joy[13]),.service_test(all_joy[14]),
        .p1(p1),.p2(p2),.p3(p3),.p4(p4),.coin(coin),.system_port(system_port));
endmodule
