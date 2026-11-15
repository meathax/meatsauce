// Big Fight's byte-addressed CPU RAM and synchronous video read ports.
// The board bus supplies cpu_valid and holds its transaction until cpu_ready;
// a RAM read is staged for one edge, while a write commits on the final
// cpu_valid && cpu_ready edge only.
module bigfight_work_ram (
    input wire hs_access,
    input wire hs_write,
    input wire [15:0] hs_address,
    input wire [7:0] hs_wdata,
    output wire [7:0] hs_rdata,

    input wire hs_grant,
    input  logic         clk_sys,
    input  logic         cold_reset,
    input  logic         load_mode,

    input  logic         cpu_valid,
    input  logic         cpu_owner_main,
    input  logic         cpu_wr,
    input  logic         cpu_uds_n,
    input  logic         cpu_lds_n,
    input  logic [23:1]  cpu_address,
    input  logic [15:0]  cpu_wdata,
    output logic         cpu_selected,
    output logic         cpu_ready,
    output logic [15:0]  cpu_rdata,

    input  logic         load_valid,
    input  logic [2:0]   load_bank,
    input  logic [14:0]  load_word_address,
    input  logic [15:0]  load_data,
    input  logic         load_uds_n,
    input  logic         load_lds_n,
    output logic         load_ready,

    input  logic         vram_req,
    output logic         vram_req_ready,
    input  logic         vram_bank,
    input  logic [14:0]  vram_word_address,
    output logic         vram_rsp_valid,
    input  logic         vram_rsp_ready,
    output logic [15:0]  vram_rsp_data,

    input  logic         sprite_req,
    output logic         sprite_req_ready,
    input  logic [12:0]  sprite_word_address,
    output logic         sprite_rsp_valid,
    input  logic         sprite_rsp_ready,
    output logic [15:0]  sprite_rsp_data,

    input  logic         palette_req,
    output logic         palette_req_ready,
    input  logic [12:0]  palette_word_address,
    output logic         palette_rsp_valid,
    input  logic         palette_rsp_ready,
    output logic [15:0]  palette_rsp_data,

    input  logic         object_req,
    output logic         object_req_ready,
    input  logic [7:0]   object_word_address,
    output logic         object_rsp_valid,
    input  logic         object_rsp_ready,
    output logic [15:0]  object_rsp_data
);
    localparam logic [2:0] BANK_MAIN   = 3'd0;
    localparam logic [2:0] BANK_SUB    = 3'd1;
    localparam logic [2:0] BANK_EXTRA  = 3'd2;
    localparam logic [2:0] BANK_VRAM0  = 3'd3;
    localparam logic [2:0] BANK_VRAM1  = 3'd4;
    localparam logic [2:0] BANK_SPRITE = 3'd5;
    localparam logic [2:0] BANK_OBJECT = 3'd6;
    localparam logic [2:0] BANK_PALETTE= 3'd7;

    logic [2:0] cpu_decode_bank;
    logic [14:0] cpu_decode_word;
    wire [18:0] cpu_decode_fields;
    logic cpu_pending;
    logic [2:0] cpu_pending_bank;
    logic [14:0] cpu_pending_word;
    logic [23:1] cpu_pending_address;
    logic cpu_pending_owner_main;
    logic cpu_pending_wr;
    logic cpu_pending_uds_n, cpu_pending_lds_n;
    logic [15:0] cpu_pending_wdata;
    logic cpu_pending_match;
    logic cpu_cancelled;
    // 2026-10-23 timing repair: a captured CPU read is issued to its bank one
    // clock later from the registered pending word, and acknowledged the clock
    // after that, so no live CPU address decode reaches an M10K address port.
    logic cpu_read_issue_q, cpu_read_done_q;
    wire  cpu_rd_issue;
    logic cpu_capture;
    logic cpu_accept;

    logic load_address_valid;
    logic load_accept;
    logic [15:0] bank_cpu_q [0:7];
    logic [15:0] bank_video_q [0:7];
    logic [2:0] vram_rsp_bank_q;

    wire vram_take = vram_req && vram_req_ready;
    wire sprite_take = sprite_req && sprite_req_ready;
    wire palette_take = palette_req && palette_req_ready;
    wire object_take = object_req && object_req_ready;

    function automatic [18:0] decode_cpu_address(
        input logic [23:0] byte_address,
        input logic owner_main
    );
        logic selected;
        logic [2:0] bank;
        logic [14:0] word_index;
        begin
            selected = 1'b1;
            bank = BANK_MAIN;
            word_index = 15'd0;

            // MAME master_map/slave_map: each CPU's low 64 KiB is private.
            if (byte_address < 24'h010000) begin
                bank = owner_main ? BANK_MAIN : BANK_SUB;
                word_index = byte_address[15:1];
            end else if (owner_main && byte_address >= 24'h03e000 &&
                         byte_address < 24'h03f000) begin
                bank = BANK_EXTRA;
                word_index = {4'b0000, byte_address[11:1]};
            end else if (owner_main && byte_address >= 24'h040000 &&
                         byte_address < 24'h050000) begin
                // This is a second address window onto the physical slave RAM.
                bank = BANK_SUB;
                word_index = byte_address[15:1];
            end else if (byte_address >= 24'h080000 && byte_address < 24'h090000) begin
                bank = BANK_VRAM1;
                word_index = byte_address[15:1];
            end else if (byte_address >= 24'h090000 && byte_address < 24'h0a0000) begin
                bank = BANK_VRAM0;
                word_index = byte_address[15:1];
            end else if (byte_address >= 24'h0c0000 && byte_address < 24'h0c4000) begin
                bank = BANK_SPRITE;
                word_index = {2'b00, byte_address[13:1]};
            end else if (byte_address >= 24'h0ca000 && byte_address < 24'h0ca200) begin
                bank = BANK_OBJECT;
                word_index = {7'b0, byte_address[8:1]};
            end else if (byte_address >= 24'h0d0000 && byte_address < 24'h0d4000) begin
                bank = BANK_PALETTE;
                word_index = {2'b00, byte_address[13:1]};
            end else begin
                selected = 1'b0;
                bank = BANK_MAIN;
                word_index = 15'd0;
            end
            decode_cpu_address = {selected, bank, word_index};
        end
    endfunction

    function automatic valid_load_address(
        input logic [2:0] bank,
        input logic [14:0] word_address
    );
        begin
            case (bank)
                BANK_MAIN, BANK_SUB, BANK_VRAM0, BANK_VRAM1:
                    valid_load_address = 1'b1;
                BANK_EXTRA:  valid_load_address = (word_address[14:11] == 0);
                BANK_SPRITE, BANK_PALETTE:
                    valid_load_address = (word_address[14:13] == 0);
                BANK_OBJECT: valid_load_address = (word_address[14:8] == 0);
                default:     valid_load_address = 1'b0;
            endcase
        end
    endfunction

    assign cpu_decode_fields = decode_cpu_address({cpu_address, 1'b0}, cpu_owner_main);
    assign cpu_selected = cpu_decode_fields[18];
    assign cpu_decode_bank = cpu_decode_fields[17:15];
    assign cpu_decode_word = cpu_decode_fields[14:0];
    assign load_address_valid = valid_load_address(load_bank, load_word_address);

    assign cpu_pending_match = cpu_selected &&
        (cpu_address == cpu_pending_address) &&
        (cpu_owner_main == cpu_pending_owner_main) &&
        (cpu_wr == cpu_pending_wr) &&
        (cpu_uds_n == cpu_pending_uds_n) &&
        (cpu_lds_n == cpu_pending_lds_n) &&
        (!cpu_pending_wr || (cpu_wdata == cpu_pending_wdata));
    assign cpu_rd_issue = cpu_read_issue_q && cpu_pending && !cpu_pending_wr &&
                          !cold_reset && !load_mode && !cpu_cancelled && cpu_valid && cpu_pending_match;
    assign cpu_ready = !cold_reset && !load_mode && !cpu_cancelled && cpu_valid &&
                       cpu_pending && cpu_pending_match && (cpu_pending_wr || cpu_read_done_q);
    assign cpu_accept = cpu_valid && cpu_ready;
    assign cpu_capture = !cold_reset && !load_mode && !cpu_cancelled && cpu_valid &&
                         cpu_selected && !cpu_pending;

    assign load_ready = !cold_reset && load_mode && load_address_valid;
    assign load_accept = load_valid && load_ready;

    // Each request is accepted on one edge. Read data is registered on that
    // edge, and its valid/data pair is retained until the consumer takes it.
    assign vram_req_ready = !cold_reset && !load_mode &&
                            (!vram_rsp_valid || vram_rsp_ready);
    assign sprite_req_ready = !cold_reset && !load_mode &&
                              (!sprite_rsp_valid || sprite_rsp_ready);
    assign palette_req_ready = !cold_reset && !load_mode &&
                               (!palette_rsp_valid || palette_rsp_ready);
    assign object_req_ready = !cold_reset && !load_mode &&
                              (!object_rsp_valid || object_rsp_ready);

    always_comb begin
        case (cpu_pending_bank)
            BANK_MAIN:    cpu_rdata = bank_cpu_q[0];
            BANK_SUB:     cpu_rdata = bank_cpu_q[1];
            BANK_EXTRA:   cpu_rdata = bank_cpu_q[2];
            BANK_VRAM0:   cpu_rdata = bank_cpu_q[3];
            BANK_VRAM1:   cpu_rdata = bank_cpu_q[4];
            BANK_SPRITE:  cpu_rdata = bank_cpu_q[5];
            BANK_OBJECT:  cpu_rdata = bank_cpu_q[6];
            BANK_PALETTE: cpu_rdata = bank_cpu_q[7];
            default:      cpu_rdata = 16'hxxxx;
        endcase

        case (vram_rsp_bank_q)
            BANK_VRAM0: vram_rsp_data = bank_video_q[3];
            BANK_VRAM1: vram_rsp_data = bank_video_q[4];
            default:    vram_rsp_data = 16'hxxxx;
        endcase
        sprite_rsp_data  = bank_video_q[5];
        object_rsp_data  = bank_video_q[6];
        palette_rsp_data = bank_video_q[7];
    end

    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            cpu_cancelled <= cpu_valid;
            cpu_pending <= 1'b0;
            cpu_read_issue_q <= 1'b0;
            cpu_read_done_q <= 1'b0;
            cpu_pending_bank <= BANK_MAIN;
            cpu_pending_word <= 15'd0;
            cpu_pending_address <= '0;
            cpu_pending_owner_main <= 1'b0;
            cpu_pending_wr <= 1'b0;
            cpu_pending_uds_n <= 1'b1;
            cpu_pending_lds_n <= 1'b1;
            cpu_pending_wdata <= 16'd0;
            vram_rsp_valid <= 1'b0;
            vram_rsp_bank_q <= BANK_VRAM0;
            sprite_rsp_valid <= 1'b0;
            palette_rsp_valid <= 1'b0;
            object_rsp_valid <= 1'b0;
        end else begin
            cpu_read_issue_q <= cpu_capture && !cpu_wr &&
                                !(load_mode || !cpu_valid || cpu_cancelled) && !cpu_pending;
            if (cpu_rd_issue)
                cpu_read_done_q <= 1'b1;
            else if (!cpu_pending || load_mode || !cpu_valid || cpu_cancelled ||
                     !cpu_pending_match || cpu_accept)
                cpu_read_done_q <= 1'b0;
            if (!cpu_valid)
                cpu_cancelled <= 1'b0;
            else if (load_mode || (cpu_pending && !cpu_pending_match))
                cpu_cancelled <= 1'b1;

            // Dropped valid, a changed payload, or loader ownership cancels
            // the staged cycle before any write can reach the RAM bank. Once
            // canceled, a still-high valid must fall before another request
            // can be staged, so it cannot replay after reset/loading.
            if (load_mode || !cpu_valid || cpu_cancelled) begin
                cpu_pending <= 1'b0;
            end else if (cpu_pending) begin
                if (!cpu_pending_match || cpu_accept)
                    cpu_pending <= 1'b0;
            end else if (cpu_capture) begin
                cpu_pending <= 1'b1;
                cpu_pending_bank <= cpu_decode_bank;
                cpu_pending_word <= cpu_decode_word;
                cpu_pending_address <= cpu_address;
                cpu_pending_owner_main <= cpu_owner_main;
                cpu_pending_wr <= cpu_wr;
                cpu_pending_uds_n <= cpu_uds_n;
                cpu_pending_lds_n <= cpu_lds_n;
                cpu_pending_wdata <= cpu_wdata;
            end

            if (vram_take) begin
                vram_rsp_valid <= 1'b1;
                vram_rsp_bank_q <= vram_bank ? BANK_VRAM1 : BANK_VRAM0;
            end else if (vram_rsp_valid && vram_rsp_ready) begin
                vram_rsp_valid <= 1'b0;
            end

            if (sprite_take)
                sprite_rsp_valid <= 1'b1;
            else if (sprite_rsp_valid && sprite_rsp_ready)
                sprite_rsp_valid <= 1'b0;

            if (palette_take)
                palette_rsp_valid <= 1'b1;
            else if (palette_rsp_valid && palette_rsp_ready)
                palette_rsp_valid <= 1'b0;

            if (object_take)
                object_rsp_valid <= 1'b1;
            else if (object_rsp_valid && object_rsp_ready)
                object_rsp_valid <= 1'b0;
        end
    end

    wire score_port = hs_access && hs_grant && !load_mode && !cold_reset &&
                      ((hs_address >= 16'h22a8 && hs_address <= 16'h22e1) ||
                       (hs_address >= 16'h6b04 && hs_address <= 16'h707b));
    logic hs_lane_q;
    always_ff @(posedge clk_sys) if (score_port) hs_lane_q <= hs_address[0];
    assign hs_rdata = hs_lane_q ? bank_video_q[0][7:0] : bank_video_q[0][15:8];

    genvar bank_g;
    generate
        for (bank_g = 0; bank_g < 8; bank_g = bank_g + 1) begin : g_bank
            localparam integer ADDR_BITS =
                (bank_g == 2) ? 11 :
                (bank_g == 5 || bank_g == 7) ? 13 :
                (bank_g == 6) ? 8 : 15;
            localparam integer WORDS = (1 << ADDR_BITS);

            wire cpu_rd_en = cpu_rd_issue &&
                             (cpu_pending_bank == bank_g);
            wire [ADDR_BITS-1:0] cpu_rd_addr = cpu_pending_word[ADDR_BITS-1:0];
            wire load_wr_en = load_accept && (load_bank == bank_g);
            wire cpu_wr_en = cpu_accept && cpu_pending_wr &&
                             (cpu_pending_bank == bank_g);
            wire score_write = (bank_g == 0) && score_port && hs_write;
            wire bank_wr_en = load_wr_en || cpu_wr_en || score_write;
            wire [14:0] bank_wr_word = score_write ? {1'b0, hs_address[15:1]} : cpu_wr_en ? cpu_pending_word : load_word_address;
            wire [ADDR_BITS-1:0] bank_wr_addr = bank_wr_word[ADDR_BITS-1:0];
            wire [15:0] bank_wr_data = score_write ? {hs_wdata, hs_wdata} : cpu_wr_en ? cpu_pending_wdata : load_data;
            wire bank_wr_uds_n = score_write ? hs_address[0] : cpu_wr_en ? cpu_pending_uds_n : load_uds_n;
            wire bank_wr_lds_n = score_write ? !hs_address[0] : cpu_wr_en ? cpu_pending_lds_n : load_lds_n;

            wire bank_video_en;
            wire [ADDR_BITS-1:0] bank_video_addr;
            if (bank_g == 0) begin : g_score_video
                assign bank_video_en = score_port;
                assign bank_video_addr = hs_address[15:1];
            end else if (bank_g == 3) begin : g_vram0_video
                assign bank_video_en = vram_take && !vram_bank;
                assign bank_video_addr = vram_word_address[ADDR_BITS-1:0];
            end else if (bank_g == 4) begin : g_vram1_video
                assign bank_video_en = vram_take && vram_bank;
                assign bank_video_addr = vram_word_address[ADDR_BITS-1:0];
            end else if (bank_g == 5) begin : g_sprite_video
                assign bank_video_en = sprite_take;
                assign bank_video_addr = sprite_word_address;
            end else if (bank_g == 6) begin : g_object_video
                assign bank_video_en = object_take;
                assign bank_video_addr = object_word_address;
            end else if (bank_g == 7) begin : g_palette_video
                assign bank_video_en = palette_take;
                assign bank_video_addr = palette_word_address;
            end else begin : g_no_video
                assign bank_video_en = 1'b0;
                assign bank_video_addr = '0;
            end

            bigfight_work_ram_bank #(
                .ADDR_BITS(ADDR_BITS),
                .WORDS(WORDS)
            ) u_ram (
                .clk(clk_sys),
                .write_en(bank_wr_en),
                .write_address(bank_wr_addr),
                .write_data(bank_wr_data),
                .write_uds_n(bank_wr_uds_n),
                .write_lds_n(bank_wr_lds_n),
                .cpu_read_en(cpu_rd_en),
                .cpu_read_address(cpu_rd_addr),
                .cpu_read_data(bank_cpu_q[bank_g]),
                .video_read_en(bank_video_en),
                .video_read_address(bank_video_addr),
                .video_read_data(bank_video_q[bank_g])
            );
        end
    endgenerate
endmodule


// One independent physical RAM bank. Port A is CPU-or-loader read/write;
// port B is the bank's synchronous video read. Byte planes and a single muxed
// write address/data avoid part-select writes and replicated read memories.
module bigfight_work_ram_bank #(
    parameter integer ADDR_BITS = 15,
    parameter integer WORDS = (1 << ADDR_BITS)
) (
    input  logic                  clk,
    input  logic                  write_en,
    input  logic [ADDR_BITS-1:0]  write_address,
    input  logic [15:0]           write_data,
    input  logic                  write_uds_n,
    input  logic                  write_lds_n,
    input  logic                  cpu_read_en,
    input  logic [ADDR_BITS-1:0]  cpu_read_address,
    output logic [15:0]           cpu_read_data,
    input  logic                  video_read_en,
    input  logic [ADDR_BITS-1:0]  video_read_address,
    output logic [15:0]           video_read_data
);
    wire [ADDR_BITS-1:0] port_a_address = write_en ? write_address : cpu_read_address;
    wire cpu_read_take = cpu_read_en && !write_en;
    wire same_address = (write_address == video_read_address);
    wire forward_hi = write_en && !write_uds_n && same_address;
    wire forward_lo = write_en && !write_lds_n && same_address;
    logic forward_hi_q, forward_lo_q;
    logic [15:0] forward_data_q;
    wire [7:0] cpu_hi, cpu_lo, video_hi, video_lo;

    // RAM port B never reads a byte that is written on that edge. Each lane
    // has its own forwarding selector so the untouched byte still comes from
    // synchronous RAM. The mux is outside the RAM output register template.
    always_ff @(posedge clk) begin
        if (video_read_en) begin
            forward_hi_q <= forward_hi;
            forward_lo_q <= forward_lo;
            forward_data_q <= write_data;
        end
    end
    assign cpu_read_data = {cpu_hi, cpu_lo};
    assign video_read_data = {
        forward_hi_q ? forward_data_q[15:8] : video_hi,
        forward_lo_q ? forward_data_q[7:0] : video_lo
    };

    bigfight_work_ram_plane #(.ADDR_BITS(ADDR_BITS), .WORDS(WORDS)) u_hi (
        .clk(clk), .a_address(port_a_address),
        .a_write(write_en && !write_uds_n), .a_wdata(write_data[15:8]),
        .a_read(cpu_read_take), .a_rdata(cpu_hi),
        .b_address(video_read_address),
        .b_read(video_read_en && !forward_hi), .b_rdata(video_hi)
    );
    bigfight_work_ram_plane #(.ADDR_BITS(ADDR_BITS), .WORDS(WORDS)) u_lo (
        .clk(clk), .a_address(port_a_address),
        .a_write(write_en && !write_lds_n), .a_wdata(write_data[7:0]),
        .a_read(cpu_read_take), .a_rdata(cpu_lo),
        .b_address(video_read_address),
        .b_read(video_read_en && !forward_lo), .b_rdata(video_lo)
    );
endmodule

// One byte-wide synchronous two-read inference template: A is CPU/loader read/write,
// B is video read-only. Quartus may duplicate simple-dual-port read copies.
// Admission above excludes every consumed same-address read/write collision;
// no no_rw_check attribute or primitive read-during-write assumption is needed.
module bigfight_work_ram_plane #(
    parameter integer ADDR_BITS = 15,
    parameter integer WORDS = (1 << ADDR_BITS)
) (
    input logic clk,
    input logic [ADDR_BITS-1:0] a_address,
    input logic a_write,
    input logic [7:0] a_wdata,
    input logic a_read,
    output logic [7:0] a_rdata,
    input logic [ADDR_BITS-1:0] b_address,
    input logic b_read,
    output logic [7:0] b_rdata
);
`ifdef VERILATOR
    `define BIGFIGHT_WORK_RAM_BEHAVIOURAL
`endif
`ifdef __ICARUS__
    `define BIGFIGHT_WORK_RAM_BEHAVIOURAL
`endif
`ifdef BIGFIGHT_WORK_RAM_BEHAVIOURAL
    logic [7:0] mem [0:WORDS-1];
    always_ff @(posedge clk) begin
        if (a_write) mem[a_address] <= a_wdata;
        if (a_read) a_rdata <= mem[a_address];
    end
    always_ff @(posedge clk) begin
        if (b_read) b_rdata <= mem[b_address];
    end
`else
    // Synthesis: one true-dual-port M10K array instead of Quartus' duplicated
    // simple-dual-port read copies (2026-10-22 M10K repair). Parameterisation
    // is the vendor-model-qualified tests/work_ram_tdp_candidate primitive
    // (run 20261021-184857-7c24fe534590, installed Q17 altera_mf). Callers
    // never read port A while writing it and suppress same-address B reads.
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"), .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"), .ram_block_type("M10K"),
        .width_a(8), .width_b(8), .widthad_a(ADDR_BITS), .widthad_b(ADDR_BITS),
        .numwords_a(WORDS), .numwords_b(WORDS), .width_byteena_a(1), .width_byteena_b(1),
        .address_reg_b("CLOCK1"), .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .clock_enable_input_a("BYPASS"), .clock_enable_input_b("BYPASS"),
        .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS"),
        .read_during_write_mode_port_a("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_port_b("NEW_DATA_NO_NBE_READ"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),
        .power_up_uninitialized("TRUE")
    ) u_ram (
        .address_a(a_address), .address_b(b_address), .clock0(clk), .clock1(clk),
        .data_a(a_wdata), .data_b(8'd0), .wren_a(a_write), .wren_b(1'b0),
        .rden_a(a_read && !a_write), .rden_b(b_read), .byteena_a(1'b1), .byteena_b(1'b1),
        .q_a(a_rdata), .q_b(b_rdata), .aclr0(1'b0), .aclr1(1'b0),
        .addressstall_a(1'b0), .addressstall_b(1'b0),
        .clocken0(1'b1), .clocken1(1'b1), .clocken2(1'b1), .clocken3(1'b1), .eccstatus()
    );
`endif
endmodule
