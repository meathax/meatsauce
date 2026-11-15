// SPDX-License-Identifier: GPL-3.0-or-later
// Work-RAM high-score persistence, adapted from the pinned Violent Storm donor.
// MAME 0.289: 60f801..60f899, with readiness bytes 00 / 29 / 00.
// Shadow storage is 128 big-endian words; word 127 contains the valid marker.
// Transport owns that storage separately. This module never restores before
// the game's initialization and an acknowledged transaction-safe pause.
module gaiapolis_hiscore (
    input wire monster,
    input              clk,
    input              rst,
    input              restore_inhibit,
    input              cpu_commit,
    input       [23:0] cpu_byte_addr,
    input       [15:0] cpu_data,
    input       [ 1:0] cpu_byte_we,
    (* preserve *) output reg pause_request,
    input              pause_safe,
    output             ram_request,
    output reg  [14:0] ram_addr,
    output reg  [15:0] ram_data,
    output reg  [ 1:0] ram_we,
    input              ram_ack,
    output reg  [ 6:0] hs_addr,
    output reg  [15:0] hs_data,
    output reg  [ 1:0] hs_we,
    input       [15:0] hs_dout,
    output reg         hs_dirty,
    output reg         shadow_valid,
    output reg         table_initialized,
    output reg  [ 7:0] restored_words,
    output reg         boundary_fault,
    output             boot_ready,
    output reg  [12:0] ram_row,
    output reg  [ 2:0] ram_lane
);
    wire [23:0] FIRST_WORD = monster ? 24'h600700 : 24'h60f800;
    wire [23:0] LAST_WORD = monster ? 24'h600798 : 24'h60f898;
    localparam [23:0] MARK_WORD  = 24'h60f896;
    localparam [15:0] MAGIC      = 16'ha55a;
    typedef enum logic [3:0] {
        S_BOOT, S_MAGIC,
        S_WAIT, S_QUIESCE, S_READ, S_WRITE, S_DONE, S_FAULT
    } state_t;
    state_t state;
    reg [7:0] first_seen, mark_seen, last_seen;
    reg [6:0] index;
    reg [1:0] delay_count;
    reg mirror;
    (* preserve *) reg ram_pending;
    wire table_word = !cpu_byte_addr[0] && cpu_byte_addr >= FIRST_WORD &&
                      cpu_byte_addr <= LAST_WORD;
    wire [1:0] table_we = cpu_byte_we &
                         (cpu_byte_addr == FIRST_WORD ? 2'b01 : 2'b11);
    wire table_commit = cpu_commit && table_word && |table_we;
    wire [6:0] table_index = cpu_byte_addr[7:1];
    wire initialized_signature = first_seen == (monster ? 8'h02 : 8'h00) &&
                                 (monster || mark_seen == 8'h29) &&
                                 last_seen == (monster ? 8'he8 : 8'h00);
    assign ram_request = ram_pending && pause_safe && pause_request;
    assign boot_ready = state == S_WAIT || state == S_QUIESCE ||
                        state == S_READ || state == S_WRITE || state == S_DONE;

    always @(posedge clk) begin
        hs_we <= 2'b00;
        hs_dirty <= 1'b0;
        if (rst) begin
            state <= S_BOOT;
            first_seen <= 8'hff;
            mark_seen <= 8'hff;
            last_seen <= 8'hff;
            index <= 7'd0;
            delay_count <= 2'd0;
            mirror <= 1'b0;
            ram_pending <= 1'b0;
            pause_request <= 1'b0;
            ram_addr <= 15'd0;
            ram_row <= 13'd0;
            ram_lane <= 3'd0;
            ram_data <= 16'd0;
            ram_we <= 2'b00;
            hs_addr <= 7'd0;
            hs_data <= 16'd0;
            shadow_valid <= 1'b0;
            table_initialized <= 1'b0;
            restored_words <= 8'd0;
            boundary_fault <= 1'b0;
        end else begin
            if (table_commit) begin
                if (cpu_byte_addr == FIRST_WORD && table_we[0])
                    first_seen <= cpu_data[7:0];
                if (cpu_byte_addr == MARK_WORD && table_we[1])
                    mark_seen <= cpu_data[15:8];
                if (cpu_byte_addr == LAST_WORD && table_we[0])
                    last_seen <= cpu_data[7:0];
            end
            case (state)
                S_BOOT: begin
                    hs_addr <= 7'd127;
                    delay_count <= 2'd3;
                    state <= S_MAGIC;
                end
                S_MAGIC: if (delay_count != 0) delay_count <= delay_count - 2'd1;
                         else begin
                    // The marker validates the saved container. The live POST
                    // signature gates restoration, not the mutable saved data.
                    shadow_valid <= hs_dout == MAGIC;
                    mirror <= hs_dout != MAGIC;
                    state <= S_WAIT;
                end
                S_WAIT: begin
                    if (mirror && table_commit) begin
                        hs_addr <= table_index;
                        hs_data <= cpu_data;
                        hs_we <= table_we;
                    end
                    // Let the last initializing write publish before acting.
                    if (initialized_signature && !table_commit && !restore_inhibit) begin
                        table_initialized <= 1'b1;
                        if (shadow_valid) begin
                            pause_request <= 1'b1;
                            state <= S_QUIESCE;
                        end else begin
                            hs_addr <= 7'd127;
                            hs_data <= MAGIC;
                            hs_we <= 2'b11;
                            hs_dirty <= 1'b1;
                            shadow_valid <= 1'b1;
                            state <= S_DONE;
                        end
                    end
                end
                S_QUIESCE: if (pause_safe) begin
                    index <= 7'd0;
                    // Track the parity bank geometry with the same index.
                    // These are quotient/remainder of the first word by five.
                    ram_row <= monster ? 13'd179 : 13'd6348;
                    ram_lane <= monster ? 3'd1 : 3'd4;
                    hs_addr <= 7'd0;
                    delay_count <= 2'd3;
                    state <= S_READ;
                end
                S_READ: if (!pause_safe) begin
                    boundary_fault <= 1'b1;
                    ram_pending <= 1'b0;
                    state <= S_FAULT;
                end else if (delay_count != 0) delay_count <= delay_count - 2'd1;
                else begin
                    ram_addr <= (monster ? 15'h0380 : 15'h7c00) + {8'd0,index};
                    ram_data <= hs_dout;
                    ram_we <= index == 7'd0 ? 2'b01 : 2'b11;
                    ram_pending <= 1'b1;
                    state <= S_WRITE;
                end
                S_WRITE: if (!pause_safe) begin
                    boundary_fault <= 1'b1;
                    ram_pending <= 1'b0;
                    state <= S_FAULT;
                end else if (ram_ack && ram_pending) begin
                    restored_words <= restored_words + 8'd1;
                    ram_pending <= 1'b0;
                    if (index == 7'd76) begin
                        mirror <= 1'b1;
                        pause_request <= 1'b0;
                        state <= S_DONE;
                    end else begin
                        index <= index + 7'd1;
                        if (ram_lane == 3'd4) begin
                            ram_row <= ram_row + 13'd1;
                            ram_lane <= 3'd0;
                        end else ram_lane <= ram_lane + 3'd1;
                        hs_addr <= index + 7'd1;
                        delay_count <= 2'd3;
                        state <= S_READ;
                    end
                end
                S_DONE: if (table_commit) begin
                    hs_addr <= table_index;
                    hs_data <= cpu_data;
                    hs_we <= table_we;
                    hs_dirty <= 1'b1;
                end
                S_FAULT: begin
                    // Retain the hold after a broken ownership contract.
                    pause_request <= 1'b1;
                    ram_pending <= 1'b0;
                end
                default: state <= S_BOOT;
            endcase
        end
    end
endmodule
