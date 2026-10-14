// SPDX-License-Identifier: GPL-3.0-or-later
// Functional pin-event storage; no CPU arbitration or electrical timing model.
module n8080_dram_storage (
    input wire clk, reset,
    input wire ras_n, cas_n, we_n,
    input wire [6:0] mux_address,
    input wire [7:0] di,
    output reg [7:0] do_data,
    output reg do_valid,
    output reg read_event, write_event, ignored_cas_event, unsupported_event
);
    reg previous_ras_n, previous_cas_n, previous_we_n;
    reg [6:0] row_address, column_address;
    reg row_valid, column_valid, read_pending;
    wire ras_fall = previous_ras_n & ~ras_n;
    wire ras_rise = ~previous_ras_n & ras_n;
    wire cas_fall = previous_cas_n & ~cas_n;
    wire cas_rise = ~previous_cas_n & cas_n;
    wire we_fall = previous_we_n & ~we_n;

    // A coincident write/CAS edge has no qualified early/late electrical order.
    wire unsupported = cas_fall & ~ras_n &
                       (ras_fall | (row_valid & we_fall));
    wire accepted_cas = cas_fall & ~ras_n & row_valid &
                        ~ras_fall & ~unsupported;
    wire early_write = accepted_cas & ~we_n;
    wire late_write = we_fall & ~cas_fall & ~ras_fall &
                      ~ras_n & ~cas_n & row_valid & column_valid;
    wire memory_write = ~reset & (early_write | late_write);
    wire memory_read = ~reset & accepted_cas & we_n;
    wire [13:0] memory_address = accepted_cas ?
                                {mux_address, row_address} :
                                {column_address, row_address};

    // One synchronous port. Reset releases control/output; it never erases RAM.
    (* ramstyle = "M10K" *) reg [7:0] memory [0:16383];
    reg [7:0] memory_read_data;
    always @(posedge clk) begin
        if (memory_write) memory[memory_address] <= di;
        else if (memory_read) memory_read_data <= memory[memory_address];
    end

    always @(posedge clk) begin
        previous_ras_n <= ras_n;
        previous_cas_n <= cas_n;
        previous_we_n <= we_n;
        if (reset) begin
            row_address <= 0;
            column_address <= 0;
            row_valid <= 0;
            column_valid <= 0;
            read_pending <= 0;
            do_data <= 0;
            do_valid <= 0;
            read_event <= 0;
            write_event <= 0;
            ignored_cas_event <= 0;
            unsupported_event <= 0;
        end else begin
            read_event <= memory_read;
            write_event <= memory_write;
            ignored_cas_event <= cas_fall & ~unsupported &
                                 (ras_n | ~row_valid | ras_fall);
            unsupported_event <= unsupported;
            read_pending <= memory_read;
            if (read_pending && !cas_n && !cas_rise && !cas_fall) begin
                do_data <= memory_read_data;
                do_valid <= 1;
            end
            if (cas_fall) begin
                do_valid <= 0;
                column_valid <= accepted_cas;
                if (accepted_cas) column_address <= mux_address;
            end
            if (cas_rise) begin
                do_valid <= 0;
                read_pending <= 0;
                column_valid <= 0;
            end
            // RAS release closes transactions, but DO remains live until CAS rise.
            if (ras_rise) begin
                row_valid <= 0;
                column_valid <= 0;
            end
            if (ras_fall) begin
                row_address <= mux_address;
                row_valid <= 1;
                column_valid <= 0;
                read_pending <= 0;
            end
            if (unsupported) begin
                do_valid <= 0;
                read_pending <= 0;
                column_valid <= 0;
                if (ras_fall) row_valid <= 0;
            end
        end
    end
endmodule
