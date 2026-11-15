// SPDX-License-Identifier: GPL-3.0-or-later
// Factory initialization is an image-load operation, not a soft-reset action.
module gaiapolis_nvram_init (
    input logic clk, reset, image_load,
    input logic restore_session, restore_write,
    input logic [7:0] seed_data,
    output logic [6:0] seed_addr,
    input logic [6:0] eeprom_addr,
    input logic [7:0] eeprom_data,
    input logic eeprom_write,
    output logic [6:0] nvram_addr,
    output logic [7:0] nvram_data,
    output logic nvram_write,
    output logic hold_reset, init_busy, initialized, seed_active
);
    // These power-up values are retained across the external soft reset.
    logic seed_pending;
    logic restore_active;
    logic seed_phase;
    initial begin
        seed_pending = 1'b1;
        restore_active = 1'b0;
        seed_phase = 1'b0;
        seed_active = 1'b0;
        seed_addr = 7'd0;
    end

    always_comb begin
        init_busy = seed_pending || seed_active || restore_active;
        initialized = !seed_pending;
        hold_reset = reset || init_busy;
        nvram_addr = seed_active ? seed_addr : eeprom_addr;
        nvram_data = seed_active ? seed_data : eeprom_data;
        nvram_write = 1'b0;
        if (!reset && !image_load && !restore_session)
            nvram_write = seed_active ? seed_phase :
                          (!seed_pending && !restore_active && eeprom_write);
    end

    always @(posedge clk) begin
        if (!restore_session) restore_active <= 1'b0;
        if (image_load) begin
            seed_pending <= 1'b1;
            seed_active <= 1'b0;
            seed_phase <= 1'b0;
            seed_addr <= 7'd0;
            restore_active <= 1'b0;
        end else if (restore_session) begin
            // The generated dump mux owns the BRAM during both reads and
            // writes. A read must not consume an unwritten factory byte.
            seed_phase <= 1'b0;
            if (restore_write) begin
                seed_pending <= 1'b0;
                seed_active <= 1'b0;
                restore_active <= 1'b1;
            end
        end else if (reset) begin
            seed_active <= seed_pending;
            seed_phase <= 1'b0;
            seed_addr <= 7'd0;
        end else if (!seed_active && seed_pending) begin
            seed_active <= 1'b1;
            seed_phase <= 1'b0;
            seed_addr <= 7'd0;
        end else if (seed_active) begin
            // One settling cycle per synchronous seed read, then one write.
            seed_phase <= !seed_phase;
            if (seed_phase) begin
                if (&seed_addr) begin
                    seed_active <= 1'b0;
                    seed_pending <= 1'b0;
                    seed_phase <= 1'b0;
                end else seed_addr <= seed_addr + 7'd1;
            end
        end
    end
endmodule
