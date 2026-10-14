// MAME-compatible logical System 24 floppy controller. The image is a flat,
// writable byte array in SDRAM; a multiple-sector command transfers one whole
// physical side/track, matching segas24.cpp.
module s24_fdc (
    input  logic        clk,
    input  logic        reset,
    input  logic [15:0] track_size,
    input  logic        index_pulse,
    input  logic        bus_rd,
    input  logic        bus_wr,
    input  logic [2:0]  bus_addr,
    input  logic [7:0]  bus_din,
    output logic [7:0]  bus_dout,
    output logic        bus_wait,
    output logic        media_req,
    output logic        media_wr,
    output logic [26:0] media_addr,
    output logic [7:0]  media_wdata,
    input  logic [7:0]  media_rdata,
    input  logic        media_ack
);
    logic [3:0] mode;
    logic [5:0] status_upper;
    logic [7:0] track, sector, data_reg, physical_track;
    logic irq, drq;
    logic [15:0] span, position;
    logic [26:0] track_base;
    logic bus_seen, media_ack_seen;
    logic transfer_busy;

    assign transfer_busy = (span != 16'd0);

    function automatic logic [26:0] image_track_offset(
        input logic [15:0] bytes_per_track,
        input logic [8:0] track_and_side
    );
        logic [31:0] product;
        begin
            product = bytes_per_track * track_and_side;
            image_track_offset = product[26:0];
        end
    endfunction

    always_comb begin
        // Assert wait on the first access cycle as well as while SDRAM is
        // active, so the CPU cannot acknowledge stale data_reg.
        if (track_size==0) begin
            bus_wait=1'b0;
            bus_dout=8'hff;
        end else begin
            bus_wait = (media_req &&
                        !(bus_rd && bus_addr == 3 && bus_seen && mode == 4'h9)) |
                       (bus_rd && bus_addr == 3 && drq && mode == 4'h9 && !bus_seen) |
                       (bus_wr && bus_addr == 3 && drq && mode == 4'hb && !bus_seen);
            case (bus_addr)
                3'd0: bus_dout = {status_upper,drq,transfer_busy};
                3'd1: bus_dout = track;
                3'd2: bus_dout = sector;
                3'd3: bus_dout = data_reg;
                3'd4: bus_dout = 8'h90 | (irq ? 8'h02 : 8'h00) |
                                 (drq ? 8'h01 : 8'h00) |
                                 (physical_track != 8'd0 ? 8'h40 : 8'h00) |
                                 (index_pulse ? 8'h20 : 8'h00);
                default: bus_dout = 8'hff;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            mode <= 0; status_upper <= 0; track <= 0; sector <= 0;
            data_reg <= 0; physical_track <= 0; irq <= 0; drq <= 0;
            span <= 0; position <= 0; track_base <= 0;
            media_req <= 0; media_wr <= 0; media_addr <= 0;
            media_wdata <= 0; bus_seen <= 0; media_ack_seen <= 0;
        end else begin
            if (!bus_rd && !bus_wr) bus_seen <= 1'b0;
            if (!media_ack) media_ack_seen <= 1'b0;

            // Accept exactly one response for each outstanding request.  The
            // SDRAM bridge normally pulses media_ack, but qualifying it keeps
            // a stretched acknowledgement from consuming multiple bytes.
            if (media_ack && media_req && !media_ack_seen) begin
                media_ack_seen <= 1'b1;
                media_req <= 1'b0;
                if (!media_wr) begin
                    data_reg <= media_rdata;
                    drq <= 1'b1;
                end else begin
                    if (span == 16'd1) begin
                        span <= 0;
                        drq <= 1'b0;
                        status_upper <= 0;
                        irq <= 1'b1;
                    end else begin
                        span <= span - 1'd1;
                        position <= position + 1'd1;
                    end
                end
            end

            if (track_size!=0 && (bus_rd || bus_wr) && !bus_seen && !media_req) begin
                bus_seen <= 1'b1;
                if (bus_rd) begin
                    if (bus_addr == 0) irq <= 1'b0;
                    if (bus_addr == 3 && drq && mode == 4'h9) begin
                        drq <= 1'b0;
                        if (span == 16'd1) begin
                            span <= 0;
                            status_upper <= 0;
                            irq <= 1'b1;
                        end else begin
                            span <= span - 1'd1;
                            position <= position + 1'd1;
                            media_req <= 1'b1;
                            media_wr <= 1'b0;
                            media_addr <= track_base + {11'd0,position + 1'd1};
                        end
                    end
                end else begin
                    case (bus_addr)
                        3'd0: begin
                            irq <= 1'b0;
                            case (bus_din[7:4])
                                4'h0: begin
                                    mode <= 0; physical_track <= 0; track <= 0;
                                    irq <= 1'b1; status_upper <= 6'h01;
                                end
                                4'h1: begin
                                    mode <= 1; physical_track <= data_reg;
                                    track <= data_reg; irq <= 1'b1;
                                    status_upper <= data_reg == 0 ? 6'h01 : 6'h00;
                                end
                                4'h9,4'hb: begin
                                    mode <= bus_din[7:4];
                                    // byte offset = track_size*(2*track+side)
                                    track_base <= image_track_offset(
                                        track_size, {physical_track,bus_din[3]});
                                    position <= 0;
                                    span <= track_size;
                                    status_upper <= 6'h00;
                                    if (bus_din[7:4] == 4'h9) begin
                                        drq <= 1'b0;
                                        media_req <= 1'b1;
                                        media_wr <= 1'b0;
                                        media_addr <= image_track_offset(
                                            track_size, {physical_track,bus_din[3]});
                                    end else begin
                                        drq <= 1'b1;
                                    end
                                end
                                4'hd: begin
                                    mode <= 4'hd; span <= 0; drq <= 0;
                                    irq <= bus_din[0]; status_upper <= 0;
                                end
                                default: ;
                            endcase
                        end
                        3'd1: track <= bus_din;
                        3'd2: sector <= bus_din;
                        3'd3: begin
                            data_reg <= bus_din;
                            if (drq && mode == 4'hb) begin
                                media_req <= 1'b1;
                                media_wr <= 1'b1;
                                media_addr <= track_base + {11'd0,position};
                                media_wdata <= bus_din;
                            end
                        end
                        default: ; // control register has no modeled effect
                    endcase
                end
            end
        end
    end
endmodule
