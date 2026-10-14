// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic native raster tests the product frontend without rerunning the CPUs.
#include "Vn8080_video.h"
#include "verilated.h"
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
static unsigned pattern(unsigned x,unsigned y){return ((x/8)+(y/8))&7;}
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vn8080_video b;
 b.reset=1;b.ce_native=0;b.rgb=0;b.hblank=1;b.vblank=1;b.hsync=0;b.vsync=0;
 b.effects=0;b.forced_scandoubler=0;b.crt_enabled=0;b.hsize_setting=b.hpos_setting=b.vpos_setting=0;b.gamma_bus=0;
 const std::string mode=argc>1?argv[1]:"native";
 bool solid=mode=="scandoubler"||mode=="hq2x";
 if(mode=="crt-neutral")b.crt_enabled=1;
 if(mode=="crt-buffer"){b.crt_enabled=1;b.vpos_setting=1;}
 if(mode=="crt-left"){b.crt_enabled=1;b.hpos_setting=8;}
 if(mode=="crt-right"){b.crt_enabled=1;b.hpos_setting=4;}
 if(mode=="crt-up"){b.crt_enabled=1;b.vpos_setting=8;}
 const bool sized=mode=="crt-size-plus"||mode=="crt-size-minus";
 if(sized){b.crt_enabled=1;b.hsize_setting=mode=="crt-size-plus"?4:8;}
 if(mode=="scandoubler")b.effects=2;
 if(mode=="hq2x")b.effects=1;
 const bool hq_pattern=mode=="hq2x-pattern";
 if(mode=="scandoubler-pattern")b.effects=2;
 if(hq_pattern)b.effects=1;
 const unsigned expected_pixels=b.effects==1?229376:b.effects?114688:57344;
 std::vector<unsigned char> golden;
 std::vector<unsigned char> observed;
 if(hq_pattern) {
  if(argc<3){std::cerr<<"HQ pattern requires an independent RGB reference file\n";return 1;}
  std::ifstream file(argv[2],std::ios::binary);
  golden.assign(std::istreambuf_iterator<char>(file),{});
  if(golden.size()!=expected_pixels*3){std::cerr<<"Invalid HQ reference size\n";return 1;}
 }
 auto step=[&](){b.gamma_bus&=~(1u<<20);b.clk=0;b.eval();b.gamma_bus|=1u<<20;b.clk=1;b.eval();};step();
 if(mode=="gamma") {
  for(unsigned channel=0;channel<3;channel++)for(unsigned value=0;value<256;value++){
   b.gamma_bus=(1u<<19)|(1u<<18)|((channel*256+value)<<8)|(255-value);step();
  }
  b.gamma_bus=1u<<19;
 }
 b.reset=0;
 unsigned x=0,y=240,phase=0,seen_frames=0,active=0,errors=0,first_bad=~0u;
 bool previous_vs=0;unsigned checked=0;
 bool previous_hs=0;unsigned line_active=0;std::vector<unsigned> line_counts;
 std::vector<unsigned> row_sources;
 for(uint64_t tick=0;tick<819200ULL*8;tick++) {
  b.ce_native=phase==0;
  if(b.ce_native){b.rgb=solid?7:mode=="crt-neutral"?(y&7):pattern(x,y);b.hblank=x>=256;b.vblank=y<16||y>=240;b.hsync=x>=272&&x<304;b.vsync=y>=248&&y<252;}
  step();
  if(b.hs&&!previous_hs){if(line_active)line_counts.push_back(line_active);line_active=0;}
  previous_hs=b.hs;
  if(b.vs&&!previous_vs) {
   if(hq_pattern && seen_frames==3 && argc>3) {
    std::ofstream file(argv[3],std::ios::binary);
    file.write(reinterpret_cast<const char*>(observed.data()),observed.size());
   }
   if(seen_frames>=3){bool dimensions_ok=active==expected_pixels;
    if(sized){dimensions_ok=line_counts.size()==224;for(unsigned width:line_counts)dimensions_ok&=width==(mode=="crt-size-plus"?243u:256u);}
    if(!dimensions_ok){std::cerr<<"FAIL "<<mode<<" active pixel count "<<active<<" expected "<<expected_pixels<<" rows="<<line_counts.size()<<" first rows=";for(unsigned i=0;i<line_counts.size()&&i<8;i++)std::cerr<<line_counts[i]<<',';std::cerr<<" source_y=";for(unsigned i=0;i<row_sources.size()&&i<8;i++)std::cerr<<row_sources[i]<<',';std::cerr<<" rgb_errors="<<errors<<" first_bad="<<first_bad<<'\n';return 1;}
    if(sized&&checked==0)std::cout<<mode<<" first frame rows="<<line_counts.size()<<" first width="<<line_counts[0]<<" active_samples="<<active<<'\n';
    checked++;
   }
   active=0;seen_frames++;
   line_counts.clear();
   row_sources.clear();
  }
  previous_vs=b.vs;
  if(b.ce_video&&b.de) {
   line_active++;
    unsigned expected=solid?7:mode=="crt-neutral"?((16+active/256)&7):sized?pattern(line_active-1,16+line_counts.size()):pattern(active%256,16+active/(b.effects?512:256));
   if(mode=="gamma")expected^=7;
   unsigned actual=(b.red?1:0)|(b.green?2:0)|(b.blue?4:0);
   if(active%256==0)row_sources.push_back(actual);
    bool bad=hq_pattern?(active>=expected_pixels || b.red!=golden[active*3] || b.green!=golden[active*3+1] || b.blue!=golden[active*3+2])
       :(actual!=expected || (b.red!=0&&b.red!=255) || (b.green!=0&&b.green!=255) || (b.blue!=0&&b.blue!=255));
    if(hq_pattern && seen_frames==3){observed.push_back(b.red);observed.push_back(b.green);observed.push_back(b.blue);}
    if(seen_frames>=3 && bad) {
     if(hq_pattern && errors<8 && active<expected_pixels)std::cerr<<"HQ mismatch "<<active%512<<','<<active/512<<" RGB "<<unsigned(b.red)<<','<<unsigned(b.green)<<','<<unsigned(b.blue)<<" expected "<<unsigned(golden[active*3])<<','<<unsigned(golden[active*3+1])<<','<<unsigned(golden[active*3+2])<<'\n';
     errors++;if(first_bad==~0u)first_bad=active;
    }
   active++;
  }
  phase=(phase+1)%10;if(phase==0){if(++x==320){x=0;y=(y+1)&255;}}
 }
 std::cout<<mode<<" frontend frames="<<checked<<" pixel_errors="<<errors<<" first_bad="<<first_bad<<'\n';
 if(!checked||errors)return 1;
 // The nonuniform HQ case consumes independent software-generated RGB pixels.
 return 0;
}
