// MAME0.289 device_rom_interface<21>, dirom.ipp66-94 mirrors power-of-two
// ROM regions over high bits; canonical Y8950 configurations have no custom map.
// This is an address-only boundary. Chip request/reply timing remains unchanged.
module snk_sample_rom_mask(input [7:0] profile,input [20:0] raw_addr,
 output reg [20:0] masked_addr,output reg supported);
 always @*begin
  supported=1;
  case(profile)
   8'd13,8'd20:masked_addr={3'd0,raw_addr[17:0]};
   8'd11,8'd12,8'd15,8'd14,8'd18:masked_addr={4'd0,raw_addr[16:0]};
   8'd16,8'd17,8'd19:masked_addr={5'd0,raw_addr[15:0]};
   default:begin supported=0;masked_addr=0;end
  endcase
 end
endmodule
