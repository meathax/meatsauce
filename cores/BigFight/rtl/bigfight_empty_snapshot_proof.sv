// Isolated candidate. Feed actual accepted snapshot responses and RAM writes.
// No additional RAM read port, renderer state change, or PCB latch claim.
module bigfight_empty_snapshot_proof (
    input logic clk, reset, invalidate_epoch_i,
    input logic [15:0] frame_epoch_i,
    input logic snapshot_accept_i,
    input logic [15:0] snapshot_epoch_i, snapshot_control_i,
    input logic snapshot_rsp_accept_i,
    input logic [15:0] snapshot_rsp_data_i,
    input logic head_write_accept_i,
    input logic head_write_bank_i,
    input logic [15:0] head_write_data_i,
    input logic head_write_uds_n_i, head_write_lds_n_i,
    input logic [15:0] live_control_i, candidate_control_i,
    output logic safe_bank_only_change_o,
    output logic protocol_fault_o, diverged_population_fault_o
);
    logic active_q, complete_q, snapshot_empty_q;
    logic [11:0] count_q;
    logic [15:0] epoch_q, control_q;
    logic [15:0] heads_q[0:1], heads_next[0:1];
    logic [1:0] known_q[0:1], known_next[0:1];
    wire proof_valid = complete_q && epoch_q==frame_epoch_i && snapshot_empty_q;
    wire both_empty = known_next[0]==2'b11 && known_next[1]==2'b11 &&
                      heads_next[0]==16'hffff && heads_next[1]==16'hffff;
    always_comb begin
        for(integer bank=0;bank<2;bank=bank+1)begin
            heads_next[bank]=heads_q[bank];known_next[bank]=known_q[bank];
        end
        if(head_write_accept_i)begin
            if(!head_write_uds_n_i)begin
                heads_next[head_write_bank_i][15:8]=head_write_data_i[15:8];
                known_next[head_write_bank_i][1]=1;
            end
            if(!head_write_lds_n_i)begin
                heads_next[head_write_bank_i][7:0]=head_write_data_i[7:0];
                known_next[head_write_bank_i][0]=1;
            end
        end
        safe_bank_only_change_o = !reset && !invalidate_epoch_i && !snapshot_accept_i &&
            !active_q && !protocol_fault_o && !diverged_population_fault_o && proof_valid &&
            both_empty && ((candidate_control_i ^ control_q)==16'h1000);
    end
    always_ff @(posedge clk)begin
        if(reset)begin
            active_q<=0;complete_q<=0;snapshot_empty_q<=0;count_q<=0;
            epoch_q<=0;control_q<=0;protocol_fault_o<=0;diverged_population_fault_o<=0;
            for(integer bank=0;bank<2;bank=bank+1)begin heads_q[bank]<=0;known_q[bank]<=0;end
        end else begin
            for(integer bank=0;bank<2;bank=bank+1)begin
                heads_q[bank]<=heads_next[bank];known_q[bank]<=known_next[bank];
            end
            if(invalidate_epoch_i)begin complete_q<=0;active_q<=0;snapshot_empty_q<=0;end
            if(snapshot_accept_i)begin
                if(active_q || snapshot_rsp_accept_i)protocol_fault_o<=1;
                active_q<=1;complete_q<=0;snapshot_empty_q<=0;count_q<=0;
                epoch_q<=snapshot_epoch_i;control_q<=snapshot_control_i;
            end else if(snapshot_rsp_accept_i)begin
                if(!active_q || invalidate_epoch_i)protocol_fault_o<=1;
                else begin
                    if(count_q==12'd4)snapshot_empty_q<=(snapshot_rsp_data_i==16'hffff);
                    if(count_q==12'h803)begin active_q<=0;complete_q<=1;end
                    else count_q<=count_q+1'b1;
                end
            end
            // Conservative fault: either head becomes populated while the
            // live bank differs from the cached empty snapshot's bank.
            if(!invalidate_epoch_i && !snapshot_accept_i && proof_valid && live_control_i[12]!=control_q[12] &&
               head_write_accept_i && !both_empty)diverged_population_fault_o<=1;
        end
    end
endmodule
