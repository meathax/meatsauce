from pathlib import Path
import re,json,hashlib,itertools,difflib
ROOT=Path('D:/Arcade/AI/aCORES/Alpha68k N/research/final_source_join_20261011')
CAN=Path('D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
CAND=ROOT/'candidate';OLD=CAN.parent.parent.parent/'Alpha68k N'
P2=Path('D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_game_divergence_20261011/p2_candidate_qualification_v7')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def tokens(s):return re.findall(r'\w+|[^\s]',re.sub(r'/\*.*?\*/|//[^\n]*','',s,flags=re.S))
def once(s,a,b):assert s.count(a)==1,(a,s.count(a));return s.replace(a,b)
base=(CAN/'rtl/alpha68kn_board.sv').read_text();new=(CAND/'rtl/alpha68kn_board.sv').read_text()
s=new;rules=[]
def segment(start,end):
 global s
 a=s.index(start);b=s.index(end,a);ca=base.index(start);cb=base.index(end,ca)
 rules.append({'start':start,'end':end,'reason':'Substitution of profile2 predicates by false; legacy conditional branch and unaffected statements retained.'})
 s=s[:a]+base[ca:cb]+s[b:]
# Profile2=false makes the new pause expression exactly the previous pause expression.
segment('    wire held_reset =','    logic [2:0] phase,cpu_phase;')
segment('    wire [2:0] level =','    wire vblank_edge =')
# Reset assertion and output-use gates isolate the entire MCU cone.
a=s.index('    wire [11:0] sting_mcu_program_addr;');b=s.index('    fx68k maincpu (',a);s=s[:a]+s[b:]
rules.append({'removed':'MCU instantiation/ROM and outputs','reason':'reset = held_reset || !is_stingray, every output consumer gated by is_stingray; no game clock, loader or CPU input modified for profile0/1.'})
s=once(s,'.enPhi1(cpu_phase==0 && !pause_game && !sting_main_pause), .enPhi2(cpu_phase==4 && !pause_game && !sting_main_pause),','.enPhi1(cpu_phase==0 && !pause_game), .enPhi2(cpu_phase==4 && !pause_game),')
segment('    always_ff @(posedge clk) begin\n        sound_rom_q','    assign zdin =')
segment('    // Kyros accepted edge retained;','    // Write-only full-byte banks') if '    // Kyros accepted edge retained;' in base else None
# Exact legacy RAM/bus selection after false MCU/profile2 service substitution.
a=s.index('    // Kyros accepted edge retained;');b=s.index('    // Write-only full-byte banks',a)
ca=base.index('    // Exact accepted edge;');cb=base.index('    // Write-only full-byte banks',ca)
s=s[:a]+base[ca:cb]+s[b:]
rules.append({'removed':'MCU RAM arbitration and disabled HLE alternative','reason':'sting_mcu_work_service=false; command_valid=false; hle_service reduces to legacy. Truth table below enumerates legacy and MCU conflict guards.'})
s=once(s,'if(!pause_game && !sting_main_pause) cpu_phase<=cpu_phase+1\'b1;','if(!pause_game) cpu_phase<=cpu_phase+1\'b1;')
segment('            if (vblank_edge) begin','            if (nmi_width!=0)')
s=once(s,'            else if (ram_bus_service) begin','            else if (!bus_done && (iack || !muds_n || !mlds_n)\n                && (iack || maddr>=24\'h020000 || main_rom_addr_q==ma[16:1])) begin')
segment("                end else if (maddr >= 'h080000",'                    end else case(ma[8:1])')
segment("                    if ((is_stingray && za >= 'h8000",'                if (!zwr_n && !ziorq_n)') if "                    if ((is_stingray && za >= 'h8000" in base else None
a=s.index("                    if ((is_stingray && za >= 'h8000");b=s.index('                if (!zwr_n && !ziorq_n)',a)
ca=base.index("                    if (za >= 'hc000");cb=base.index('                if (!zwr_n && !ziorq_n)',ca)
s=s[:a]+base[ca:cb]+s[b:]
irq='            // Set wins over same-edge IACK: do not lose a fresh firmware IRQ2.\n            if(is_stingray && sting_mcu_irq2) irq2<=1;\n            if(is_stingray && sting_mcu_control_event) flip<=sting_mcu_flip;\n'
s=once(s,irq,'')
ta,tb=tokens(base),tokens(s)
assert ta==tb, 'Legacy specialized board token mismatch: '+str(list(difflib.unified_diff(ta,tb))[:35])
table=0
for held,pause,AS,done,iack,uds,lds,addrready,ramregion,mcuwrite in itertools.product([False,True],repeat=10):
 legacy=(not held and not pause and not AS and not done and (iack or not uds or not lds) and addrready)
 candidate=legacy and (not (False and not held and mcuwrite) or iack or not ramregion)
 assert legacy==candidate;table+=1
for profile in [0,1]:assert (profile==2)==False
for addr in range(0x20100,0x30100):assert ((addr-0x20100)>>1)==(((addr-0x20100)>>1)&0x7fff)
private=Path('D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_combined_stage/next_coupled_scope_v2/source/rtl/alpha68kn_board.sv').read_text()
line='            2:debug_rom_data<={sound_rom[debug_rom_addr[14:0]][7:0],sound_rom[debug_rom_addr[14:0]][15:8]};'
assert new==once(private,line,'`ifdef VERILATOR\n'+line+'\n`endif')
assert '`ifdef VERILATOR\n'+line+'\n`endif' in new
assert "sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;" in new
# Existing generated baseline differs from canonical only in whitespace/comment diagnostics.
tb=tokens((P2/'baseline/t48_core.v').read_text());tc=tokens((CAN/'rtl/vendor/t48/t48_core.v').read_text())
donor_diff=list(difflib.unified_diff(tc,tb));assert tc==tb,'Baseline donor functional differences: '+str(donor_diff[:30])
assert (CAND/'Alpha68k_N.sv').read_bytes()==(CAN/'Alpha68k_N.sv').read_bytes()
assert 'board_load_data[15:8]<=1' in (CAND/'Alpha68k_N.sv').read_text()
assert not (CAND/'sys').exists()
assert sha(CAN/'rtl/alpha68kn_board.sv')=='ba9357acc26ac391c71a01b166e96c7879fed726274eb13c60a25a494093f8fc'
result={'actual_exit_code':0,'checks':{'profile0_and_1_board_specialization':'Entire legacy board token stream exact after is_stingray=false specialization; MCU isolated and output consumers gated.','profile0_1_tokens':len(ta),'ram_guard_truth_table_cases':table,'sound_loader_legal_address_cases':65536,'sound_VERILATOR_reader':'Candidate differs from private joined board only by VERILATOR guard; defined-reader body exact.','P2_baseline_vs_canonical_donor_tokens':len(tc),'production_profile2_admission':'Disabled <=1; conditional patch separate.','pinned_sys':'No copies or edits','native_builds_runs_Quartus_RBF_hardware':'None'},'translation_rules':rules,'limits':['Structural specialization and exhaustive finite expression checks; not a new replay or sequential formal model.','Shared SSG zero-period behavior intentionally changes all profiles and needs final-source binding.','Actual181 gameplay and realHPS wrapper admission gate remain parent-owned.','Complete fitted 161-source image excludes this changed board, MCU, T48 and shared divider.','Additive SDC remains parent timing-agent owned and is not merged here.']}
(ROOT/'verification.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
files=[]
for p in sorted(ROOT.rglob('*')):
 if p.is_file() and p.name not in ['import_manifest.json']:
  files.append({'path':str(p),'bytes':p.stat().st_size,'sha256':sha(p)})
(ROOT/'import_manifest.json').write_text(json.dumps({'scope':'Immutable prepare-only final-source proposal. No production changes or gameplay/timing/hardware acceptance.','files':files},indent=2)+'\n',encoding='utf-8')
print(json.dumps({'actual_exit_code':0,'checks':result['checks'],'manifest':str(ROOT/'import_manifest.json'),'manifest_sha256':sha(ROOT/'import_manifest.json'),'files':len(files)},indent=2))
