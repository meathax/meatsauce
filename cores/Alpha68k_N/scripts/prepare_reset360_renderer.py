from pathlib import Path
import csv,json,hashlib
r=Path(r'D:\Arcade\AI\aCORES\Alpha68k N')
capture=r/'sim/captures/rtl/kyros_reset_background421'
out=r/'sim/captures/diagnostics/reset360_timed_renderer'
out.mkdir(parents=True,exist_ok=True)
states={int(x['frame']):x for x in csv.DictReader((capture/'snapshot_state.csv').open())}
start,end=int(states[330]['tick']),int(states[360]['tick'])
reset_rows=[row for row in csv.reader((capture/'applied_inputs.csv').open()) if row and row[0]=='warm_reset']
assert len(reset_rows)==1 and int(reset_rows[0][1])==300
release=int(reset_rows[0][2])
assert end-start==30*811008
ram=bytearray((capture/'frame_000330.sprites.bin').read_bytes())
events=[]
with (capture/'epoch_events.csv').open() as f:
 for x in csv.DictReader(f):
  tick,addr=int(x['tick']),int(x['address'])
  if not(start<tick<=end and 0x40000<=addr<0x42000 and x['rw']=='0' and x['iack']=='0'):continue
  e=tick-release
  pix=((e+6)//8+240*384)%(384*264)
  assert (pix%384,pix//384)==(int(x['raster_x']),int(x['raster_y']))
  offset=addr-0x40000;offset&=~1
  data=int(x['data_out'])
  if x['uds_n']=='0':ram[offset]=(data>>8)&255
  if x['lds_n']=='0':ram[offset+1]=data&255
  events.append((tick-start,offset//2,ram[offset]*256+ram[offset+1]))
expected=(capture/'frame_000360.sprites.bin').read_bytes()
assert bytes(ram)==expected,'accepted write replay does not reconstruct final RAM'
with (out/'writes.csv').open('w',newline='') as f:
 w=csv.writer(f);w.writerow(['step','word_address','merged_word']);w.writerows(events)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
meta={'scope':'Actual accepted sprite writes, lane merging and deterministic raster phase; isolated graphics diagnostic, no CPU acceptance','source_revision':'2d326a5','source_capture':str(capture),'start_field':330,'end_field':360,'start_tick':start,'end_tick':end,'warm_release_tick':release,'elapsed_start':start-release,'elapsed_end':end-release,'write_count':len(events),'reconstructed_final_ram_equal':True,'all_write_raster_coordinates_equal':True,'background':int(states[360]['background']),'background_scope':'Fixed target-field final background, not replayed background write history','refresh_scope':'Original isolated fixture cadence; original controller state/refresh phase is not checkpointed','inputs_sha256':{str(p):sha(p) for p in [capture/'epoch_events.csv',capture/'applied_inputs.csv',capture/'snapshot_state.csv',capture/'frame_000330.sprites.bin',capture/'frame_000360.sprites.bin',capture/'frame_000360.rgb',out/'writes.csv']}}
(r/'research/kyros_reset360_timed_renderer_preparation.json').write_text(json.dumps(meta,indent=2)+'\n')
src=(r/'sim/render_fixture_main.cpp').read_text()
src=src.replace('#include <iterator>','#include <iterator>\n#include <sstream>\n#include <algorithm>')
src=src.replace('if(argc<6)', 'if(argc!=10)')
src=src.replace('usage: render_fixture download.bin sprites.bin background output flip [oracle.rgb]','usage: render_timed download.bin sprites.bin background output flip oracle.rgb writes.csv elapsed_start elapsed_end')
old="""        for(unsigned y=15;y<240;y++) for(unsigned cycle=0;cycle<3072;cycle++) {
            top.line_start=cycle==0;top.line_y=y;top.video_y=y;top.video_x=(cycle/8)&255;
            tick();
            if(y>=16 && cycle%8==3 && cycle/8<256) put(actual,cycle/8,y,top.rgb);
        }"""
new="""        struct Write {uint64_t step;unsigned address,data;};
        std::vector<Write> writes;
        std::ifstream trace(argv[7]);
        if(!trace) throw std::runtime_error("cannot read writes");
        std::string text;std::getline(trace,text);
        while(std::getline(trace,text)) {
            std::replace(text.begin(),text.end(),',',' ');
            std::istringstream row(text);Write w{};
            if(!(row>>w.step>>w.address>>w.data)) throw std::runtime_error("invalid timed write");
            if(w.address>=4096 || (!writes.empty() && w.step<=writes.back().step))
                throw std::runtime_error("invalid write order");
            writes.push_back(w);
        }
        uint64_t elapsed_start=std::stoull(argv[8]),elapsed_end=std::stoull(argv[9]);
        if(elapsed_end<=elapsed_start || (elapsed_end-elapsed_start)%811008)
            throw std::runtime_error("invalid field interval");
        uint64_t duration=elapsed_end-elapsed_start;
        unsigned fields=duration/811008;
        size_t next=0;unsigned captured=0;
        for(uint64_t step=1;step<=duration;step++) {
            uint64_t elapsed=elapsed_start+step;
            unsigned pixel=((elapsed+6)/8+240*384)%(384*264);
            unsigned phase=(elapsed-1)%8,x=pixel%384,y=pixel/384;
            top.line_start=phase==0 && x==0;
            top.line_y=y;top.video_y=y;top.video_x=x&255;
            top.strip_wr=next<writes.size() && writes[next].step==step;
            if(top.strip_wr) {
                top.strip_write_addr=writes[next].address;top.strip_din=writes[next].data;++next;
            }
            tick();
            // Match the system's three-edge video enable/coordinate pipeline.
            if(step>(fields-1)*811008 && phase==2) {
                unsigned sample=((elapsed+4)/8+240*384)%(384*264);
                unsigned sx=sample%384,sy=sample/384;
                if(sx<256 && sy>=16 && sy<240) {
                    put(actual,sx,sy,top.rgb);++captured;
                }
            }
        }
        if(next!=writes.size() || captured!=57344)
            throw std::runtime_error("incomplete write or pixel coverage");"""
assert old in src
src=src.replace(old,new)
src=src.replace('oracle[p]!=expected[p]','oracle[p]!=actual[p]').replace('oracle[p+1]!=expected[p+1]','oracle[p+1]!=actual[p+1]').replace('oracle[p+2]!=expected[p+2]','oracle[p+2]!=actual[p+2]')
src=src.replace('bool pass=mismatches==0 && oracle_mismatches==0', 'bool pass=oracle_compared && oracle_mismatches==0')
src=src.replace('top.completed_lines==225','top.completed_lines==264*fields')
src=src.replace('isolated strip/palette/SDRAM fixture; no CPU acceptance','timed accepted-write strip/palette/SDRAM replay; no CPU acceptance')
src=src.replace('pixel_mismatches','initial_static_pixel_mismatches')
(r/'sim/render_timed_main.cpp').write_text(src,encoding='utf8',newline='\n')
sh=(r/'sim/build_renderer.sh').read_text()
sh=sh.replace('build_root="$(mktemp -d /tmp/alpha68kn-render.XXXXXX)"','build_root="$(mktemp -d /mnt/d/vibes/fpga/temp/alpha68kn-render-timed.XXXXXX)"')
sh=sh.replace('wsl_renderer_build_dir','wsl_renderer_timed_build_dir').replace('renderer_inputs.sha256','renderer_timed_inputs.sha256')
sh=sh.replace('render_fixture_main.cpp','render_timed_main.cpp').replace('alpha68kn_render_fixture_sim','alpha68kn_render_timed_sim')
(r/'sim/build_renderer_timed.sh').write_text(sh,encoding='utf8',newline='\n')
print(json.dumps({k:meta[k] for k in ['write_count','reconstructed_final_ram_equal','all_write_raster_coordinates_equal','elapsed_start','elapsed_end','background']}))
