from pathlib import Path
import hashlib, json, re, subprocess, sys

root=Path(__file__).parent
source=Path(r'D:/Arcade/AI/aCORES/Alpha68k N/research/stingray_game_divergence_20261011/p2_candidate_qualification_v3')
if '--worker' not in sys.argv:
    assert not (root/'static_review_v1_exit.json').exists(), 'Immutable output exists'
    run=subprocess.run([sys.executable,str(Path(__file__).resolve()),'--worker'],capture_output=True,text=True)
    (root/'static_review_v1.log').write_text(run.stdout+run.stderr,encoding='utf-8')
    receipt={'actual_exit_code':run.returncode,'command':[sys.executable,str(Path(__file__).resolve()),'--worker'],'scope':'Static source proof only; no RTL replay or Quartus.'}
    (root/'static_review_v1_exit.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt));print(run.stdout,end='');print(run.stderr,end='',file=sys.stderr)
    sys.exit(run.returncode)
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def tokens(path):
    # Strings stay indivisible; comments and whitespace cannot hide code changes.
    pieces=re.findall(r'/\*.*?\*/|//[^\r\n]*|"(?:\\.|[^"\\])*"|[A-Za-z_$][A-Za-z0-9_$]*|[0-9]+|[^\s]',path.read_text(encoding='utf-8'),re.S)
    return [piece for piece in pieces if not piece.startswith(('/*','//'))]
def remove_once(items,sequence):
    found=[index for index in range(len(items)-len(sequence)+1) if items[index:index+len(sequence)]==sequence]
    assert len(found)==1,(sequence,len(found))
    index=found[0];return items[:index]+items[index+len(sequence):]
paths={name:source/profile/name for profile in ['baseline','candidate'] for name in ['t48_core.v','alpha68kn_mcu.sv']}
pin_rows=[]
for profile in ['baseline','candidate']:
    for name in ['t48_core.v','alpha68kn_mcu.sv']:
        path=source/profile/name;pin_rows.append({'profile':profile,'path':str(path),'sha256':sha(path)})
base=tokens(source/'baseline/t48_core.v');new=tokens(source/'candidate/t48_core.v')
for sequence in [
    ['output','[','7',':','0',']','p2_latch_o',','],
    ['assign','p2_latch_o','=','p2_q',';'],
    [',','output','[','7',':','0',']','alpha_p2_latch_o'],
    ['.','p2_latch_o','(','alpha_p2_latch_o',')',','],
]:new=remove_once(new,sequence)
assert new==base,'Donor functional token delta beyond export'
base_wrapper=tokens(source/'baseline/alpha68kn_mcu.sv');new_wrapper=tokens(source/'candidate/alpha68kn_mcu.sv')
new_wrapper=remove_once(new_wrapper,['wire','[','7',':','0',']','p2_latched',';'])
new_wrapper=remove_once(new_wrapper,['.','alpha_p2_latch_o','(','p2_latched',')',','])
new_wrapper=['p2_out' if token=='p2_latched' else token for token in new_wrapper]
assert new_wrapper==base_wrapper,'Wrapper functional token delta beyond P2 consumer'
donor=(source/'candidate/t48_core.v').read_text(encoding='utf-8')
for assertion in ['assign p2_latch_o = p2_q;','assign p2_q = n4784_q;','assign n4783_o = en_clk_i ? n4721_o : p2_q;','n4784_q <= 8\'b11111111;','assign n4797_o = xtal_en_i ? n4751_o : n4798_q;','assign alpha_p2_write_o = p2_write_p2_s & en_clk_s;','assign n4778_o = read_reg_i ? p2_q : n4777_o;']:
    assert assertion in donor,assertion
canonical=Path(r'D:/Arcade/AI/aCORES/meatsauce-alpha68kn/cores/Alpha68k_N/rtl/vendor/t48')
notice=(canonical/'LICENSE.upstream').read_text(encoding='utf-8')
assert 'Arnim Laeuger' in notice and 'Redistribution and use in source and synthezised forms' in notice
receipt={'pass':True,'source':str(source),'pins':pin_rows,'donor_functional_tokens_preserved_except_export':True,'wrapper_functional_tokens_preserved_except_p2_consumer':True,'donor_tokens_compared':len(base),'wrapper_tokens_compared':len(base_wrapper),'license_sha256':sha(canonical/'LICENSE.upstream'),'provenance_sha256':sha(canonical/'SOURCE.json'),'qualification_review_pending':True,'findings':[],'integration_notes':['Update donor SOURCE.json adaptation and SHA plus donormap for architectural P2 export.','Update stale wrapper comment describing physical output pins; BUS still uses pins, P2 now uses architectural latch.'],'scope':'Static full-source token proof, reset/CE/strobe/readback/physical-pipeline and license inspection. No replay, build, Quartus, or production edit.'}
(root/'static_review_v1.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
print(json.dumps(receipt))
