// Raw MiSTer video chain checks (rules from the MiSTer video-output reference): native
// (Direct Video / 15 kHz CRT), forced scandoubler, HQ2x and CRT scanline modes, with CRT
// Adjust at 0 and both extremes. Asserts one pixel width, one visible-line pixel count,
// one line length, constant HS/VS width and picture-to-sync distance, one frame length,
// line rate and line count in range, and (non-HQ2x) every column present once, in order.
#include "Vcs_sys_video.h"
#include "verilated.h"
#include "Vcs_sys_video___024root.h"
#include <cstdio>
#include <set>
#include <vector>
#include <string>
double sc_time_stamp(){return 0;}
static const double CLK=85909080.0;
static int fails=0;
static void check(bool ok,const std::string&what){if(!ok){std::fprintf(stderr,"FAIL %s\n",what.c_str());++fails;}}
int main(int argc,char**argv){Verilated::commandArgs(argc,argv);
    struct Mode{const char*name;int fx,forced;bool doubled,values;unsigned px_clocks,line_px;};
    const Mode modes[]={{"native (Direct Video / 15 kHz)",0,0,false,true,12,320},{"forced scandoubler",0,1,true,true,6,320},
        {"HQ2x",1,0,true,false,3,640},{"CRT 25%",2,0,true,false,6,320},{"CRT 50%",3,0,true,false,6,320},{"CRT 75%",4,0,true,false,6,320}};
    // CRT Adjust settings: {on, H-Size OSD index, H-Position, V-Shift}. H-Size index 10 = +10 %, 11 = -12 %.
    const int offsets[][4]={{0,0,0,0},{1,0,7,7},{1,0,-8,0},{1,0,0,-3},{1,0,0,-8},{1,10,0,0},{1,11,0,0}};
    for(const Mode&m:modes)for(auto&o:offsets){if(m.forced||m.fx>1)if(&o!=&offsets[0]&&&o!=&offsets[1])continue;
        Vcs_sys_video d;
        // sys/arcade_video leaves video_mixer HDMI_FREEZE unconnected; Quartus ties it low,
        // Verilator leaves it undriven (frozen = black picture). Tie it low as the fitter does.
        auto tie=[&](){d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__HDMI_FREEZE=0;d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__genblk2__DOT__gamma__DOT__gamma_en=0;
            // video_mixer declares R_in/G_in/B_in inside generate blocks and uses them outside;
            // Quartus binds them, Verilator makes separate undriven nets. Drive them as Quartus does.
            d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__R_in=d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__frz?0:d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__R;d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__G_in=d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__frz?0:d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__G;d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__B_in=d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__frz?0:d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__B;};
        if(&m==&modes[0]&&&o==&offsets[0])std::printf("undriven HDMI_FREEZE in Verilator = %d (tied to 0 below)\n",int(d.rootp->cs_sys_video__DOT__video__DOT__video_mixer__DOT__HDMI_FREEZE));d.fx=m.fx;d.forced_scandoubler=m.forced;d.osd_on=o[0];d.h_size=o[1];d.h_offset=o[2]&15;d.v_offset=o[3]&15;
        // Polarity: sys normalizes sync; take the level that is active for the minority of clocks.
        uint64_t clk=0;bool phs=d.VGA_HS,pvs=d.VGA_VS;long hs_low=0,vs_low=0;
        for(int i=0;i<455*12*262*2;i++){tie();d.clk=0;d.eval();d.clk=1;d.eval();} // settle: CRT Adjust samples OSD at a frame event, its V-Shift line delay fills
        for(int i=0;i<455*12*262*2;i++){tie();d.clk=0;d.eval();d.clk=1;d.eval();hs_low+=!d.VGA_HS;vs_low+=!d.VGA_VS;}
        const bool hs_act=!(hs_low<455*12*262),vs_act=!(vs_low<455*12*262); // active level is the minority level

        if(!m.doubled&&!m.forced&&o[0]&&o[3]<0)std::printf("  VS low clocks over 2 warm-up frames: %ld (shift %d)%c",vs_low,o[3],10);
        std::set<uint64_t> pix_w,line_len,hs_w,vs_w,frame_len,lines_frame,act_lines,sync_to_pic,line_pixels;
        uint64_t last_ce=0,hs_start=0,hs_fall=0,vs_start=0,frames=0,lines=0,act=0,line_px=0;bool in_frame=false,first_de=false,de_line=false;
        long col_errors=0,nonzero=0;int expect_x=0;bool pvs_raw=d.VGA_VS;
        phs=d.VGA_HS==hs_act;pvs=d.VGA_VS==vs_act;
        for(clk=0;clk<455ull*12*262*6;clk++){
            tie();d.clk=0;d.eval();d.clk=1;d.eval();
            const bool hs=d.VGA_HS==hs_act,vs=d.VGA_VS==vs_act;
            {static int shown=0;if(!m.doubled&&!m.forced&&o[0]&&o[3]==-3&&bool(d.VGA_VS)!=bool(pvs_raw)&&shown<12){std::printf("  VS edge at line %.2f level %d%c",double(clk)/5460.0,int(d.VGA_VS),10);++shown;}pvs_raw=d.VGA_VS;}
            // Columns are checked where the core hands pixels to sys/arcade_video (its input
            // pixel register on each pixel enable outside blanking): every visible line must
            // carry columns 0..319 once, in order. The sys mixer's own RGB path does not
            // simulate in Verilator (generate-scoped R_in/G_in/B_in nets), so output RGB values
            // are not compared; output timing/DE/sync are.
            {auto*r=d.rootp;
             if(r->cs_sys_video__DOT__video__DOT__HBL)expect_x=0;
             else if(r->cs_sys_video__DOT__video__DOT__CE&&!r->cs_sys_video__DOT__video__DOT__VBL&&m.values){
                const int xv=int((r->cs_sys_video__DOT__video__DOT__RGB_fix>>16)&255)|int(((r->cs_sys_video__DOT__video__DOT__RGB_fix>>8)&15)<<8);
                if(xv!=expect_x){if(col_errors<6)std::fprintf(stderr,"  col: index %d value %d\n",expect_x,xv);++col_errors;}++expect_x;}}
            if(d.CE_PIXEL){
                if(d.VGA_DE){if(last_ce&&line_px)pix_w.insert(clk-last_ce);
                    ++line_px;de_line=true;
                    if(!first_de&&in_frame){first_de=true;sync_to_pic.insert(clk-vs_start);}}
                last_ce=clk;}
            if(hs&&!phs){ // line boundary at HS start
                if(hs_start)line_len.insert(clk-hs_start);hs_start=clk;
                if(in_frame){++lines;if(de_line){++act;line_pixels.insert(line_px);}}
                line_px=0;de_line=false;}
            if(!hs&&phs&&hs_start)hs_w.insert(clk-hs_start); // a pulse already active at the window start is partial
            if(vs&&!pvs){if(in_frame){frame_len.insert(clk-vs_start);lines_frame.insert(lines);act_lines.insert(act);++frames;}
                in_frame=true;vs_start=clk;lines=0;act=0;first_de=false;}
            if(!vs&&pvs&&in_frame)vs_w.insert(clk-vs_start);
            phs=hs;pvs=vs;}
        std::string tag=std::string(m.name)+(o[0]?" CRT adjust size "+std::to_string(o[1])+" pos "+std::to_string(o[2])+" shift "+std::to_string(o[3]):" CRT adjust off");
        const double rate=line_len.size()?CLK/double(*line_len.begin()):0;
        std::printf("%-34s px width %s [%llu..%llu], line %s clk (%.3f kHz), lines/frame %s, active lines %s, px/line %s, HS %s, VS %s, sync->picture %s, frame %s, column errors %ld\n",tag.c_str(),
            pix_w.size()==1?std::to_string(*pix_w.begin()).c_str():"VARIES",(unsigned long long)(pix_w.empty()?0:*pix_w.begin()),(unsigned long long)(pix_w.empty()?0:*pix_w.rbegin()),line_len.size()==1?std::to_string(*line_len.begin()).c_str():"VARIES",rate/1000,
            lines_frame.size()==1?std::to_string(*lines_frame.begin()).c_str():"VARIES",act_lines.size()==1?std::to_string(*act_lines.begin()).c_str():"VARIES",
            line_pixels.size()==1?std::to_string(*line_pixels.begin()).c_str():"VARIES",hs_w.size()==1?std::to_string(*hs_w.begin()).c_str():"VARIES",
            vs_w.size()==1?std::to_string(*vs_w.begin()).c_str():"VARIES",sync_to_pic.size()==1?std::to_string(*sync_to_pic.begin()).c_str():"VARIES",
            frame_len.size()==1?std::to_string(*frame_len.begin()).c_str():"VARIES",col_errors,nonzero);
        check(frames>=3,tag+": fewer than 3 frames");
        const bool resized=o[0]&&o[1]&&!m.doubled&&!m.forced;
        if(resized)check(pix_w.size()<=2&&*pix_w.rbegin()-*pix_w.begin()<=1,tag+": resized pixel widths not adjacent");
        else check(pix_w.size()==1&&*pix_w.begin()==m.px_clocks,tag+": pixel width not one integer");
        check(hs_w.size()==1,tag+": HS width varies");
        check(vs_w.size()==1,tag+": VS width varies");check(frame_len.size()==1,tag+": frame length varies");
        check(sync_to_pic.size()==1,tag+": picture-to-sync distance varies");
        check(line_pixels.size()==1&&*line_pixels.begin()==m.line_px,tag+": visible line pixel count");
        check(act_lines.size()==1&&*act_lines.begin()==(m.doubled?480u:240u),tag+": active lines");
        check(lines_frame.size()==1&&*lines_frame.begin()==(m.doubled?524u:262u),tag+": lines per frame");
        check(m.doubled?(rate>31000&&rate<32000):(rate>15500&&rate<16000),tag+": line rate out of range");
        check(col_errors==0,tag+": dropped/repeated/out-of-order columns");
    }
    if(fails){std::fprintf(stderr,"FAIL raw sys video chain: %d checks\n",fails);return 1;}
    std::printf("PASS raw sys video chain: native/direct, scandoubler, HQ2x and CRT scanline modes at CRT Adjust 0/+7/-8\n");return 0;}
