// SPDX-License-Identifier: GPL-2.0-or-later
// Independent floating point reference for the fixed point capacitor engine.
#include "Vsheriff_sn76477.h"
#include "verilated.h"
#include <algorithm>
#include <cmath>
#include <fstream>
#include <iostream>
#include <array>
struct Reference {
 double slf=.33,vco=.33,noise=0,ad=0,shot=0;
 bool slfbit=0,vcobit=0,filtered=0,real=0,running=0;
 uint32_t rng=0; int count=0;
 int step(bool enabled,bool mode,bool mixer,bool voltage) {
  slf=slfbit ? std::max(.33,slf-2.04/(.5413*1.5e6*47e-9+.001343)/48000) :
               std::min(2.37,slf+2.04/(.5885*1.5e6*47e-9+.001300)/48000);
  if(slf>=2.37)slfbit=1;else if(slf<=.33)slfbit=0;
  double multiplier=voltage?1.64:1.,rate=.64*2*2.39/(1.5e6*1e-9)/48000;
  double top=(mode?slf:voltage?5.:0.)+.35;
  vco=vcobit?std::max(.33,vco-rate*multiplier):std::min(top,vco+rate/multiplier);
  if(vco>=top)vcobit=1;else if(vco<=.33)vcobit=0;
  const int frequency=int(339100000*std::pow(36000.,-.8849));
  while(count<=frequency) {count+=48000;real=((rng>>28)^rng)&1;if(!(rng&0x1000001f))real=1;rng=(rng>>1)|(uint32_t(real)<<30);}
  count-=frequency;
  noise=real?std::min(5.,noise+5/(.1571*100e3*1e-9+.00001430)/48000):
             std::max(0.,noise-5/(.1331*100e3*1e-9+.00001734)/48000);
  if(noise>=3.35)filtered=0;else if(noise<=.74)filtered=1;
  shot=running?std::min(2.5,shot+2.5/(.8024*560e3*47e-9+.002079)/48000):
                std::max(0.,shot-2.5/(854.7*47e-9+.00001795)/48000);
  if(shot>=2.5)running=0;
  ad=running?std::min(4.44,ad+4.44/(20e3*1e-6)/48000):std::max(0.,ad-4.44/(620e3*1e-6)/48000);
  static const std::array<double,45> pos={0,0,0,0,0,0,0,0,0,.01,.03,.11,.15,.19,.21,.23,.26,.29,.31,.33,.36,.38,.41,.43,.46,.49,.52,.54,.57,.60,.62,.65,.68,.70,.73,.76,.80,.82,.84,.87,.90,.93,.96,.98,1};
  static const std::array<double,45> neg={0,0,0,0,0,0,0,0,0,-.01,-.02,-.09,-.13,-.15,-.17,-.19,-.22,-.24,-.26,-.28,-.30,-.32,-.34,-.37,-.39,-.41,-.44,-.46,-.48,-.51,-.53,-.56,-.58,-.60,-.62,-.65,-.67,-.69,-.72,-.74,-.76,-.78,-.81,-.84,-.85};
  if(!enabled||vco>2.72)return 0;
  int index=std::min(44,int(ad*10));double gain=(mixer?filtered:vcobit)?pos[index]:neg[index];
   double voltage_out=std::clamp(2.57+(3.818*(47e3/150e3)+.03)*gain,.715,3.51);
   float normalized=float((voltage_out-.715)/(2.57-.715)-1);
   float routed=normalized*float(.35);
   return int(routed*32768);
 }
};
int main(int argc,char**argv) {
 Verilated::commandArgs(argc,argv);Vsheriff_sn76477 b;Reference r;
 b.reset=1;b.pause=0;b.enabled=0;b.vco_mode=0;b.mixer_b=1;b.vco_5v=0;
 auto clock=[&](){b.clk=0;b.eval();b.clk=1;b.eval();};clock();clock();b.reset=0;
 double maxcap=0,squared=0;unsigned noise_errors=0,vco_errors=0;int maximum=0;
 std::ofstream report("qualification.csv");report<<"sample,actual,reference,slf,vco,noise,ad\n";
 bool previous_enabled=0;
 for(unsigned n=0;n<96000;n++) {
  b.enabled=(n>=200 && n<35000)||(n>=50000&&n<90000);
  b.vco_mode=n<20000 || n>=60000;b.mixer_b=!b.vco_mode;b.vco_5v=n>=12000&&n<50000;
  if(b.enabled&&!previous_enabled){r.ad=0;r.running=1;}previous_enabled=b.enabled;
  for(unsigned t=0;t<1050;t++)clock();
  if(!b.sample_ce){std::cerr<<"sample cadence mismatch\n";return 1;}
  int expected=r.step(b.enabled,b.vco_mode,b.mixer_b,b.vco_5v),delta=int16_t(b.sample)-expected;
  squared+=double(delta)*delta;maximum=std::max(maximum,std::abs(delta));
  maxcap=std::max({maxcap,std::abs(b.slf_voltage/double(1ULL<<32)-r.slf),std::abs(b.vco_voltage/double(1ULL<<32)-r.vco),std::abs(b.noise_voltage/double(1ULL<<32)-r.noise),std::abs(b.ad_voltage/double(1ULL<<32)-r.ad)});
  noise_errors+=b.filtered_noise!=r.filtered;vco_errors+=b.vco_bit!=r.vcobit;
  if(n%48==0||delta)report<<n<<','<<int16_t(b.sample)<<','<<expected<<','<<r.slf<<','<<r.vco<<','<<r.noise<<','<<r.ad<<'\n';
 }
 double rms=std::sqrt(squared/96000);
 std::cout<<"samples=96000 max_cap_error_V="<<maxcap<<" noise_bit_errors="<<noise_errors<<" vco_bit_errors="<<vco_errors<<" pcm_rms_LSB="<<rms<<" pcm_max_LSB="<<maximum<<'\n';
 // Fixed point rounding must not alter any comparator decision in this corpus.
 return maxcap<.001 && noise_errors==0 && vco_errors==0 && rms<2 && maximum<=1 ? 0:1;
}
