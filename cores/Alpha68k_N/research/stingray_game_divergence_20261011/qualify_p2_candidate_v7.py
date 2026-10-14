import difflib, hashlib, json, subprocess, time
from pathlib import Path

O = Path(__file__).resolve().parent
BASE = O / 'p2_strobe_fixture_v2'
OUT = O / 'p2_candidate_qualification_v7'
OUT.mkdir(exist_ok=True)
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def save(p, d): p.write_text(json.dumps(d, indent=2)+'\n')
def replace_once(s, a, b):
    assert s.count(a)==1, (a, s.count(a))
    return s.replace(a,b)

wrapper=(BASE/'alpha68kn_mcu.sv').read_text()
core=(BASE/'t48_core.v').read_text()
start=core.index('module t48_p2\n');end=core.index('endmodule',start)
chunk=core[start:end]
newchunk=replace_once(chunk,'output p2l_low_imp_o,','output [7:0] p2_latch_o,\n   output p2l_low_imp_o,')
newcore=core[:start]+newchunk+core[end:]
newcore=replace_once(newcore,'assign p2_o = n4798_q;','assign p2_o = n4798_q;\n  // Alpha68k N donor integration fork, 2026-10-11: transaction-data export.\n  // Original T48 physical P2 output pipeline and license notices retained.\n  // Board handshake consumes the real enabled architectural port write.\n  assign p2_latch_o = p2_q;')
newcore=replace_once(newcore,'output alpha_p2_write_o);','output alpha_p2_write_o,\n    output [7:0] alpha_p2_latch_o);')
newcore=replace_once(newcore,'.p2_o(use_p2_p2_b_p2_o),','.p2_o(use_p2_p2_b_p2_o),\n    .p2_latch_o(alpha_p2_latch_o),')
newwrapper=replace_once(wrapper,'wire [7:0] effective_control=', 'wire [7:0] p2_latched;\n  wire [7:0] effective_control=')
newwrapper=replace_once(newwrapper,'p2_pending ? p2_out : control','p2_pending ? p2_latched : control')
newwrapper=replace_once(newwrapper,'control<=p2_out;','control<=p2_latched;')
for bit in [4,5,6,7]:
    newwrapper=replace_once(newwrapper,f'p2_out[{bit}]',f'p2_latched[{bit}]')
newwrapper=replace_once(newwrapper,'.alpha_p2_write_o(p2_we),','.alpha_p2_write_o(p2_we),.alpha_p2_latch_o(p2_latched),')

newwrapper=replace_once(newwrapper,'Observe output pins one master tick','Observe BUS pins and the committed P2 latch one master tick')

cpp=(BASE/'main.cpp').read_text()
cpp=replace_once(cpp,'bool sent=false,reply=false;','bool sent=false,reply=false,sent_second=false,sent_third=false,sent_fourth=false,status_reply=false,coinage_reply=false;')
cpp=replace_once(cpp,'t.command_valid=!sent && tick>30000 && (t.control&16) && t.program_addr>=0x20b && t.program_addr<=0x227;\n  if(t.command_valid) sent=true;',
'''bool first=!sent && tick>30000 && (t.control&16) && t.program_addr>=0x20b && t.program_addr<=0x227;
   bool second=sent && reply && !sent_second && tick>60000;
   bool third=sent_second && !sent_third && tick>90000;
   bool fourth=sent_third && !sent_fourth && tick>95000;
   t.command_valid=first || second || third || fourth;t.command_addr=fourth?34:((second || third)?41:255);
   if(first) sent=true;if(second) sent_second=true;if(third) sent_third=true;if(fourth) sent_fourth=true;''')
cpp=replace_once(cpp,'if(t.shared_write && t.shared_addr==255 && t.shared_data==255)reply=true;', 'if(t.shared_write && t.shared_addr==255 && t.shared_data==255)reply=true;\n   if(t.shared_write && t.shared_addr==41 && t.shared_data==35)status_reply=true;\n   if(t.shared_write && t.shared_addr==34 && t.shared_data==1)coinage_reply=true;')
cpp=replace_once(cpp,'t.reset=tick<8;','t.reset=tick<8;t.coins_n=(tick>=35000 && tick<85000)?2:3;')
cpp=replace_once(cpp,'t.command_data=0;t.eval();','t.command_data=0;t.coins_n=3;t.eval();')
cpp=replace_once(cpp,'return !(sent && reply && lost_ready>0);','return !(sent && reply && sent_second && sent_third && sent_fourth && EXPECT);')
cpp=replace_once(cpp,'<<\",\\\"ID_reply\\\":\"<<reply', '<<\",\\\"ID_reply\\\":\"<<reply<<\",\\\"sent_second\\\":\"<<sent_second<<\",\\\"coinage_reply\\\":\"<<coinage_reply')

patch=''.join(difflib.unified_diff(wrapper.splitlines(True),newwrapper.splitlines(True),fromfile='a/rtl/alpha68kn_mcu.sv',tofile='b/rtl/alpha68kn_mcu.sv'))
patch+=''.join(difflib.unified_diff(core.splitlines(True),newcore.splitlines(True),fromfile='a/rtl/vendor/t48/t48_core.v',tofile='b/rtl/vendor/t48/t48_core.v'))
(OUT/'candidate.patch').write_text(patch)
results={}
for variant in ['baseline','candidate']:
    F=OUT/variant;F.mkdir(exist_ok=True)
    (F/'alpha68kn_mcu.sv').write_text(wrapper if variant=='baseline' else newwrapper)
    (F/'t48_core.v').write_text(core if variant=='baseline' else newcore)
    (F/'mcu.hex').write_bytes((BASE/'mcu.hex').read_bytes())
    fixture=(BASE/'fixture.sv').read_text().replace('module fixture(input logic clk,reset,command_valid,command_read,','module fixture(input logic clk,reset,command_valid,command_read,input logic [1:0] coins_n,').replace(".coins_n(2'b11)",'.coins_n(coins_n)')
    (F/'fixture.sv').write_text(fixture)
    expect='!coinage_reply && lost_ready>0' if variant=='baseline' else 'status_reply && coinage_reply && lost_ready==0 && (t.control&16)'
    (F/'main.cpp').write_text(cpp.replace('EXPECT',expect))
    linux='/tmp/alpha68kn-p2-qualification-v7-'+variant
    prep=['wsl.exe','-d','Ubuntu','--cd',str(F),'--exec','/bin/bash','-c',f'mkdir -p {linux} && cp fixture.sv alpha68kn_mcu.sv t48_core.v main.cpp {linux}/']
    p=subprocess.run(prep,capture_output=True);save(F/'prepare_exit.json',{'exit_code':p.returncode,'stderr':p.stderr.decode(errors='replace')});p.check_returncode()
    build=['wsl.exe','-d','Ubuntu','--cd',linux,'--exec','/usr/local/bin/verilator','--cc','--exe','--build','-j','4','-O3','-Wno-fatal','--top-module','fixture','--Mdir','obj','fixture.sv','alpha68kn_mcu.sv','t48_core.v','main.cpp','-CFLAGS','-std=c++17']
    for stage,cmd in [('build',build),('run',['wsl.exe','-d','Ubuntu','--cd',str(F),'--exec',linux+'/obj/Vfixture'])]:
        with (F/(stage+'.log')).open('wb') as log:
            p=subprocess.Popen(cmd,stdout=log,stderr=subprocess.STDOUT);save(F/(stage+'_job.json'),{'pid':p.pid,'started':time.time(),'command':cmd});code=p.wait()
        save(F/(stage+'_exit.json'),{'pid':p.pid,'exit_code':code,'finished':time.time()})
        print(variant,stage,code,flush=True)
        if code: raise RuntimeError((variant,stage,code))
    results[variant]=json.loads((F/'result.json').read_text())
    results[variant]['source_pins']=[{'name':n,'sha256':sha(F/n)} for n in ['alpha68kn_mcu.sv','t48_core.v','fixture.sv','main.cpp','mcu.hex']]
save(OUT/'verification.json',{'scope':'Paired real8748 same-ROM component fixture, original ID initialization, real coin pulse, accepted 0x29 coin-detected status, 0x29 credit-ready status, then 0x22 coinage commands. This is not gameplay or timing qualification.','results':results,'candidate_patch_sha256':sha(OUT/'candidate.patch'),'functional_CPU_timer_clock_ROM_logic_changed':False})
print(json.dumps(results),flush=True)
