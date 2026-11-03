// SPDX-License-Identifier: GPL-3.0-or-later
// Repeat only on native completed input samples.
module midres_weapon_fire #(parameter PLAYER2=0)(
    input wire clk, reset, paused, enable,
    input wire physical_fire, stick_fire, up,
    input wire commit,
    input wire [23:1] address,
    input wire [7:0] data,
    output wire fire
);
    localparam [23:1] WEAPON=(PLAYER2 ? 24'h1021fc : 24'h102180)>>1;
    localparam [23:1] SAMPLE=(PLAYER2 ? 24'h102222 : 24'h1021a6)>>1;
    localparam [23:1] BACKPACK=(PLAYER2 ? 24'h102212 : 24'h102196)>>1;
    localparam [23:1] COUNT=(PLAYER2 ? 24'h1021fe : 24'h102182)>>1;
    localparam [23:1] SLOTS=(PLAYER2 ? 24'h1024aa : 24'h10226a)>>1;
    reg [7:0] weapon=0;
    reg [7:0] backpack=0;
    reg [3:0] cadence_phase=0;
    reg [7:0] projectile_count=0;
    reg [11:0] tracked=0;
    reg [5:0] slot_age [0:11];
    reg [5:0] observed_life=24;
    reg physical_last=0, secondary=0;
    reg sampled_fire=0, manual_release=0;
    wire request=physical_fire || stick_fire;
    // The original game clears this ID on the last round, death and item loss.
    // Its pickup routine publishes a new ID and ammunition before the next poll.
    wire manual_backpack=up && backpack!=0;
    wire manual_fire=(physical_fire && (secondary || !physical_last));
    // Full Auto (1) and Fire (3) already accept a continuous held input.
    // Unknown weapon IDs fail safe to held input rather than manufactured presses.
    wire repeat_weapon=weapon==0 || weapon==2 || weapon==4;
    // Space volleys across the native projectile lifetime instead of filling
    // every slot immediately and waiting for the whole burst to expire.
    // Counts are completed game input samples, NOT fabric clocks or video ticks.
    wire [3:0] repeat_period=weapon==0 ? 4'd6 : weapon==2 ? 4'd11 : 4'd8;
    wire native_room=weapon==0 ? projectile_count<4 :
                     weapon==2 ? projectile_count<10 : projectile_count<9;
    reg retiring, sibling;
    reg [3:0] retiring_index;
    reg [5:0] retiring_age;
    wire [5:0] effective_life;
    wire [5:0] life_tree [1:31];
    genvar age_leaf, age_branch;
    generate
        for(age_leaf=0;age_leaf<12;age_leaf=age_leaf+1) begin: g_life_bound
            assign life_tree[16+age_leaf]=!tracked[age_leaf] ? 6'd0 :
                slot_age[age_leaf]==63 ? 6'd63 : slot_age[age_leaf]+1'b1;
        end
        for(age_branch=1;age_branch<16;age_branch=age_branch+1) begin: g_life_max
            assign life_tree[age_branch]=life_tree[age_branch*2]>=life_tree[age_branch*2+1] ?
                life_tree[age_branch*2] : life_tree[age_branch*2+1];
        end
    endgenerate
    assign life_tree[28]=observed_life;
    assign life_tree[29]=0;
    assign life_tree[30]=0;
    assign life_tree[31]=0;
    assign effective_life=life_tree[1];
    integer n,i;
    // All pellets born between two input samples share an age. Learn a volley's
    // lifetime only after its LAST pellet disappears, including hit animation.
    // Older live volleys bound acceleration even if a newer shot hits early.
    always @* begin
        retiring=0;retiring_index=0;retiring_age=0;
        for(n=0;n<12;n=n+1) begin
            if(commit && address==SLOTS+n*12 && tracked[n] && !data[7]) begin
                retiring=1;retiring_index=n;retiring_age=slot_age[n];
            end
        end
        sibling=0;
        for(n=0;n<12;n=n+1)
            if(tracked[n] && n!=retiring_index && slot_age[n]==retiring_age) sibling=1;
    end
    // Rifle sustains four individual bullets; spread and Shot Gun use a
    // conservative three-volley budget. Never request more than one press plus
    // one sampled release: two input updates is the original manual limit.
    wire [6:0] estimated_period=weapon==0 ? ({1'b0,effective_life}+7'd3)>>2 :
                                                       ({1'b0,effective_life}+7'd2)/7'd3;
    wire [3:0] adaptive_period=estimated_period<2 ? 4'd2 :
                              estimated_period>repeat_period ? repeat_period : estimated_period[3:0];
    always @(posedge clk) begin
        if(reset) begin
            weapon<=0;backpack<=0;cadence_phase<=0;physical_last<=0;secondary<=0;
            projectile_count<=0;tracked<=0;observed_life<=24;
            for(i=0;i<12;i=i+1) slot_age[i]<=0;
            sampled_fire<=0;manual_release<=0;
        end else if(!paused) begin
            physical_last<=physical_fire;
            if(commit && address==SAMPLE) sampled_fire<=data[4];
            if(!manual_backpack || !physical_fire) begin secondary<=0;manual_release<=0;end
            else if(!physical_last) begin secondary<=1;manual_release<=sampled_fire;end
            else if(commit && address==SAMPLE && !data[4]) manual_release<=0;
            if(commit && address==COUNT) projectile_count<=data;
            if(commit && address==WEAPON) begin
                weapon<=data;tracked<=0;observed_life<=data==2 ? 6'd33 : 6'd24;
                for(i=0;i<12;i=i+1) slot_age[i]<=0;
            end else begin
                for(i=0;i<12;i=i+1) begin
                    if(commit && address==SAMPLE && tracked[i] && slot_age[i]!=63)
                        slot_age[i]<=slot_age[i]+1'b1;
                    if(commit && address==SLOTS+i*12 && repeat_weapon) begin
                        tracked[i]<=data[7];
                        if(data[7] && !tracked[i]) slot_age[i]<=0;
                    end
                end
                if(retiring && !sibling) observed_life<=retiring_age==63 ? 6'd63 : retiring_age+1'b1;
                if(!request || manual_backpack || !enable)
                    observed_life<=weapon==2 ? 6'd33 : 6'd24;
            end
            if(commit && address==BACKPACK) backpack<=data;
            if(!request || manual_backpack || !enable || !repeat_weapon ||
               (commit && address==WEAPON)) cadence_phase<=0;
            else if(commit && address==SAMPLE) begin
                if(cadence_phase==0) begin
                    if(native_room) cadence_phase<=1;
                end else if(cadence_phase>=adaptive_period-1'b1) cadence_phase<=0;
                else cadence_phase<=cadence_phase+1'b1;
            end
        end
    end
    // With a backpack, Up+Fire is manual. Stick demand never enters it;
    // entering Up with an already-held button requires release/repress first.
    assign fire=!reset && !paused && (manual_backpack ?
        (manual_fire && !manual_release && (secondary || !sampled_fire)) :
        (request && (!enable || !repeat_weapon || (cadence_phase==0 && native_room))));
endmodule
