// Load-time ownership outside the existing video arbiter. Retain a stalled
// command and all accepted responses across game/download reset. If video
// reset cancels a write burst, finish its remaining beats with byte enables 0.
module rf_ddr_rom_port #(parameter AUDIO_ENABLE=0) (
    input wire clk, init, video_reset, load,
    input wire [7:0] v_burstcnt,
    input wire [28:0] v_addr,
    input wire [63:0] v_din,
    input wire [7:0] v_be,
    input wire v_we, v_rd,
    output wire v_busy,
    output wire v_ready,
    input wire [28:0] l_addr,
    input wire [7:0] l_burstcnt,
    input wire l_rd,
    output wire l_busy,
    output wire l_ready,
    input wire a_req, a_write, a_reset,
    input wire [15:0] a_addr, a_data,
    output wire a_ack,
    output wire [15:0] a_q,
    input wire [63:0] DDRAM_DOUT,
    input wire DDRAM_BUSY,
    output reg [7:0] DDRAM_BURSTCNT,
    output reg [28:0] DDRAM_ADDR,
    output reg [63:0] DDRAM_DIN,
    output reg [7:0] DDRAM_BE,
    output reg DDRAM_WE, DDRAM_RD,
    input wire DDRAM_DOUT_READY
);
    reg loading = 0;
    reg [15:0] pending = 0;
    reg [7:0] write_left = 0, write_burst = 0;
    reg [28:0] write_addr;
    reg held = 0, held_loader, held_we, held_rd;
    reg [7:0] held_burst, held_be;
    reg [28:0] held_addr;
    reg [63:0] held_din;
    reg selected_loader, selected_video;
    reg selected_audio, held_audio;
    reg audio_pending=0, audio_served=0;
    reg audio_cancelled=0;
    reg [1:0] audio_lane;
    wire audio_request = AUDIO_ENABLE && a_req;
    wire audio_reset = AUDIO_ENABLE && a_reset;
    always @* begin
        DDRAM_BURSTCNT = 1; DDRAM_ADDR = 0; DDRAM_DIN = 0;
        DDRAM_BE = 0; DDRAM_WE = 0; DDRAM_RD = 0;
        selected_loader = 0; selected_video = 0;
        selected_audio = 0;
        if (held) begin
            DDRAM_BURSTCNT = held_burst; DDRAM_ADDR = held_addr;
            DDRAM_DIN = held_din; DDRAM_BE = held_be;
            DDRAM_WE = held_we; DDRAM_RD = held_rd;
            selected_loader = held_loader; selected_audio = held_audio;
            selected_video = !held_loader && !held_audio;
        end else if (write_left != 0 && video_reset) begin
            DDRAM_BURSTCNT = write_burst; DDRAM_ADDR = write_addr;
            DDRAM_WE = 1; // cancelled video payload: finish with no writes
        end else if (loading) begin
            DDRAM_BURSTCNT = l_burstcnt; DDRAM_ADDR = l_addr;
            DDRAM_RD = l_rd; DDRAM_BE = 8'hff; selected_loader = 1;
        end else if (!load && !video_reset && !audio_reset && !audio_cancelled && audio_request && !audio_served &&
                     !audio_pending && pending==0 && write_left==0) begin
            // 128KiB at byte30200000; outside sprite/flip buffers. ROM staging
            // may overlap only while load owns the port and sound is reset.
            DDRAM_ADDR = 29'h06040000 + {15'd0,a_addr[15:2]};
            DDRAM_DIN = {4{a_data}}; DDRAM_BE = 8'h03 << {a_addr[1:0],1'b0};
            DDRAM_WE = a_write; DDRAM_RD = !a_write; selected_audio=1;
        end else if (((!load && !video_reset && !audio_pending &&
                      !(audio_request && !audio_served)) || write_left != 0)) begin
            DDRAM_BURSTCNT = v_burstcnt; DDRAM_ADDR = v_addr;
            DDRAM_DIN = v_din; DDRAM_BE = v_be;
            DDRAM_WE = v_we; DDRAM_RD = v_rd; selected_video = 1;
        end
    end
    assign v_busy = DDRAM_BUSY || !selected_video;
    assign l_busy = DDRAM_BUSY || !selected_loader;
    assign v_ready = DDRAM_DOUT_READY && pending != 0 && !loading && !audio_pending;
    assign l_ready = DDRAM_DOUT_READY && pending != 0 && loading;
    wire accept = (DDRAM_WE || DDRAM_RD) && !DDRAM_BUSY;
    wire returned = DDRAM_DOUT_READY && pending != 0;
    assign a_ack = !audio_reset && !audio_cancelled &&
                   ((accept && selected_audio && DDRAM_WE) || (returned && audio_pending));
    assign a_q = DDRAM_DOUT[audio_lane*16+:16];
    wire [15:0] read_beats = accept && DDRAM_RD ? {8'd0, DDRAM_BURSTCNT} : 16'd0;
    always @(posedge clk) begin
        if (init) begin
            loading <= 0; pending <= 0; write_left <= 0; held <= 0;
            audio_pending<=0;audio_served<=0;held_audio<=0;audio_lane<=0;
            audio_cancelled<=0;
        end else begin
            if(!audio_request || audio_reset)audio_served<=0;
            if(returned && audio_pending)audio_pending<=0;
            // Finish the old external transfer but never acknowledge it into
            // the restarted DSP. Keep its epoch until every old beat retires.
            if((returned && audio_pending) || (accept && selected_audio && DDRAM_WE))
                audio_cancelled<=0;
            if(audio_reset && ((audio_pending && !returned) ||
                (held && held_audio && !accept) || (accept && selected_audio && DDRAM_RD)))
                audio_cancelled<=1;
            pending <= pending + read_beats - (returned ? 16'd1 : 16'd0);
            if (!held && (DDRAM_WE || DDRAM_RD) && DDRAM_BUSY) begin
                held <= 1; held_loader <= selected_loader;
                held_audio <= selected_audio;
                held_burst <= DDRAM_BURSTCNT; held_addr <= DDRAM_ADDR;
                held_din <= DDRAM_DIN; held_be <= DDRAM_BE;
                held_we <= DDRAM_WE; held_rd <= DDRAM_RD;
            end
            if (accept) begin
                held <= 0;
                if(selected_audio)begin
                    audio_served<=!audio_reset && !audio_cancelled;
                    // Lane belongs to the held request, not a subsequent one.
                    case(DDRAM_BE)
                        8'h03:audio_lane<=0;8'h0c:audio_lane<=1;
                        8'h30:audio_lane<=2;default:audio_lane<=3;
                    endcase
                    if(DDRAM_RD)audio_pending<=1;
                end
                if (DDRAM_WE) begin
                    if (write_left != 0) write_left <= write_left - 1'b1;
                    else begin
                        write_left <= DDRAM_BURSTCNT - 1'b1;
                        write_burst <= DDRAM_BURSTCNT; write_addr <= DDRAM_ADDR;
                    end
                end
            end
            // No outstanding transaction may change its response owner.
            if (!held && write_left == 0 && pending == 0 && !accept) begin
                if (load && !loading) loading <= 1;
                else if (!load && loading && !l_rd) loading <= 0;
            end
        end
    end
endmodule
