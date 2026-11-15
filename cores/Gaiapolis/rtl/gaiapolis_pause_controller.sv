// SPDX-License-Identifier: GPL-3.0-or-later
// clk48 transaction boundary. All input bus/status pins are synchronous to
// clk48 except the three held platform requests, synchronized below.
// main_phi1/2 are upstream FX68K enables BEFORE main_ce_run masking.
// *_pending includes memory/registered-answer tails, never video render ports.
// eeprom_commit is an actual admitted game-memory write (one clk48 per byte),
// not factory initialization or HPS restore. continuous WRITE_ALL is128events.
// core_reset is the shared CPU/PCM/5911 reset, NOT this controller's reset;
// this controller and its grant must survive reset held by an admitted restore.
module gaiapolis_pause_controller (
    input logic clk,rst,pause_req,nv_freeze_req,restore_pending,
    input logic nv_initialized,seed_active,core_reset,
    input logic main_phi1,main_phi2,main_as_n,main_uds_n,main_lds_n,main_pending,
    input logic sound_busak_n,sound_mreq_n,sound_iorq_n,sound_rd_n,sound_wr_n,sound_pending,
    input logic [1:0] pcm_idle,
    input logic eeprom_cs,eeprom_ready,eeprom_write,eeprom_control_write,
    input logic nv_write_pending,eeprom_commit,
    output logic main_halt_n,sound_busrq_n,main_ce_run,sound_ce_run,
    output logic pcm_quiesce,gameplay_freeze,gameplay_irq_run,pause_ack,
    output logic nv_safe_grant,restore_cancel_seed,dirty_toggle,boundary_fault
);
    logic [1:0] pause_sync,nv_sync,restore_sync;
    logic main_halt_requested,phi1_seen,phi2_seen;
    logic [2:0] eeprom_quiet_count,main_quiet_count,all_quiet_count;
    typedef enum logic [1:0] {RUN,DRAIN,HOLD} state_t;
    // Keep the Moore ownership boundary; physical retiming must not absorb it.
    (* preserve *) state_t state;
    wire want=pause_sync[1] || nv_sync[1];
    wire main_idle=main_as_n && main_uds_n && main_lds_n && !main_pending;
    wire sound_idle=sound_mreq_n && sound_iorq_n && sound_rd_n && sound_wr_n && !sound_pending;
    wire eeprom_idle=!eeprom_cs && (eeprom_ready || core_reset) &&
                     !eeprom_write && !eeprom_control_write && !nv_write_pending;
    // Include currentpins as well as the guard count. A select/write arriving
    // on the final DRAIN edge must veto acknowledgement immediately.
    wire eeprom_quiet=eeprom_quiet_count==3'd4 && eeprom_idle;
    wire main_stopped=main_idle && (core_reset ||
                      (main_halt_requested && phi1_seen && phi2_seen && main_quiet_count==3'd3));
    wire sound_stopped=sound_idle && (core_reset || !sound_busak_n);
    wire seed_quiet=!seed_active || restore_cancel_seed;
    wire all_quiet=main_stopped && sound_stopped && (&pcm_idle) && eeprom_quiet && seed_quiet;
    wire restore_eligible=nv_initialized || restore_sync[1];
    always_comb begin
        restore_cancel_seed=nv_sync[1] && restore_sync[1];
        main_halt_n=!(main_halt_requested || state==HOLD);
        sound_busrq_n=!(want || state==HOLD);
        main_ce_run=state!=HOLD;
        sound_ce_run=state!=HOLD;
        pcm_quiesce=want || state==HOLD;
        gameplay_freeze=state==HOLD;
        gameplay_irq_run=state!=HOLD;
        pause_ack=state==HOLD;
    end
    always_ff @(posedge clk) begin
        if(rst) begin
            pause_sync<=0;nv_sync<=0;restore_sync<=0;state<=RUN;
            main_halt_requested<=0;phi1_seen<=0;phi2_seen<=0;
            eeprom_quiet_count<=0;main_quiet_count<=0;all_quiet_count<=0;
            nv_safe_grant<=0;dirty_toggle<=0;boundary_fault<=0;
        end else begin
            pause_sync<={pause_sync[0],pause_req};
            nv_sync<={nv_sync[0],nv_freeze_req};
            restore_sync<={restore_sync[0],restore_pending};
            if(eeprom_commit && nv_initialized && !seed_active && !restore_sync[1])
                dirty_toggle<=~dirty_toggle;
            if(eeprom_idle) begin
                if(eeprom_quiet_count!=3'd4) eeprom_quiet_count<=eeprom_quiet_count+1'b1;
            end else eeprom_quiet_count<=0;
            if(!nv_sync[1]) nv_safe_grant<=0;
            else if(state==HOLD && all_quiet && restore_eligible) nv_safe_grant<=1;
            // Stable grant through HPS transfer/drain. Once held, real game
            // writes cannot occur: CPUs have no enables,5911CS is alreadylow.
            // The parent's restore port is intentionally absent from pending.
            if(state==HOLD && (!main_idle || !sound_idle || !( &pcm_idle) ||
                eeprom_cs || eeprom_write || eeprom_control_write || nv_write_pending))
                boundary_fault<=1;
            case(state)
                RUN:begin
                    main_halt_requested<=0;phi1_seen<=0;phi2_seen<=0;
                    main_quiet_count<=0;all_quiet_count<=0;
                    if(want) state<=DRAIN;
                end
                DRAIN:begin
                    if(!want) begin
                        state<=RUN;main_halt_requested<=0;
                        phi1_seen<=0;phi2_seen<=0;main_quiet_count<=0;all_quiet_count<=0;
                    end else begin
                        // A CPU write in flight may reopen EEPROM CS just
                        // after HALT was requested. Release it until the real
                        // serial command ends; never synthesize serial clocks.
                        if(!eeprom_quiet) begin
                            main_halt_requested<=0;phi1_seen<=0;phi2_seen<=0;main_quiet_count<=0;
                        end else begin
                            main_halt_requested<=1;
                            if(main_halt_requested && main_phi1) phi1_seen<=1;
                            if(phi1_seen && main_phi2) phi2_seen<=1;
                            if(phi1_seen && phi2_seen && main_idle) begin
                                if(main_quiet_count!=3'd3) main_quiet_count<=main_quiet_count+1'b1;
                            end else main_quiet_count<=0;
                        end
                        if(all_quiet) begin
                            if(all_quiet_count==3'd2) state<=HOLD;
                            else all_quiet_count<=all_quiet_count+1'b1;
                        end else all_quiet_count<=0;
                    end
                end
                HOLD:if(!want) begin
                    state<=RUN;main_halt_requested<=0;phi1_seen<=0;phi2_seen<=0;
                    main_quiet_count<=0;all_quiet_count<=0;
                end
                default:state<=RUN;
            endcase
        end
    end
endmodule
