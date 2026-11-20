// SPDX-License-Identifier: BSD-3-Clause
// Synthesizable source-compatible affine command path. Indexed surfaces,
// previous-frame presentation and physical memory arbitration are external.
module gs_tc0610(
    input wire clk,reset,query,
    output wire query_ready,
    input wire signed [15:0] rzx,rzy,
    output reg done,
    output wire mem_req,
    output wire [17:0] mem_addr,
    input wire mem_ack,
    input wire [15:0] mem_rdata,
    output wire pixel_valid,
    input wire pixel_ready,
    output wire [8:0] pixel_y,pixel_x,
    output wire [15:0] pixel_index
);
    localparam IDLE=0,LAUNCH=1,WAIT_VERTICES=2,RENDER=3;
    reg [1:0] state;
    reg signed [15:0] saved_x,saved_y;
    reg raster_finished;
    wire vertices_ready,vertices_valid,vertices_empty,raster_ready,raster_done;
    wire [255:0] vertices;
    wire extent_valid,extent_ready;
    wire [8:0] extent_y;
    wire [9:0] start_x,stop_x;
    wire signed [31:0] u,v,du,dv;
    // Quad construction completes before raster arithmetic starts. Share the
    // unchanged binary32 units at their original handshakes, with no new cycle.
    wire raster_owner=state==RENDER;
    wire [1:0] quad_op,raster_op;
    wire [31:0] quad_a,quad_b,raster_a,raster_b;
    wire quad_a_stb,quad_b_stb,quad_z_ack,raster_a_stb,raster_b_stb,raster_z_ack;
    wire [1:0] unit_op=raster_owner ? raster_op : quad_op;
    wire [31:0] unit_a=raster_owner ? raster_a : quad_a;
    wire [31:0] unit_b=raster_owner ? raster_b : quad_b;
    wire unit_a_stb=raster_owner ? raster_a_stb : quad_a_stb;
    wire unit_b_stb=raster_owner ? raster_b_stb : quad_b_stb;
    wire unit_z_ack=raster_owner ? raster_z_ack : quad_z_ack;
    wire [2:0] unit_a_ack,unit_b_ack,unit_valid;
    wire [31:0] unit_z[0:2];
    wire fp_a_ack=unit_a_ack[unit_op],fp_b_ack=unit_b_ack[unit_op];
    wire fp_valid=unit_valid[unit_op];
    wire [31:0] fp_z=unit_z[unit_op];
    assign query_ready=state==IDLE;
    gs_tc0610_vertices #(.EXTERNAL_FP(1)) quad(
        .clk(clk),.reset(reset),.query(state==LAUNCH),.query_ready(vertices_ready),
        .rzx(saved_x),.rzy(saved_y),.valid(vertices_valid),
        .ready(state==WAIT_VERTICES && raster_ready),.empty(vertices_empty),.vertices(vertices),
        .unit_operation(quad_op),.unit_a(quad_a),.unit_b(quad_b),
        .unit_a_stb(quad_a_stb),.unit_b_stb(quad_b_stb),.unit_z_ack(quad_z_ack),
        .unit_a_ack(!raster_owner && fp_a_ack),.unit_b_ack(!raster_owner && fp_b_ack),
        .unit_z_valid(!raster_owner && fp_valid),.unit_z(fp_z));
    gs_tc0610_raster #(.EXTERNAL_FP(1)) raster(
        .clk(clk),.reset(reset),.query(state==WAIT_VERTICES && vertices_valid),
        .query_ready(raster_ready),.empty(vertices_empty),.vertices(vertices),
        .valid(extent_valid),.ready(extent_ready),.done(raster_done),
        .y(extent_y),.start_x(start_x),.stop_x(stop_x),.u(u),.v(v),.du(du),.dv(dv),
        .unit_operation(raster_op),.unit_a(raster_a),.unit_b(raster_b),
        .unit_a_stb(raster_a_stb),.unit_b_stb(raster_b_stb),.unit_z_ack(raster_z_ack),
        .unit_a_ack(raster_owner && fp_a_ack),.unit_b_ack(raster_owner && fp_b_ack),
        .unit_z_valid(raster_owner && fp_valid),.unit_z(fp_z));
    adder addition(
        .clk(clk),.rst(reset),.input_a(unit_a),.input_b(unit_b),
        .input_a_stb(unit_a_stb && unit_op==0),.input_b_stb(unit_b_stb && unit_op==0),
        .input_a_ack(unit_a_ack[0]),.input_b_ack(unit_b_ack[0]),
        .output_z(unit_z[0]),.output_z_stb(unit_valid[0]),.output_z_ack(unit_z_ack && unit_op==0));
    multiplier multiplication(
        .clk(clk),.rst(reset),.input_a(unit_a),.input_b(unit_b),
        .input_a_stb(unit_a_stb && unit_op==1),.input_b_stb(unit_b_stb && unit_op==1),
        .input_a_ack(unit_a_ack[1]),.input_b_ack(unit_b_ack[1]),
        .output_z(unit_z[1]),.output_z_stb(unit_valid[1]),.output_z_ack(unit_z_ack && unit_op==1));
    divider division(
        .clk(clk),.rst(reset),.input_a(unit_a),.input_b(unit_b),
        .input_a_stb(unit_a_stb && unit_op==2),.input_b_stb(unit_b_stb && unit_op==2),
        .input_a_ack(unit_a_ack[2]),.input_b_ack(unit_b_ack[2]),
        .output_z(unit_z[2]),.output_z_stb(unit_valid[2]),.output_z_ack(unit_z_ack && unit_op==2));
    gs_tc0610_texture texture(
        .clk(clk),.reset(reset),.extent_valid(extent_valid),.extent_ready(extent_ready),
        .extent_y(extent_y),.start_x(start_x),.stop_x(stop_x),.u(u),.v(v),.du(du),.dv(dv),
        .mem_req(mem_req),.mem_addr(mem_addr),.mem_ack(mem_ack),.mem_rdata(mem_rdata),
        .pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
        .pixel_y(pixel_y),.pixel_x(pixel_x),.pixel_index(pixel_index));
    always @(posedge clk) begin
        done<=0;
        case(state)
        IDLE: if(query && query_ready) begin saved_x<=rzx;saved_y<=rzy;raster_finished<=0;state<=LAUNCH;end
        LAUNCH: if(vertices_ready) state<=WAIT_VERTICES;
        WAIT_VERTICES: if(vertices_valid && raster_ready) state<=RENDER;
        RENDER: begin
            if(raster_done) raster_finished<=1;
            if((raster_finished || raster_done) && extent_ready) begin done<=1;state<=IDLE;end
        end
        endcase
        if(reset) begin state<=IDLE;done<=0;saved_x<=0;saved_y<=0;raster_finished<=0;end
    end
endmodule
