// SPDX-License-Identifier: GPL-3.0-or-later
// Registered adapters around the staged M92/Sorgelig SDRAM controller.
// One outstanding request per client; addresses are selected-set byte offsets.
// Split DQ is joined to physical inout pins only at the emu boundary.
module heavyunit_sdram (
    input logic clk, reset, download_active,
    output logic initialized, drained,
    input logic cpu_req_valid,
    output logic cpu_req_ready,
    input logic [24:0] cpu_req_addr,
    output logic cpu_rsp_valid,
    output logic [7:0] cpu_rsp_data,
    output logic [31:0] cpu_rsp_line_data,
    input logic object_req_valid,
    input logic object_req_full_tile,
    output logic object_req_ready,
    input logic [24:0] object_req_addr, // 8-byte aligned
    output logic object_rsp_valid,
    output logic object_rsp_last,
    output logic [63:0] object_rsp_data,
    input logic tile_req_valid,
    output logic tile_req_ready,
    input logic [24:0] tile_req_addr, // 8-byte aligned
    output logic tile_rsp_valid,
    output logic [63:0] tile_rsp_data,
    input logic load_req_valid,
    output logic load_req_ready,
    input logic [24:0] load_req_addr, // even byte address
    input logic [15:0] load_req_data,
    input logic [1:0] load_req_be,
    output logic load_rsp_valid,
    input logic [15:0] dq_in,
    output logic [15:0] dq_out,
    output logic dq_oe,
    output logic [12:0] sdram_addr,
    output logic [1:0] sdram_bank,
    output logic sdram_dqml, sdram_dqmh,
    output logic sdram_ncs, sdram_nwe, sdram_nras, sdram_ncas,
    output logic sdram_cke, sdram_clk
);
    typedef enum logic [2:0] {IDLE, LOOKUP, WAIT_DATA, GAP} cpu_state_t;
    typedef enum logic [1:0] {PORT_IDLE, PORT_WAIT, PORT_GAP} port_state_t;
    cpu_state_t cpu_state;
    port_state_t object_state, tile_state, load_state;
    logic [25:0] cpu_addr, object_addr, tile_addr, load_addr;
    logic cpu_req, object_req, tile_req, load_req;
    logic cpu_done, object_done, tile_done, load_done;
    logic object_stream,object_beat_valid,object_beat_last;
    logic [31:0] cpu_data;
    logic [63:0] object_data, tile_data;
    logic [63:0] unused_ch3_data;
    logic [15:0] load_data;
    logic [1:0] load_be;
    logic [1:0] cpu_offset;
    logic [5:0] cpu_index;
    logic [16:0] cpu_tag, lookup_tag;
    logic [31:0] lookup_data;
    logic lookup_valid;
    logic [63:0] cache_valid;
    logic [16:0] cache_tag [0:63];
    logic [31:0] cache_data [0:63];

    assign cpu_req_ready = initialized && !reset && !download_active && cpu_state == IDLE;
    assign object_req_ready = initialized && !reset && !download_active && object_state == PORT_IDLE && object_req_addr[2:0] == 0 && (!object_req_full_tile || object_req_addr[6:0]==0);
    assign tile_req_ready = initialized && !reset && !download_active && tile_state == PORT_IDLE && tile_req_addr[2:0] == 0;
    assign load_req_ready = initialized && !reset && download_active && load_state == PORT_IDLE && !load_req_addr[0];
    assign drained = initialized && cpu_state == IDLE && object_state == PORT_IDLE &&
        tile_state == PORT_IDLE && load_state == PORT_IDLE;

    heavyunit_sdram_controller controller (
        .init(reset), .clk, .doRefresh(1'b0), .initialized,
        .dq_in, .dq_out, .dq_oe,
        .SDRAM_A(sdram_addr), .SDRAM_BA(sdram_bank), .SDRAM_DQML(sdram_dqml),
        .SDRAM_DQMH(sdram_dqmh), .SDRAM_nCS(sdram_ncs), .SDRAM_nWE(sdram_nwe),
        .SDRAM_nRAS(sdram_nras), .SDRAM_nCAS(sdram_ncas), .SDRAM_CKE(sdram_cke),
        .SDRAM_CLK(sdram_clk),
        .ch1_addr(cpu_addr), .ch1_dout(cpu_data), .ch1_req(cpu_req), .ch1_ready(cpu_done),
        .ch2_addr(object_addr), .ch2_dout(object_data), .ch2_req(object_req), .ch2_ready(object_done), .ch2_stream(object_stream), .ch2_beat_valid(object_beat_valid), .ch2_beat_last(object_beat_last),
        .ch3_addr(load_addr), .ch3_dout(unused_ch3_data), .ch3_din(load_data), .ch3_be(load_be),
        .ch3_req(load_req), .ch3_rnw(1'b0), .ch3_ready(load_done),
        .ch4_addr(tile_addr), .ch4_dout(tile_data), .ch4_req(tile_req), .ch4_ready(tile_done)
    );

    always_ff @(posedge clk) begin
        cpu_rsp_valid <= 1'b0;
        object_rsp_valid <= 1'b0;
        object_rsp_last <= 1'b0;
        tile_rsp_valid <= 1'b0;
        load_rsp_valid <= 1'b0;
        if (reset) begin
            cpu_state <= IDLE;
            object_state <= PORT_IDLE; tile_state <= PORT_IDLE; load_state <= PORT_IDLE;
            cpu_req <= 0; object_req <= 0; tile_req <= 0; load_req <= 0;
            object_stream<=0;
            cpu_addr <= 0; object_addr <= 0; tile_addr <= 0; load_addr <= 0;
            cpu_offset <= 0; cpu_index <= 0; cpu_tag <= 0;
            lookup_tag <= 0; lookup_data <= 0; lookup_valid <= 0;
            cache_valid <= 0;
            cpu_rsp_line_data <= 0;
            cpu_rsp_data <= 0; object_rsp_data <= 0; tile_rsp_data <= 0;
            load_data <= 0; load_be <= 0;
        end else begin
            case (cpu_state)
                IDLE: if (cpu_req_valid && cpu_req_ready) begin
                    cpu_addr <= {2'd0,cpu_req_addr[24:2],1'b0};
                    cpu_offset <= cpu_req_addr[1:0];
                    cpu_index <= cpu_req_addr[7:2];
                    cpu_tag <= cpu_req_addr[24:8];
                    lookup_data <= cache_data[cpu_req_addr[7:2]];
                    lookup_tag <= cache_tag[cpu_req_addr[7:2]];
                    lookup_valid <= cache_valid[cpu_req_addr[7:2]];
                    cpu_state <= LOOKUP;
                end
                LOOKUP: begin
                    if (lookup_valid && lookup_tag == cpu_tag && !download_active) begin
                        cpu_rsp_data <= lookup_data[8*cpu_offset +: 8];
                        cpu_rsp_line_data <= lookup_data;
                        cpu_rsp_valid <= 1'b1;
                        cpu_state <= GAP;
                    end else begin
                        cpu_req <= 1'b1;
                        cpu_state <= WAIT_DATA;
                    end
                end
                WAIT_DATA: if (cpu_done) begin
                    cpu_req <= 1'b0;
                    cpu_rsp_data <= cpu_data[8*cpu_offset +: 8];
                    cpu_rsp_line_data <= cpu_data;
                    cpu_rsp_valid <= 1'b1;
                    cache_data[cpu_index] <= cpu_data;
                    cache_tag[cpu_index] <= cpu_tag;
                    cache_valid[cpu_index] <= 1'b1;
                    cpu_state <= GAP;
                end
                GAP: cpu_state <= IDLE;
                default: cpu_state <= IDLE;
            endcase
            case (object_state)
                PORT_IDLE: if (object_req_valid && object_req_ready) begin
                    object_addr <= {2'd0,object_req_addr[24:3],2'd0};
                    object_req <= 1'b1; object_stream<=object_req_full_tile; object_state <= PORT_WAIT;
                end
                PORT_WAIT: if (object_beat_valid) begin
                    object_rsp_data <= object_data; object_rsp_valid <= 1'b1; object_rsp_last<=object_beat_last;
                    if(object_beat_last)begin object_req<=1'b0;object_state<=PORT_GAP;end
                end
                PORT_GAP: object_state <= PORT_IDLE;
                default: object_state <= PORT_IDLE;
            endcase
            case (tile_state)
                PORT_IDLE: if (tile_req_valid && tile_req_ready) begin
                    tile_addr <= {2'd0,tile_req_addr[24:3],2'd0};
                    tile_req <= 1'b1; tile_state <= PORT_WAIT;
                end
                PORT_WAIT: if (tile_done) begin
                    tile_rsp_data <= tile_data; tile_rsp_valid <= 1'b1;
                    tile_req <= 1'b0; tile_state <= PORT_GAP;
                end
                PORT_GAP: tile_state <= PORT_IDLE;
                default: tile_state <= PORT_IDLE;
            endcase
            case (load_state)
                PORT_IDLE: if (load_req_valid && load_req_ready) begin
                    load_addr <= {2'd0,load_req_addr[24:1]};
                    load_data <= load_req_data; load_be <= load_req_be;
                    load_req <= 1'b1; load_state <= PORT_WAIT;
                end
                PORT_WAIT: if (load_done) begin
                    load_rsp_valid <= 1'b1;
                    load_req <= 1'b0; load_state <= PORT_GAP;
                end
                PORT_GAP: load_state <= PORT_IDLE;
                default: load_state <= PORT_IDLE;
            endcase
            // Loading invalidates every program line, including any miss that
            // was accepted just before game reset/download began.
            if (download_active) cache_valid <= 64'd0;
        end
    end
endmodule
