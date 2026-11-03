// SPDX-License-Identifier: GPL-3.0-or-later
// Relative renderer bytes -> Heavy Unit's one selected flat SDRAM ROM image.
// One acknowledged64-bit request per client may be outstanding. No clocks,
// CPU addresses, CPU Pandora permutation or renderer page ownership change.
module airbustr_video_adapter (
    input logic clk, reset,
    input logic object_req_valid,object_req_full_tile,
    output logic object_req_ready,
    input logic [20:0] object_req_addr,
    output logic object_rsp_valid,object_rsp_last,
    output logic [63:0] object_rsp_data,
    input logic tile_req_valid,
    output logic tile_req_ready,
    input logic [18:0] tile_req_addr,
    output logic tile_rsp_valid,
    output logic [63:0] tile_rsp_data,
    output logic storage_object_req_valid,storage_object_req_full_tile,
    input logic storage_object_req_ready,
    output logic [21:0] storage_object_req_addr,
    input logic storage_object_rsp_valid,storage_object_rsp_last,
    input logic [63:0] storage_object_rsp_data,
    output logic storage_tile_req_valid,
    input logic storage_tile_req_ready,
    output logic [21:0] storage_tile_req_addr,
    input logic storage_tile_rsp_valid,
    input logic [63:0] storage_tile_rsp_data,
    output logic [1:0] pending,
    output logic protocol_error
);
    logic object_slot, tile_slot;
    assign object_slot = !pending[0] || (storage_object_rsp_valid && storage_object_rsp_last);
    assign storage_object_req_full_tile=object_req_full_tile;
    assign object_rsp_last=storage_object_rsp_last;
    assign tile_slot = !pending[1] || storage_tile_rsp_valid;
    assign storage_object_req_addr = 22'h120000 + {2'b0,object_req_addr[19:0]}; // 1 MB sprite region (gfx wraps at 8192 tiles)
    assign storage_tile_req_addr = 22'h0a0000 + {3'b0,tile_req_addr};
    assign storage_object_req_valid = !reset && object_slot && object_req_valid && object_req_addr[2:0] == 0 && (!object_req_full_tile || object_req_addr[6:0]==0);
    assign storage_tile_req_valid = !reset && tile_slot && tile_req_valid && tile_req_addr[2:0] == 0;
    assign object_req_ready = !reset && object_slot && storage_object_req_ready && object_req_addr[2:0] == 0 && (!object_req_full_tile || object_req_addr[6:0]==0);
    assign tile_req_ready = !reset && tile_slot && storage_tile_req_ready && tile_req_addr[2:0] == 0;
    assign object_rsp_valid = !reset && pending[0] && storage_object_rsp_valid;
    assign tile_rsp_valid = !reset && pending[1] && storage_tile_rsp_valid;
    assign object_rsp_data = storage_object_rsp_data;
    assign tile_rsp_data = storage_tile_rsp_data;
    always_ff @(posedge clk) begin
        if(reset) begin pending <= 0; protocol_error <= 0; end
        else begin
            pending[0] <= (pending[0] && !(storage_object_rsp_valid && storage_object_rsp_last)) || (storage_object_req_valid && storage_object_req_ready);
            pending[1] <= (pending[1] && !storage_tile_rsp_valid) || (storage_tile_req_valid && storage_tile_req_ready);
            if((object_req_valid && object_req_addr[2:0] != 0) ||
               (tile_req_valid && tile_req_addr[2:0] != 0) ||
               (storage_object_rsp_valid && !pending[0]) ||
               (storage_tile_rsp_valid && !pending[1])) protocol_error <= 1;
        end
    end
endmodule
