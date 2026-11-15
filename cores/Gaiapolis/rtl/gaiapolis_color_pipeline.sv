// SPDX-License-Identifier: GPL-3.0-or-later
// Gaiapolis ordered color pipeline; pinned donors remain unchanged.
// Exact MAME GX full32bit object keys and six-layer presort (including SUB2).
// Only the two front valid solids plus all accepted shadows are sufficient
// for this title's non-alpha sprite callback. Presets are raw1..3; keys carry
// zero-based shadow codes. Shadow slots arrive in descending complete order.
//
// 96MHz: snapshot C0, sort C1; six colors issue C2..7 and brighten C3..9.
// One iterative two-shadow RGB unit runs four clocks on each side of the front blend.
// Three tagged pixel contexts retain the unchanged C30 RGB/sync output.
// Palette bandwidth and accepted capture cadence remain unchanged.
// Grouped shadows use no additional palette reads. All inputs/effects snapshot
// together; early capture is rejected and sets sticky deadline_overrun.
//
// K054338 chip model (SiliconRE 054338 die notes, donors/siliconre/Konami/
// 054338/README.md; O. Galibert's register description, MAME discussion 109):
// - The K055555 sends only the two front pixels, so only the topmost visible
//   color mixes; every color below it is drawn opaque (its own mix code is
//   not used). Both titles write K338 CONTROL=0x01 (MI/SH/BR=0), which with
//   the boards' alpha inversion makes the front pixel the mix source.
// - Additive mode is under + top*(32-level)/32, saturated. The previous
//   front + under*level/31 scaled the wrong pixel, halving whatever sat
//   behind every additive Gaiapolis sprite (all three PBLEND slots are
//   additive level 16 in that title).
// - Brightness is one analog scale of the final RGB, chosen by the front
//   pixel's brightness code, not a per-layer gain before blending.
// An average-mode level of 31 now stays the front pixel (weight 0) instead of
// being removed, so the pixel behind it remains opaque as on the chip.
// RGB+sync publish C30 (one extra clock for the final brightness multiply).
module gaiapolis_color_pipeline (
    input wire monster,
    input wire [1:0] sprite_mix,
    input wire [7:0] roz_pen8,
    input logic clk, rst, cen_pxl,
    input logic we,
    input logic [3:0] addr,
    input logic [1:0] dsn,
    input logic [15:0] din,
    input logic [5:0] input_enables,
    input logic [7:0] layer_priority0, layer_priority1,
    input logic [7:0] layer_priority2, layer_priority3,
    input logic [11:0] layer_palette0, layer_palette1,
    input logic [11:0] layer_palette2, layer_palette3,
    input logic [8:0] lyrf_pxl, lyra_pxl, lyrb_pxl, lyrc_pxl,
    input logic [1:0] lyrf_mix, lyra_mix, lyrb_mix, lyrc_mix,
    input logic [7:0] tile_blend, tile_blend_on, brightness_code,
    input logic [3:0] osbri_code, // K55_OSBRI: OBJ [1:0], ROZ/SUB1 [3:2]
    input logic [9:0] sprite_pixel,
    input logic [31:0] sprite_order,
    input logic [7:0] shadow_ops_valid,
    input logic [15:0] shadow_ops_mode,
    input logic [255:0] shadow_ops_order,
    input logic [11:0] object_palette_base, roz_palette_base,
    input logic [7:0] roz_priority, unused_sub2_priority,
    input logic [4:0] roz_palette,
    input logic [3:0] roz_pen,
    input logic roz_valid,
    input logic [1:0] roz_mix,
    input logic hs_in, vs_in, hblank_in, vblank_in,
    output logic [11:0] palette_index,
    output logic palette_read,
    input logic [23:0] palette_rgb,
    output logic [3:1] transparent_mixes,
    output logic [7:0] red, green, blue,
    output logic pixel_valid, busy, deadline_overrun,
    output logic hs_out, vs_out, hblank_out, vblank_out
);
    // CPU priorities change on clk48 rising edges, which coincide with
    // alternate clk96 rising edges. Capture on the intervening falling edge
    // so the pixel snapshot has half a cycle of setup and hold separation.
    // With the related clocks this preserves the value seen at each rising
    // pixel edge while avoiding a bare 48-to-96 MHz register-to-register path.
    (* dont_retime *) logic [7:0] priority_half_q [0:4];
    always_ff @(negedge clk) begin
        priority_half_q[0] <= layer_priority0;
        priority_half_q[1] <= layer_priority1;
        priority_half_q[2] <= layer_priority2;
        priority_half_q[3] <= layer_priority3;
        priority_half_q[4] <= roz_priority;
    end
    logic [15:0] regs [0:15];
    logic [3:0] phase;
    typedef struct packed {
        logic valid, shadow;
        // Front weight /256: average 0..255 (255 exact opaque), additive
        // (32-level)*8 = 8..256.
        logic [8:0] alpha;
        logic additive;
        logic signed [8:0] shd_r, shd_g, shd_b;
        logic noclip;
    } effect_t;
    typedef struct packed {
        logic [31:0] key;
        logic [3:0] tie;
        logic [11:0] palette;
        logic [7:0] gain;
        effect_t effect;
    } candidate_t;
    candidate_t candidates [0:5], unsorted [0:5], ranked [0:5];
    logic [5:0] key_greater [0:5]; // key_greater[i][j]: i draws before j
    logic [5:0] is_top;
    logic [7:0] top_gain;
    logic [7:0] context_gain [0:2];
    logic [15:0] output_product_q [0:2];
    logic [7:0] curved_rgb [0:2];
    logic [23:0] output_rgb_selected;
    logic [7:0] output_gain_selected;
    logic [3:0] output_sync_selected;
    logic output_selected;
    wire [15:0] shared_output_product [0:2];
    logic [3:0] output_sync_q;
    logic output_pending_q;
    logic [7:0] curved_q [0:2];
    logic [7:0] gain_q;
    logic [3:0] sync_q1;
    logic sel_q;
    // Snapshot without a pixel-enable mux: the 48MHz inputs only drive this
    // shallow boundary. Rank comparisons and payload selection run at96MHz.
    (* dont_retime *) candidate_t unsorted_q [0:5];
    typedef struct packed {logic valid; logic signed [8:0] shd_r,shd_g,shd_b;} shadow_rgb_t;
    typedef struct packed {logic signed [8:0] r,g,b;} shadow_delta_t;
    (* dont_retime *) shadow_delta_t raw_shadow_presets_q [0:2];
    (* dont_retime *) logic [15:0] raw_shadow_modes_q;
    (* dont_retime *) logic [7:0] raw_shadow_valid_q;
    (* dont_retime *) logic [255:0] shadow_order_q;
    (* dont_retime *) logic packet_accept_q;
    logic [23:0] raw_background_q;
    logic [3:0] raw_sync_q;
    logic raw_noclip_q;
    logic [2:0] candidate_rank [0:5];
    logic [11:0] queue_palette [0:5];
    logic [5:0] queue_valid;
    logic [2:0] shadow_rank [0:7];
    (* dont_retime *) logic [2:0] shadow_rank_q [0:7];
    (* dont_retime *) logic [5:0] shadow_sort_key0_q [0:7],shadow_sort_key1_q [0:7];
    logic [5:0] shadow_sort_key0 [0:7],shadow_sort_key1 [0:7];
    logic [5:0] shadow_swap0,shadow_swap1;
    logic rank_valid_q;
    logic [1:0] sort_valid_q;
    (* dont_retime *) logic [2:0] shadow_token_q [0:7], after_token_q [0:7];
    logic [2:0] selected_token0, selected_token1;
    logic [5:0] is_under;
    shadow_delta_t direct_presets_q [0:2],after_presets_q [0:2],selected_presets [0:2];
    logic [15:0] direct_modes_q,after_modes_q;
    logic [7:0] direct_valid_q,after_valid_q;
    logic [1:0] selected_mode0,selected_mode1;
    shadow_rgb_t selected_shadow0,selected_shadow1;
    (* dont_retime *) shadow_rgb_t pair_shadow0_q,pair_shadow1_q;
    (* dont_retime *) logic [1:0] pair_mask_q;
    logic pair_prefetch,pair_after;
    logic [1:0] pair_step;
    logic [7:0] pre_mask_q, post_mask_q, after_mask_q;
    logic [2:0] front_slot, under_slot, front_slot_q, under_slot_q;
    logic front_valid, under_valid, front_valid_q, under_valid_q;
    typedef struct packed {logic [8:0] alpha; logic additive;} front_control_t;
    front_control_t front_effect, front_effect_q;
    logic [23:0] front_rgb_q, under_rgb_q;
    logic [23:0] launch_front, launch_under;
    logic [1:0] capture_context, frontend_context;
    logic [1:0] request_context, brightness_context;
    logic [2:0] request_slot, brightness_slot;
    logic request_valid, brightness_valid;
    logic [7:0] palette_q [0:2];
    logic [23:0] context_accumulator [0:2];
    logic [4:0] context_age [0:2];
    logic [3:0] context_sync [0:2];
    logic [2:0] context_active, context_noclip;
    (* dont_retime *) logic [23:0] rgb_q;
    logic [23:0] rgb_operand,rgb_result;
    logic [1:0] rgb_context_q, rgb_step_q, rgb_selected_context;
    logic rgb_active_q, rgb_done_q, rgb_after_q, rgb_noclip_q;
    logic rgb_command, rgb_selected_after;
    logic launch, product_valid_q,blend_valid_q;
    logic [1:0] blend_context_q;
    (* dont_retime *) logic [23:0] blended_rgb_q;
    logic [1:0] product_context_q;
    logic job_front_valid_q, job_opaque_q;
    logic [8:0] job_alpha_q, job_back_factor_q;
    logic [23:0] job_front_q, product_passthrough_q;
    logic product_passthrough_valid_q;
    logic [15:0] product_front_q [0:2];
    logic [16:0] product_back_q [0:2], product_sum [0:2];
    logic [23:0] blended_rgb;
    integer i, j;

    // Preserve the original last-matching-context priority, including invalid
    // overrun states. Multiplex before lookup/multiply, sharing three lanes.
    always_comb begin
        output_selected=0; output_rgb_selected=0;
        output_gain_selected=0; output_sync_selected=0;
        for(integer c=0;c<3;c=c+1) if(context_active[c] && context_age[c]==27) begin
            output_selected=1;
            output_rgb_selected=context_accumulator[c];
            output_gain_selected=context_gain[c];
            output_sync_selected=context_sync[c];
        end
    end
    genvar dac_channel;
    generate for(dac_channel=0;dac_channel<3;dac_channel=dac_channel+1) begin : g_dac_channel
        gaiapolis_dac_lut u_dac_lut(
            .x(output_rgb_selected[23-dac_channel*8 -: 8]),
            .o(curved_rgb[dac_channel])
        );
        assign shared_output_product[dac_channel]=curved_q[dac_channel]*gain_q;
    end endgenerate

    function automatic [1:0] tile_mix(input [1:0] attr_mix, internal_mix, internal_mask);
        tile_mix = attr_mix == 0 ? (internal_mix & internal_mask) :
                                  (attr_mix & ~internal_mask);
    endfunction
    function automatic [11:0] tile_palette(input [11:0] base, input [8:0] pixel);
        logic [11:0] group_bits, pen_bits, carry_bits, sum_bits;
        begin
            group_bits = monster ? {3'd0,pixel[8:5],5'd0} : {4'd0,pixel[8:5],4'd0};
            pen_bits = {7'd0,pixel[4:0]};
            // The callback ORs the base and color group before adding the pen.
            // Five-bit groups overlap base bit 8; adding them selects another palette.
            sum_bits = (base | group_bits) ^ pen_bits;
            carry_bits = ((base | group_bits) & pen_bits) << 1;
            tile_palette = sum_bits + carry_bits;
        end
    endfunction
    function automatic [7:0] select_gain(input [1:0] select_code);
        case (select_code)
            2'd1: select_gain = regs[11][7:0];
            2'd2: select_gain = regs[12][15:8];
            2'd3: select_gain = regs[12][7:0];
            default: select_gain = 8'hff;
        endcase
    endfunction
    function automatic candidate_t make_color(
        input [31:0] key, input [3:0] tie, input [11:0] palette,
        input valid, input [1:0] mix, input [7:0] gain);
        logic [5:0] raw_mix;
        logic [4:0] level;
        candidate_t value;
        begin
            raw_mix = 0;
            case (mix)
                2'd1: raw_mix = regs[13][5:0];
                2'd2: raw_mix = regs[14][13:8];
                2'd3: raw_mix = regs[14][5:0];
                default: begin end
            endcase
            level = 5'd31 - raw_mix[4:0];
            value = '0;
            value.key = key; value.tie = tie; value.palette = palette; value.gain = gain;
            value.effect.additive = mix != 0 && raw_mix[5];
            value.effect.alpha = mix == 0 ? 9'd255 :
                value.effect.additive ? {6'd32 - {1'b0,raw_mix[4:0]},3'd0} :
                                        {1'b0,level,level[4:2]};
            value.effect.valid = valid && regs[15][0];
            make_color = value;
        end
    endfunction



    always_comb begin
        transparent_mixes[1] = regs[13][5:0] == 6'h1f;
        transparent_mixes[2] = regs[14][13:8] == 6'h1f;
        transparent_mixes[3] = regs[14][5:0] == 6'h1f;
        // MAME's <= exchanges reverse equal-priority source IDs. Only
        // relative ties matter: priorities already occupy the complete key.
        // Fixed IDs preserve that order without serial sorting, including
        // the inactive SUB2 source; sprite/shadow ties remain above all layers.
        unsorted[0] = make_color(
            {priority_half_q[0],24'd0},4'd0,tile_palette(layer_palette0,lyrf_pxl),
            input_enables[0] && lyrf_pxl[4:0] != 0,
            tile_mix(lyrf_mix,tile_blend[1:0],tile_blend_on[1:0]),select_gain(brightness_code[1:0]));
        unsorted[1] = make_color(
            {priority_half_q[1],24'd0},4'd1,tile_palette(layer_palette1,lyra_pxl),
            input_enables[1] && lyra_pxl[4:0] != 0,
            tile_mix(lyra_mix,tile_blend[3:2],tile_blend_on[3:2]),select_gain(brightness_code[3:2]));
        unsorted[2] = make_color(
            {priority_half_q[2],24'd0},4'd2,tile_palette(layer_palette2,lyrb_pxl),
            input_enables[2] && lyrb_pxl[4:0] != 0,
            tile_mix(lyrb_mix,tile_blend[5:4],tile_blend_on[5:4]),select_gain(brightness_code[5:4]));
        unsorted[3] = make_color(
            {priority_half_q[3],24'd0},4'd3,tile_palette(layer_palette3,lyrc_pxl),
            input_enables[3] && lyrc_pxl[4:0] != 0,
            tile_mix(lyrc_mix,tile_blend[7:6],tile_blend_on[7:6]),select_gain(brightness_code[7:6]));
        unsorted[4] = make_color(
            sprite_order,4'd6,object_palette_base | {2'd0,sprite_pixel},
            input_enables[4] && (monster ? sprite_pixel[4:0] != 0 : sprite_pixel[3:0] != 0),sprite_mix,select_gain(osbri_code[1:0]));
        unsorted[5] = make_color(
            {priority_half_q[4],24'd0},4'd4,monster ? (roz_palette_base | {4'd0,roz_pen8}) : (roz_palette_base | {3'd0,roz_palette,roz_pen}),
            input_enables[5] && roz_valid && (monster ? roz_pen8 != 0 : roz_pen != 0),roz_mix,select_gain(osbri_code[3:2]));
        // Complete keys plus distinct tie ranks give every candidate a unique rank.
        // Parallel pair comparisons avoid cascading full payload exchanges.
        for(i=0;i<6;i=i+1)
            for(j=0;j<6;j=j+1)
                key_greater[i][j]={unsorted_q[i].key,unsorted_q[i].tie}>{unsorted_q[j].key,unsorted_q[j].tie};
        for(i=0;i<6;i=i+1) begin
            candidate_rank[i]=0;
            for(j=0;j<6;j=j+1)
                if(key_greater[j][i])
                    candidate_rank[i]=candidate_rank[i]+3'd1;
        end
        // The front pixel is the last valid color drawn (smallest complete
        // key). Only it mixes with what lies below; the rest are opaque.
        top_gain=0;
        for(i=0;i<6;i=i+1) begin
            is_top[i]=unsorted_q[i].effect.valid;
            for(j=0;j<6;j=j+1)
                if(unsorted_q[j].effect.valid && key_greater[i][j]) is_top[i]=1'b0;
            ranked[i]=unsorted_q[i];
            if(!is_top[i]) begin
                ranked[i].effect.alpha=9'd255;
                ranked[i].effect.additive=1'b0;
            end
            top_gain=top_gain | (unsorted_q[i].gain & {8{is_top[i]}});
        end
        if(is_top==0) top_gain=8'hff;
        for(i=0;i<6;i=i+1) begin
            candidates[i]='0;
            for(j=0;j<6;j=j+1)
                candidates[i]=candidates[i] | (ranked[j] & {$bits(candidate_t){candidate_rank[j]==3'(i)}});
        end
        for (j=0;j<8;j=j+1) begin
            // A shadow's tie7 wins equal complete keys. Its insertion group
            // is the number of strictly greater color keys, independently
            // of the sorted-payload crossbar and all layer tie ranks.
            shadow_rank[j] = 0;
            for (i=0;i<6;i=i+1)
                if (unsorted_q[i].key > shadow_order_q[j*32 +: 32])
                    shadow_rank[j] = shadow_rank[j] + 3'd1;
        end
    end

    always_ff @(posedge clk) begin
        packet_accept_q <= !rst && cen_pxl && phase == 0 && !packet_accept_q;
        for(integer q=0;q<6;q=q+1) unsorted_q[q] <= unsorted[q];
        raw_shadow_modes_q<=shadow_ops_mode;
        for(integer q=0;q<8;q=q+1)
            raw_shadow_valid_q[q]<=shadow_ops_valid[q] && shadow_ops_mode[q*2+:2]!=0 && regs[15][0] && input_enables[4];
        for(integer p=0;p<3;p=p+1)
            raw_shadow_presets_q[p]<={regs[2+3*p][8:0],regs[3+3*p][8:0],regs[4+3*p][8:0]};
        shadow_order_q <= shadow_ops_order;
        raw_background_q <= {regs[0][7:0],regs[1]};
        raw_sync_q <= {hs_in,vs_in,hblank_in,vblank_in};
        raw_noclip_q <= regs[15][5];
    end

    // Original analog brightness arithmetic and final output phase stay intact.
    function automatic [7:0] brightness_round(input [15:0] product);
        brightness_round = 8'((product+{8'd0,product[15:8]}+16'd1)>>8);
    endfunction
    function automatic [7:0] direct_channel(input [7:0] component,
        input signed [8:0] delta, input enabled, noclip);
        logic signed [9:0] sum;
        begin
            sum=$signed({2'b0,component})+$signed(delta);
            direct_channel=!enabled ? component : noclip ? sum[7:0] :
                sum[9] ? 8'd0 : sum[8] ? 8'd255 : sum[7:0];
        end
    endfunction
    function automatic [23:0] direct_pair(input [23:0] rgb,
        input shadow_rgb_t first, second, input [1:0] mask, input noclip);
        logic [23:0] middle;
        begin
            middle={direct_channel(rgb[23:16],first.shd_r,mask[0]&&first.valid,noclip),
                    direct_channel(rgb[15:8],first.shd_g,mask[0]&&first.valid,noclip),
                    direct_channel(rgb[7:0],first.shd_b,mask[0]&&first.valid,noclip)};
            direct_pair={direct_channel(middle[23:16],second.shd_r,mask[1]&&second.valid,noclip),
                         direct_channel(middle[15:8],second.shd_g,mask[1]&&second.valid,noclip),
                         direct_channel(middle[7:0],second.shd_b,mask[1]&&second.valid,noclip)};
        end
    endfunction
    always_comb begin
        front_slot=0; under_slot=0; front_valid=0; under_valid=0; front_effect='0;
        for(integer s=0;s<6;s=s+1) begin
            is_under[s]=unsorted_q[s].effect.valid && !is_top[s];
            for(integer q=0;q<6;q=q+1)
                if(unsorted_q[q].effect.valid && !is_top[q] && key_greater[s][q]) is_under[s]=0;
            front_valid=front_valid | is_top[s]; under_valid=under_valid | is_under[s];
            front_slot=front_slot | (candidate_rank[s] & {3{is_top[s]}});
            under_slot=under_slot | (candidate_rank[s] & {3{is_under[s]}});
            front_effect=front_effect | ({unsorted_q[s].effect.alpha,unsorted_q[s].effect.additive} & {10{is_top[s]}});
        end
        launch=brightness_valid && brightness_slot==5;
        launch_front=front_rgb_q; launch_under=under_rgb_q;
        // Slot5 completes at this edge; retain the original palette capture
        // timestamp and explicitly forward it into the direct-color job.
        if(brightness_valid && front_valid_q && brightness_slot==front_slot_q)
            launch_front={palette_q[0],palette_q[1],palette_q[2]};
        if(brightness_valid && under_valid_q && brightness_slot==under_slot_q)
            launch_under={palette_q[0],palette_q[1],palette_q[2]};
        rgb_command=launch || blend_valid_q;
        rgb_selected_after=rgb_command ? blend_valid_q : rgb_after_q;
        rgb_selected_context=rgb_command ? (blend_valid_q ? blend_context_q : brightness_context) : rgb_context_q;
        rgb_operand=rgb_command ? (blend_valid_q ? blended_rgb_q : launch_under) : rgb_q;
        // C8 prefetch for C9 first pass; C14 prefetch for C15 after pass.
        // Active clocks look ahead to the NEXT pair, independently of RGB.
        pair_prefetch=(request_valid && request_slot==5) || product_valid_q || rgb_command || (rgb_active_q && rgb_step_q<3);
        pair_after=product_valid_q || blend_valid_q || (rgb_active_q && rgb_after_q);
        pair_step=((request_valid && request_slot==5) || product_valid_q) ? 2'd0 : rgb_command ? 2'd1 : rgb_step_q+2'd1;
        selected_token0=pair_after ? after_token_q[{pair_step,1'b0}] : shadow_token_q[{pair_step,1'b0}];
        selected_token1=pair_after ? after_token_q[{pair_step,1'b1}] : shadow_token_q[{pair_step,1'b1}];
        selected_mode0=pair_after ? after_modes_q[{selected_token0,1'b0}+:2] : direct_modes_q[{selected_token0,1'b0}+:2];
        selected_mode1=pair_after ? after_modes_q[{selected_token1,1'b0}+:2] : direct_modes_q[{selected_token1,1'b0}+:2];
        for(integer p=0;p<3;p=p+1)
            selected_presets[p]=pair_after ? after_presets_q[p] : direct_presets_q[p];
        selected_shadow0='0; selected_shadow1='0;
        selected_shadow0.valid=pair_after ? after_valid_q[selected_token0] : direct_valid_q[selected_token0];
        selected_shadow1.valid=pair_after ? after_valid_q[selected_token1] : direct_valid_q[selected_token1];
        case(selected_mode0)
            1:selected_shadow0[26:0]=selected_presets[0];
            2:selected_shadow0[26:0]=selected_presets[1];
            3:selected_shadow0[26:0]=selected_presets[2];
            default:begin end
        endcase
        case(selected_mode1)
            1:selected_shadow1[26:0]=selected_presets[0];
            2:selected_shadow1[26:0]=selected_presets[1];
            3:selected_shadow1[26:0]=selected_presets[2];
            default:begin end
        endcase
        rgb_result=direct_pair(rgb_operand,pair_shadow0_q,pair_shadow1_q,pair_mask_q,
            rgb_command ? context_noclip[rgb_selected_context] : rgb_noclip_q);
    end
    always_comb begin
        for(integer c=0;c<3;c=c+1) begin
            product_sum[c]={1'b0,product_front_q[c]}+product_back_q[c];
            blended_rgb[23-c*8-:8]=product_passthrough_valid_q ? product_passthrough_q[23-c*8-:8] :
                product_sum[c][16] ? 8'hff : product_sum[c][15:8];
        end
    end

    // C1 captures ranks from the original C0 snapshot. Later stages
    // never reread continuously changing unsorted_q/shadow_order_q metadata.
    always_comb begin
        shadow_swap0=0;
        for(integer s=0;s<8;s=s+1) shadow_sort_key0[s]={shadow_rank_q[s],3'(s)};
        if(shadow_sort_key0[0]>shadow_sort_key0[1]) begin
            shadow_swap0=shadow_sort_key0[0]; shadow_sort_key0[0]=shadow_sort_key0[1]; shadow_sort_key0[1]=shadow_swap0;
        end
        if(shadow_sort_key0[2]>shadow_sort_key0[3]) begin
            shadow_swap0=shadow_sort_key0[2]; shadow_sort_key0[2]=shadow_sort_key0[3]; shadow_sort_key0[3]=shadow_swap0;
        end
        if(shadow_sort_key0[4]>shadow_sort_key0[5]) begin
            shadow_swap0=shadow_sort_key0[4]; shadow_sort_key0[4]=shadow_sort_key0[5]; shadow_sort_key0[5]=shadow_swap0;
        end
        if(shadow_sort_key0[6]>shadow_sort_key0[7]) begin
            shadow_swap0=shadow_sort_key0[6]; shadow_sort_key0[6]=shadow_sort_key0[7]; shadow_sort_key0[7]=shadow_swap0;
        end
        if(shadow_sort_key0[0]>shadow_sort_key0[2]) begin
            shadow_swap0=shadow_sort_key0[0]; shadow_sort_key0[0]=shadow_sort_key0[2]; shadow_sort_key0[2]=shadow_swap0;
        end
        if(shadow_sort_key0[1]>shadow_sort_key0[3]) begin
            shadow_swap0=shadow_sort_key0[1]; shadow_sort_key0[1]=shadow_sort_key0[3]; shadow_sort_key0[3]=shadow_swap0;
        end
        if(shadow_sort_key0[4]>shadow_sort_key0[6]) begin
            shadow_swap0=shadow_sort_key0[4]; shadow_sort_key0[4]=shadow_sort_key0[6]; shadow_sort_key0[6]=shadow_swap0;
        end
        if(shadow_sort_key0[5]>shadow_sort_key0[7]) begin
            shadow_swap0=shadow_sort_key0[5]; shadow_sort_key0[5]=shadow_sort_key0[7]; shadow_sort_key0[7]=shadow_swap0;
        end
        if(shadow_sort_key0[1]>shadow_sort_key0[2]) begin
            shadow_swap0=shadow_sort_key0[1]; shadow_sort_key0[1]=shadow_sort_key0[2]; shadow_sort_key0[2]=shadow_swap0;
        end
        if(shadow_sort_key0[5]>shadow_sort_key0[6]) begin
            shadow_swap0=shadow_sort_key0[5]; shadow_sort_key0[5]=shadow_sort_key0[6]; shadow_sort_key0[6]=shadow_swap0;
        end
        if(shadow_sort_key0[0]>shadow_sort_key0[4]) begin
            shadow_swap0=shadow_sort_key0[0]; shadow_sort_key0[0]=shadow_sort_key0[4]; shadow_sort_key0[4]=shadow_swap0;
        end
        if(shadow_sort_key0[3]>shadow_sort_key0[7]) begin
            shadow_swap0=shadow_sort_key0[3]; shadow_sort_key0[3]=shadow_sort_key0[7]; shadow_sort_key0[7]=shadow_swap0;
        end
    end
    always_comb begin
        shadow_swap1=0;
        for(integer s=0;s<8;s=s+1) shadow_sort_key1[s]=shadow_sort_key0_q[s];
        if(shadow_sort_key1[1]>shadow_sort_key1[5]) begin
            shadow_swap1=shadow_sort_key1[1]; shadow_sort_key1[1]=shadow_sort_key1[5]; shadow_sort_key1[5]=shadow_swap1;
        end
        if(shadow_sort_key1[2]>shadow_sort_key1[6]) begin
            shadow_swap1=shadow_sort_key1[2]; shadow_sort_key1[2]=shadow_sort_key1[6]; shadow_sort_key1[6]=shadow_swap1;
        end
        if(shadow_sort_key1[1]>shadow_sort_key1[4]) begin
            shadow_swap1=shadow_sort_key1[1]; shadow_sort_key1[1]=shadow_sort_key1[4]; shadow_sort_key1[4]=shadow_swap1;
        end
        if(shadow_sort_key1[3]>shadow_sort_key1[6]) begin
            shadow_swap1=shadow_sort_key1[3]; shadow_sort_key1[3]=shadow_sort_key1[6]; shadow_sort_key1[6]=shadow_swap1;
        end
        if(shadow_sort_key1[2]>shadow_sort_key1[4]) begin
            shadow_swap1=shadow_sort_key1[2]; shadow_sort_key1[2]=shadow_sort_key1[4]; shadow_sort_key1[4]=shadow_swap1;
        end
        if(shadow_sort_key1[3]>shadow_sort_key1[5]) begin
            shadow_swap1=shadow_sort_key1[3]; shadow_sort_key1[3]=shadow_sort_key1[5]; shadow_sort_key1[5]=shadow_swap1;
        end
        if(shadow_sort_key1[3]>shadow_sort_key1[4]) begin
            shadow_swap1=shadow_sort_key1[3]; shadow_sort_key1[3]=shadow_sort_key1[4]; shadow_sort_key1[4]=shadow_swap1;
        end
    end
    always_ff @(posedge clk) begin
        if(rst) begin rank_valid_q<=0; sort_valid_q<=0; end
        else begin
            rank_valid_q<=packet_accept_q;
            sort_valid_q<={sort_valid_q[0],rank_valid_q};
            if(packet_accept_q) for(integer s=0;s<8;s=s+1) shadow_rank_q[s]<=shadow_rank[s];
            if(rank_valid_q) for(integer s=0;s<8;s=s+1) shadow_sort_key0_q[s]<=shadow_sort_key0[s];
            if(sort_valid_q[0]) for(integer s=0;s<8;s=s+1) shadow_sort_key1_q[s]<=shadow_sort_key1[s];
            if(sort_valid_q[1]) for(integer s=0;s<8;s=s+1) begin
                shadow_token_q[s]<=shadow_sort_key1_q[s][2:0];
                pre_mask_q[s]<=(!under_valid_q || shadow_sort_key1_q[s][5:3]>under_slot_q) && (!front_valid_q || shadow_sort_key1_q[s][5:3]<=front_slot_q);
                post_mask_q[s]<=front_valid_q && shadow_sort_key1_q[s][5:3]>front_slot_q;
            end
        end
    end

    always_comb begin
        palette_index = 0; palette_read = 0;
        if (phase >= 1 && phase <= 6) begin
            palette_index = queue_palette[phase-1];
            palette_read = queue_valid[phase-1];
        end
        busy = phase != 0 || packet_accept_q;
    end
    always_ff @(posedge clk) begin
        if (rst)
            for (integer r=0;r<16;r=r+1) regs[r] <= 0;
        else if (we) begin
            if (!dsn[1]) regs[addr][15:8] <= din[15:8];
            if (!dsn[0]) regs[addr][7:0] <= din[7:0];
        end
    end
    // One iterative two-shadow RGB unit runs twice: shadows below the front, then
    // the original blend, then shadows above the front. Discarded opaque colors never
    // contribute. The frontend's six palette requests and gain snapshot do
    // not move. Earliest accepted packet spacing is11 clocks; parameters are
    // consumed before their same-edge nonblocking replacement. Rank C1,
    // sort C2/C3, token/mask C4; coefficient prefetch C8..11/C14..17,
    // RGB C9..12/C15..18, blend C13/C14, commit C19; publish stays C30.
    always_ff @(posedge clk) begin
        if(rst) begin
            phase<=0; capture_context<=0; frontend_context<=0;
            request_context<=0; request_slot<=0; request_valid<=0;
            brightness_context<=0; brightness_slot<=0; brightness_valid<=0;
            rgb_active_q<=0; rgb_done_q<=0; product_valid_q<=0; blend_valid_q<=0;
            output_pending_q<=0; output_sync_q<=0; sel_q<=0; gain_q<=0; sync_q1<=0;
            for(integer c=0;c<3;c=c+1) curved_q[c]<=0;
            context_active<=0; context_noclip<=0;
            red<=0; green<=0; blue<=0; pixel_valid<=0; deadline_overrun<=0;
            hs_out<=0; vs_out<=0; hblank_out<=1; vblank_out<=1;
            for(integer c=0;c<3;c=c+1) begin
                context_accumulator[c]<=0; context_age[c]<=0; context_sync[c]<=0;
                palette_q[c]<=0; output_product_q[c]<=0; context_gain[c]<=8'hff;
            end
        end else begin
            pixel_valid<=0;
            if(phase!=0) phase<=phase==9 ? 4'd0 : phase+4'd1;
            output_pending_q<=0;
            for(integer c=0;c<3;c=c+1) if(context_active[c]) begin
                context_age[c]<=context_age[c]+5'd1;
                if(context_age[c]==27) context_active[c]<=0;
            end
            sel_q<=output_selected;
            if(output_selected) begin
                for(integer c=0;c<3;c=c+1) curved_q[c]<=curved_rgb[c];
                gain_q<=output_gain_selected; sync_q1<=output_sync_selected;
            end
            if(sel_q) begin
                for(integer c=0;c<3;c=c+1) output_product_q[c]<=shared_output_product[c];
                output_sync_q<=sync_q1; output_pending_q<=1;
            end
            if(output_pending_q) begin
                {red,green,blue}<={brightness_round(output_product_q[0]),
                                  brightness_round(output_product_q[1]),
                                  brightness_round(output_product_q[2])};
                {hs_out,vs_out,hblank_out,vblank_out}<=output_sync_q;
                pixel_valid<=1;
            end
            request_valid<=phase>=1 && phase<=6;
            if(phase>=1 && phase<=6) begin
                request_context<=frontend_context; request_slot<=3'(phase-1);
            end
            brightness_valid<=request_valid;
            brightness_context<=request_context; brightness_slot<=request_slot;
            if(request_valid) for(integer c=0;c<3;c=c+1) palette_q[c]<=palette_rgb[23-c*8-:8];
            if(brightness_valid) begin
                if(front_valid_q && brightness_slot==front_slot_q) front_rgb_q<={palette_q[0],palette_q[1],palette_q[2]};
                if(under_valid_q && brightness_slot==under_slot_q) under_rgb_q<={palette_q[0],palette_q[1],palette_q[2]};
            end
            if(pair_prefetch) begin
                pair_shadow0_q<=selected_shadow0; pair_shadow1_q<=selected_shadow1;
                pair_mask_q<=pair_after ? after_mask_q[{pair_step,1'b0}+:2] : pre_mask_q[{pair_step,1'b0}+:2];
            end
            blend_valid_q<=product_valid_q;
            if(product_valid_q) begin blended_rgb_q<=blended_rgb; blend_context_q<=product_context_q; end
            rgb_done_q<=0;
            if(rgb_command) begin
                rgb_q<=rgb_result; rgb_active_q<=1; rgb_step_q<=1;
                rgb_context_q<=rgb_selected_context; rgb_after_q<=rgb_selected_after;
                rgb_noclip_q<=context_noclip[rgb_selected_context];
            end else if(rgb_active_q) begin
                rgb_q<=rgb_result;
                if(rgb_step_q==3) begin rgb_active_q<=0; rgb_done_q<=1; end
                else rgb_step_q<=rgb_step_q+2'd1;
            end
            if(launch) begin
                job_front_q<=launch_front; job_front_valid_q<=front_valid_q;
                job_alpha_q<=front_effect_q.alpha;
                job_back_factor_q<=front_effect_q.additive ? 9'd256 : 9'd256-front_effect_q.alpha;
                job_opaque_q<=front_effect_q.alpha==255 && !front_effect_q.additive;
                after_mask_q<=post_mask_q;
                for(integer p=0;p<3;p=p+1) after_presets_q[p]<=direct_presets_q[p];
                after_modes_q<=direct_modes_q; after_valid_q<=direct_valid_q;
                for(integer s=0;s<8;s=s+1) after_token_q[s]<=shadow_token_q[s];
            end
            product_valid_q<=rgb_done_q && !rgb_after_q; product_context_q<=rgb_context_q;
            product_passthrough_valid_q<=!job_front_valid_q || job_opaque_q;
            product_passthrough_q<=job_front_valid_q ? job_front_q : rgb_q;
            for(integer c=0;c<3;c=c+1) begin
                product_front_q[c]<=job_front_q[23-c*8-:8]*job_alpha_q;
                product_back_q[c]<=rgb_q[23-c*8-:8]*job_back_factor_q;
            end
            if(rgb_done_q && rgb_after_q) context_accumulator[rgb_context_q]<=rgb_q;

            if(packet_accept_q) begin
                frontend_context<=capture_context;
                capture_context<=capture_context==2 ? 2'd0 : capture_context+2'd1;
                context_active[capture_context]<=1; context_age[capture_context]<=0;
                context_accumulator[capture_context]<=raw_background_q;
                context_sync[capture_context]<=raw_sync_q; context_noclip[capture_context]<=raw_noclip_q;
                context_gain[capture_context]<=top_gain; phase<=1;
                front_slot_q<=front_slot; under_slot_q<=under_slot;
                front_valid_q<=front_valid; under_valid_q<=under_valid; front_effect_q<=front_effect;
                front_rgb_q<=0; under_rgb_q<=raw_background_q;
                for(integer s=0;s<6;s=s+1) begin
                    queue_palette[s]<=candidates[s].palette; queue_valid[s]<=candidates[s].effect.valid;
                end
                for(integer p=0;p<3;p=p+1) direct_presets_q[p]<=raw_shadow_presets_q[p];
                direct_modes_q<=raw_shadow_modes_q; direct_valid_q<=raw_shadow_valid_q;

            end
            if(cen_pxl && busy) deadline_overrun<=1;
        end
    end
`ifdef VERILATOR
    logic pair_prefetched_debug;
    always @(posedge clk) begin
        if(rst) pair_prefetched_debug<=0;
        else begin
            pair_prefetched_debug<=pair_prefetch;
            if(rgb_command) assert(!rgb_active_q && !rgb_done_q) else $fatal(1,"RGB job occupancy collision");
            if(rgb_command || rgb_active_q) assert(pair_prefetched_debug) else $fatal(1,"Missing one-clock coefficient lookahead");
            if(request_valid && request_slot==5) assert(context_age[request_context]==6) else $fatal(1,"First prefetch phase");
            if(launch) assert(context_age[brightness_context]==7) else $fatal(1,"First RGB phase");
            if(product_valid_q) assert(context_age[product_context_q]==12) else $fatal(1,"Blend register phase");
            if(blend_valid_q) assert(context_age[blend_context_q]==13) else $fatal(1,"After RGB phase");
            if(rgb_done_q && rgb_after_q) assert(context_age[rgb_context_q]==17) else $fatal(1,"RGB commit phase");
        end
    end
`endif
endmodule
