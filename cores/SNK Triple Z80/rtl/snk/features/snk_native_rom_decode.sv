// Generated from runtime-rom-layout.json. Candidate ABI, not an engine implementation.
module snk_native_rom_decode(input [7:0] profile,input [24:0] download_addr,
output reg valid,output reg [7:0] region_id,output reg [24:0] region_offset,output reg packed_planes);
always @* begin valid=0;region_id=0;region_offset=0;packed_planes=0;case(profile)
8'd13:begin
if(download_addr>=25'd0 && download_addr<25'd49152)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd114688)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd180224)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd524288)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd655360)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=1;end
if(download_addr>=25'd655360 && download_addr<25'd1179648)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=1;end
if(download_addr>=25'd1179648 && download_addr<25'd1184768)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
if(download_addr>=25'd1245184 && download_addr<25'd1507328)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1245184;packed_planes=0;end
end
8'd11:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd524288)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd655360)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=0;end
if(download_addr>=25'd655360 && download_addr<25'd1179648)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1184768)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
if(download_addr>=25'd1245184 && download_addr<25'd1376256)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1245184;packed_planes=0;end
if(download_addr>=25'd1376256 && download_addr<25'd1384448)begin valid=1;region_id=8'd13;region_offset=download_addr-25'd1376256;packed_planes=0;end
end
8'd12:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd524288)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd655360)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=0;end
if(download_addr>=25'd655360 && download_addr<25'd1179648)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1184768)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
if(download_addr>=25'd1245184 && download_addr<25'd1376256)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1245184;packed_planes=0;end
if(download_addr>=25'd1376256 && download_addr<25'd1384448)begin valid=1;region_id=8'd13;region_offset=download_addr-25'd1376256;packed_planes=0;end
end
8'd16:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd524288)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd655360)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=0;end
if(download_addr>=25'd655360 && download_addr<25'd1179648)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1182720)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
if(download_addr>=25'd1245184 && download_addr<25'd1310720)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1245184;packed_planes=0;end
if(download_addr>=25'd1310720 && download_addr<25'd1314816)begin valid=1;region_id=8'd12;region_offset=download_addr-25'd1310720;packed_planes=0;end
end
8'd5:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd204800)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd278528)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd327680 && download_addr<25'd376832)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd327680;packed_planes=0;end
if(download_addr>=25'd393216 && download_addr<25'd396288)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd393216;packed_planes=0;end
end
8'd2:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd204800)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd270336)begin valid=1;region_id=8'd4;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd327680 && download_addr<25'd335872)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd327680;packed_planes=0;end
if(download_addr>=25'd393216 && download_addr<25'd417792)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd393216;packed_planes=0;end
if(download_addr>=25'd458752 && download_addr<25'd461824)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd458752;packed_planes=0;end
end
8'd0:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd204800)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd270336)begin valid=1;region_id=8'd4;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd327680 && download_addr<25'd335872)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd327680;packed_planes=0;end
if(download_addr>=25'd393216 && download_addr<25'd417792)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd393216;packed_planes=0;end
if(download_addr>=25'd458752 && download_addr<25'd461824)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd458752;packed_planes=0;end
end
8'd1:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd204800)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd270336)begin valid=1;region_id=8'd4;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd327680 && download_addr<25'd335872)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd327680;packed_planes=0;end
if(download_addr>=25'd393216 && download_addr<25'd417792)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd393216;packed_planes=0;end
if(download_addr>=25'd458752 && download_addr<25'd461824)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd458752;packed_planes=0;end
end
8'd3:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd212992)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd270336)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd327680 && download_addr<25'd352256)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd327680;packed_planes=0;end
if(download_addr>=25'd393216 && download_addr<25'd396288)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd393216;packed_planes=0;end
end
8'd4:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd204800)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd270336)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd327680 && download_addr<25'd352256)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd327680;packed_planes=0;end
if(download_addr>=25'd393216 && download_addr<25'd396288)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd393216;packed_planes=0;end
end
8'd15:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd589824)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd589824 && download_addr<25'd1114112)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd589824;packed_planes=0;end
if(download_addr>=25'd1114112 && download_addr<25'd1117184)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1114112;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1310720)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1179648;packed_planes=0;end
end
8'd20:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd655360)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd655360 && download_addr<25'd1179648)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1182720)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
if(download_addr>=25'd1245184 && download_addr<25'd1507328)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1245184;packed_planes=0;end
end
8'd17:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd589824)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd589824 && download_addr<25'd1114112)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd589824;packed_planes=0;end
if(download_addr>=25'd1114112 && download_addr<25'd1117184)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1114112;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1245184)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1179648;packed_planes=0;end
end
8'd19:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd229376)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd524288)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd786432)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=0;end
if(download_addr>=25'd786432 && download_addr<25'd1310720)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd786432;packed_planes=0;end
if(download_addr>=25'd1310720 && download_addr<25'd1313792)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1310720;packed_planes=0;end
if(download_addr>=25'd1376256 && download_addr<25'd1441792)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1376256;packed_planes=0;end
end
8'd14:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd212992)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd393216)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd655360)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=0;end
if(download_addr>=25'd655360 && download_addr<25'd917504)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1182720)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
end
8'd18:begin
if(download_addr>=25'd0 && download_addr<25'd65536)begin valid=1;region_id=8'd0;region_offset=download_addr-25'd0;packed_planes=0;end
if(download_addr>=25'd65536 && download_addr<25'd131072)begin valid=1;region_id=8'd1;region_offset=download_addr-25'd65536;packed_planes=0;end
if(download_addr>=25'd131072 && download_addr<25'd196608)begin valid=1;region_id=8'd2;region_offset=download_addr-25'd131072;packed_planes=0;end
if(download_addr>=25'd196608 && download_addr<25'd212992)begin valid=1;region_id=8'd3;region_offset=download_addr-25'd196608;packed_planes=0;end
if(download_addr>=25'd262144 && download_addr<25'd393216)begin valid=1;region_id=8'd5;region_offset=download_addr-25'd262144;packed_planes=0;end
if(download_addr>=25'd524288 && download_addr<25'd655360)begin valid=1;region_id=8'd6;region_offset=download_addr-25'd524288;packed_planes=0;end
if(download_addr>=25'd655360 && download_addr<25'd917504)begin valid=1;region_id=8'd7;region_offset=download_addr-25'd655360;packed_planes=0;end
if(download_addr>=25'd1179648 && download_addr<25'd1182720)begin valid=1;region_id=8'd9;region_offset=download_addr-25'd1179648;packed_planes=0;end
if(download_addr>=25'd1245184 && download_addr<25'd1376256)begin valid=1;region_id=8'd11;region_offset=download_addr-25'd1245184;packed_planes=0;end
end
default:begin end endcase end endmodule
