// SPDX-License-Identifier: BSD-3-Clause
// Finite normal binary32 helpers for the pinned Taito En stream path. This
// path has no NaN, infinity or subnormal operands: raw signed20 samples,
// positive gain <=100/32, signed16 DSP outputs, and their bounded sum.
function automatic [31:0] gs_audio_pack(input sign,input [49:0] magnitude,input signed [10:0] base);
    reg [63:0] scan;
    reg [5:0] top,shift;
    reg [24:0] rounded;
    reg guard_bit,sticky;
    reg [49:0] mask;
    reg [7:0] exponent;
    begin
        scan={14'b0,magnitude};top=0;
        if(|scan[63:32])begin scan=scan>>32;top=top+32;end
        if(|scan[31:16])begin scan=scan>>16;top=top+16;end
        if(|scan[15:8])begin scan=scan>>8;top=top+8;end
        if(|scan[7:4])begin scan=scan>>4;top=top+4;end
        if(|scan[3:2])begin scan=scan>>2;top=top+2;end
        if(scan[1])top=top+1'b1;
        shift=top>23 ? top-23:0;
        guard_bit=0;sticky=0;mask=0;
        if(top>23)begin
            rounded=magnitude>>shift;
            guard_bit=magnitude[shift-1'b1];
            mask=(50'd1<<(shift-1'b1))-1'b1;
            sticky=|(magnitude&mask);
            rounded=rounded+(guard_bit && (sticky || rounded[0]));
        end else rounded=magnitude<<(23-top);
        if(rounded[24])begin rounded=rounded>>1;top=top+1'b1;end
        exponent=$signed({1'b0,top})+base+11'sd127;
        gs_audio_pack=magnitude==0 ? 32'b0:{sign,exponent,rounded[22:0]};
    end
endfunction

function automatic [15:0] gs_audio_pcm(input [31:0] value);
    reg [23:0] magnitude;
    reg [4:0] shift;
    begin
        shift=8'd135-value[30:23];
        magnitude={1'b1,value[22:0]}>>shift;
        if(value[30:23]<112)gs_audio_pcm=0;
        else if(value[30:23]>=127)gs_audio_pcm=value[31] ? 16'h8000:16'h7fff;
        else gs_audio_pcm=value[31] ? -magnitude[15:0]:magnitude[15:0];
    end
endfunction

function automatic [31:0] gs_audio_add(input [31:0] a,input [31:0] b);
    reg [31:0] larger,smaller;
    reg [27:0] lhs,rhs;
    reg [28:0] magnitude;
    reg [7:0] distance;
    reg [27:0] mask;
    reg signed [10:0] base;
    begin
        larger=a[30:0]>=b[30:0] ? a:b;smaller=a[30:0]>=b[30:0] ? b:a;
        distance=larger[30:23]-smaller[30:23];
        lhs=larger[30:23]==0 ? 0:{1'b0,1'b1,larger[22:0],3'b000};
        rhs=smaller[30:23]==0 ? 0:{1'b0,1'b1,smaller[22:0],3'b000};
        if(distance>=28)rhs=rhs!=0;
        else if(distance!=0)begin
            mask=(28'd1<<distance)-1'b1;
            rhs=(rhs>>distance)|((rhs&mask)!=0);
        end
        magnitude=larger[31]==smaller[31] ? {1'b0,lhs}+{1'b0,rhs}:{1'b0,lhs}-{1'b0,rhs};
        base=$signed({1'b0,larger[30:23]})-11'sd153;
        gs_audio_add=gs_audio_pack(larger[31],{21'b0,magnitude},base);
    end
endfunction
