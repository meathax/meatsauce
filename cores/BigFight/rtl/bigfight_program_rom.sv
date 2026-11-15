// Native device-bus completion bridge to one ordered synchronous ROM service.
// cold_reset must also flush the ROM backend; no pre-reset reply may reappear.
module bigfight_program_rom (
    input logic clk_sys,cold_reset,
    input logic cpu_valid,cpu_wr,
    input logic [23:1] cpu_address,
    output logic cpu_selected,cpu_ready,
    output logic [15:0] cpu_rdata,
    output logic rom_req,
    input logic rom_ready,
    output logic rom_master,
    output logic [19:0] rom_word_address,
    input logic rom_rsp_valid,
    output logic rom_rsp_ready,
    input logic [15:0] rom_rsp_data
`ifdef BIGFIGHT_CPU_RECOVERY
    ,input logic cpu_owner_main,
    output logic [1:0] program_owner
`endif
);
    typedef enum logic [1:0] {IDLE,WAIT_REPLY,HOLD_REPLY} state_t;
    state_t state;
    logic [23:1] accepted_address;
    logic [15:0] reply;
    logic abandoned;
`ifdef BIGFIGHT_CPU_RECOVERY
    logic pending_owner_valid_q;
    logic pending_owner_main_q;
    logic [23:1] pending_owner_address_q;
    logic accepted_owner_valid_q;
    logic accepted_owner_main_q;

    // Observation-only owner descriptor. Capture the selected CPU before
    // frontend acceptance; preserve it through frontend stalls and the held
    // bridge reply. The CPU pair then retains ownership through physical AS/
    // strobe release, including a final wait repeat after mem_ready.
    always_comb begin
        program_owner = 2'b00;
        if (!cold_reset) begin
            if (state == IDLE && cpu_valid && cpu_selected && !cpu_wr) begin
                if (pending_owner_valid_q &&
                    pending_owner_address_q == cpu_address)
                    program_owner = pending_owner_main_q ? 2'b01 : 2'b10;
                else
                    program_owner = cpu_owner_main ? 2'b01 : 2'b10;
            end else if ((state == WAIT_REPLY || state == HOLD_REPLY) &&
                         accepted_owner_valid_q && !abandoned && cpu_valid &&
                         cpu_selected && cpu_address == accepted_address) begin
                program_owner = accepted_owner_main_q ? 2'b01 : 2'b10;
            end
        end
    end

    // Kept separate from the bridge FSM so the original ready/data/response
    // behavior remains unchanged. cold_reset must flush the shared backend.
    always_ff @(posedge clk_sys) begin
        if (cold_reset) begin
            pending_owner_valid_q <= 1'b0;
            pending_owner_main_q <= 1'b0;
            pending_owner_address_q <= '0;
            accepted_owner_valid_q <= 1'b0;
            accepted_owner_main_q <= 1'b0;
        end else begin
            case (state)
                IDLE: begin
                    accepted_owner_valid_q <= 1'b0;
                    if (cpu_valid && cpu_selected && !cpu_wr) begin
                        if (rom_ready) begin
                            if (pending_owner_valid_q &&
                                pending_owner_address_q == cpu_address)
                                accepted_owner_main_q <= pending_owner_main_q;
                            else
                                accepted_owner_main_q <= cpu_owner_main;
                            accepted_owner_valid_q <= 1'b1;
                            pending_owner_valid_q <= 1'b0;
                        end else if (!pending_owner_valid_q ||
                                     pending_owner_address_q != cpu_address) begin
                            pending_owner_valid_q <= 1'b1;
                            pending_owner_main_q <= cpu_owner_main;
                            pending_owner_address_q <= cpu_address;
                        end
                    end else begin
                        pending_owner_valid_q <= 1'b0;
                    end
                end
                WAIT_REPLY: begin
                    if (!cpu_valid || cpu_address != accepted_address || abandoned)
                        accepted_owner_valid_q <= 1'b0;
                end
                HOLD_REPLY: begin
                    if (!cpu_valid || cpu_ready || cpu_address != accepted_address)
                        accepted_owner_valid_q <= 1'b0;
                end
                default: begin
                    pending_owner_valid_q <= 1'b0;
                    accepted_owner_valid_q <= 1'b0;
                end
            endcase
        end
    end
`endif
    wire [23:0] byte_address={cpu_address,1'b0};
    assign cpu_selected=(byte_address>=24'h100000 && byte_address<=24'h3ffffe);
    assign rom_master=(byte_address>=24'h200000);
    // Both CPUs use the same logical regions; slave is 1MiB, master 2MiB.
    assign rom_word_address=rom_master ? cpu_address[20:1] : {1'b0,cpu_address[19:1]};
    assign rom_req=!cold_reset && state==IDLE && cpu_valid && cpu_selected && !cpu_wr;
    assign rom_rsp_ready=!cold_reset && state==WAIT_REPLY;
    assign cpu_ready=!cold_reset && state==HOLD_REPLY && cpu_valid &&
                     cpu_selected && cpu_address==accepted_address;
    assign cpu_rdata=reply;
    always_ff @(posedge clk_sys) begin
        if(cold_reset) begin
            state<=IDLE;accepted_address<='0;reply<=16'hffff;abandoned<=1'b0;
        end else begin
            case(state)
                IDLE: begin
                    abandoned<=1'b0;
                    if(cpu_valid && cpu_selected) begin
                        if(cpu_wr) begin
                            // ROM writes are acknowledged without changing storage.
                            accepted_address<=cpu_address;reply<=16'hffff;state<=HOLD_REPLY;
                        end else if(rom_ready) begin
                            accepted_address<=cpu_address;state<=WAIT_REPLY;
                        end
                    end
                end
                WAIT_REPLY: begin
                    if(!cpu_valid || cpu_address!=accepted_address) abandoned<=1'b1;
                    if(rom_rsp_valid) begin
                        if(abandoned || !cpu_valid || cpu_address!=accepted_address) state<=IDLE;
                        else begin reply<=rom_rsp_data;state<=HOLD_REPLY;end
                    end
                end
                HOLD_REPLY: begin
                    // Final native acceptance is valid&&ready on this edge.
                    if(!cpu_valid || cpu_ready || cpu_address!=accepted_address) state<=IDLE;
                end
                default:state<=IDLE;
            endcase
        end
    end
endmodule
