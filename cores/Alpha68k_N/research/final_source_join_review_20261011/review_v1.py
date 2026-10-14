from pathlib import Path
import hashlib,json,subprocess,sys

root=Path(__file__).parent
proposal=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/final_source_join_20261011')
candidate=proposal/'candidate'
canonical=Path(r'D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N')
if '--worker' not in sys.argv:
    assert not (root/'review_v1_exit.json').exists(),'Immutable output exists'
    run=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker'],capture_output=True,text=True)
    (root/'review_v1.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    receipt={'actual_exit_code':run.returncode,'command':[sys.executable,str(Path(__file__).resolve()),'--worker'],'scope':'Pinned read-only source/dependency review; no Verilator replay, build, Quartus or production edit.'}
    (root/'review_v1_exit.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt));print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr);sys.exit(run.returncode)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
manifest=proposal/'import_manifest.json'
assert sha(manifest).startswith('b62087'),sha(manifest)
entries=json.loads(manifest.read_text())['files']
for entry in entries:
    path=Path(entry['path']);assert path.stat().st_size==entry['bytes'] and sha(path)==entry['sha256'],path
assert sha(canonical/'rtl/alpha68kn_board.sv')=='ba9357acc26ac391c71a01b166e96c7879fed726274eb13c60a25a494093f8fc'
assert sha(candidate/'rtl/alpha68kn_board.sv')=='714511ffa52963bd02e5b5b31a5335c7929bde281398267a5d7f981b8f4b9fa3'
board=(candidate/'rtl/alpha68kn_board.sv').read_text()
assert "sound_rom[15'((load_addr-'h20100)>>1)] <= load_data;" in board
assert '`ifdef VERILATOR\n            2:debug_rom_data' in board
assert 'alpha68kn_mcu sting_mcu (' in board and '.reset(held_reset || !is_stingray)' in board
assert 'wire sting_main_pause=is_stingray && sting_mcu_main_halt && mas_n;' in board
assert 'wire sting_mcu_work_service=is_stingray && !held_reset && sting_mcu_shared_write;' in board
assert "wire hle_service=!is_stingray && ram_bus_service" in board
assert 'if(is_stingray && sting_mcu_irq2) irq2<=1;' in board
assert 'if(is_stingray && sting_mcu_control_event) flip<=sting_mcu_flip;' in board
for profile in [0,1]:
    for address in range(65536):
        sting=profile==2
        assert (address<(0x8000 if sting else 0xc000))==(address<0xc000)
        ram=(sting and 0x8000<=address<0x8800) or (not sting and 0xc000<=address<0xc800)
        assert ram==(0xc000<=address<0xc800)
        assert (address==(0xc100 if sting else 0xe000))==(address==0xe000)
for address in range(0x20100,0x30100):assert ((address-0x20100)>>1)==(((address-0x20100)>>1)&0x7fff)
prior=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_p2_independent_review_20261011/qualification_review_v2.json')
p2=json.loads(prior.read_text());assert p2['pass'] and p2['approved_for_bounded_real_game_replay']
assert sha(candidate/'rtl/vendor/t48/t48_core.v')==p2['candidate_core_sha256']
assert sha(candidate/'rtl/alpha68kn_mcu.sv')==p2['candidate_wrapper_sha256']
source=json.loads((candidate/'rtl/vendor/t48/SOURCE.json').read_text())
assert source['sha256']==sha(candidate/'rtl/vendor/t48/t48_core.v') and source['bytes']==(candidate/'rtl/vendor/t48/t48_core.v').stat().st_size
assert source['candidate_wrapper_sha256']==sha(candidate/'rtl/alpha68kn_mcu.sv')
assert source['license_notice']['sha256']==sha(candidate/'rtl/vendor/t48/LICENSE.upstream')=='f9870f7d47c16bec37e17b923440d4f0a274d7c409d9327d86e25a000e4bab27'
fork=json.loads((candidate/'rtl/vendor/jt12/SSG_PERIOD_ZERO_FORK.json').read_text())
assert fork['candidate_sha256']==sha(candidate/'rtl/vendor/jt12/jt49/hdl/jt49_div.v')=='2c4e8f7924b89756c339d29b58e971238fdd8cbd8f23c64b8c9a78a6990dae4a'
assert fork['baseline_sha256']==sha(canonical/'rtl/vendor/jt12/jt49/hdl/jt49_div.v')
assert 'GNU General Public License' in (candidate/'rtl/vendor/jt12/jt49/hdl/jt49_div.v').read_text()
qip=(candidate/'files.qip').read_text()
assert 'set_global_assignment -name SYSTEMVERILOG_FILE rtl/alpha68kn_mcu.sv' in qip
assert 'set_global_assignment -name VERILOG_FILE rtl/vendor/t48/t48_core.v' in qip
assert (candidate/'Alpha68k_N.sv').read_bytes()==(canonical/'Alpha68k_N.sv').read_bytes()
assert 'board_load_data[15:8]<=1' in (candidate/'Alpha68k_N.sv').read_text()
assert 'board_load_data[15:8]<=2' in (proposal/'conditional_profile2_enable.patch').read_text()
assert not (candidate/'sys').exists()
build=candidate/'sim/build_system.sh';text=build.read_text();lines=text.splitlines()
assert 'rtl/alpha68kn_mcu.sv' not in text and 'rtl/vendor/t48/t48_core.v' not in text
assert 'alpha68kn_mcu.sv' not in text and 't48_core.v' not in text
assert text==(canonical/'sim/build_system.sh').read_text()
copy_line=next(i+1 for i,row in enumerate(lines) if row.startswith('cp rtl/alpha68kn_board.sv'))
verilator_line=next(i+1 for i,row in enumerate(lines) if row.startswith('/usr/local/bin/verilator --cc'))
findings=[{'priority':'P1','path':'sim/build_system.sh','line':copy_line,'title':'Standard real-system simulator omits new unconditional MCU dependencies','detail':'Board now unconditionally instantiates alpha68kn_mcu. The build script copies neither alpha68kn_mcu.sv nor t48_core.v and omits alpha68kn_mcu.sv from the Verilator SV file list. Its source SHA receipt also excludes vendor/t48/t48_core.v. files.qip fixes only the Quartus graph. Update source copy, explicit MCU SV compile input and donor source hashing before merging; include T48 in the copied .v closure.','compiler_line':verilator_line,'evidence_sha256':sha(build)}]
receipt={'review_completed':True,'approved_for_merge':False,'findings':findings,'manifest_sha256':sha(manifest),'manifest_files_verified':len(entries),'board_baseline_sha256':sha(canonical/'rtl/alpha68kn_board.sv'),'board_candidate_sha256':sha(candidate/'rtl/alpha68kn_board.sv'),'candidate_patch_sha256':sha(proposal/'candidate.patch'),'p2_prior_qualified_candidate_reused':True,'profile0_1_review':'Diff manually reviewed; profile2-gated MCU, CPU pause, RAM arbitration, firmware IRQ/flip and HLE exclusion reduce to the existing board behavior. Sound map enumerated for every address in both profiles. This is structural/finite evidence, not sequential formal or game replay.','shared_ssg_scope':'Intentional period-zero change affects all profiles and requires current-source replay binding.','merge_exclusions':['sim/coupled_observer.vlt is private diagnostic configuration and need not enter production.'],'conditional_gates':['Keep production profile admission <=1 until genuine181 gameplay and realHPS wrapper gates pass.','New board/MCU/T48/divider require complete current-source resource/all-corner timing acceptance.'],'metadata_notes':['Prefer repository-relative license_notice.path during production metadata integration; retained neighboring LICENSE.upstream hash is correct.'],'native_builds_replays_Quartus':False}
(root/'review_v1.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps(receipt))
