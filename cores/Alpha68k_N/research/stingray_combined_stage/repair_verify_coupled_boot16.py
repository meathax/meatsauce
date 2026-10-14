"""Preserve verifier schema failure, repair once, and qualify the actual terminal."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys

HERE=Path(__file__).resolve().parent
def main():
    script=HERE/'verify_coupled_boot16.py';prior=HERE/'verify_coupled_boot16_v1.py'
    assert not prior.exists(),'Observe completed correction instead of repeating.'
    prior.write_bytes(script.read_bytes())
    (HERE/'coupled_boot16/verifier_v1_failure.json').write_text(json.dumps({
        'failure':'KeyError: sound_transactions','location':'verify_coupled_boot16.py line39',
        'reason':'frames.csv contains sound_address but no sound_transactions column; corrected using actual retained Z80 audio/bus evidence.',
        'verifier_sha256':hashlib.sha256(prior.read_bytes()).hexdigest(),'actual_simulation_failed':False,
        'actual_build_exit':0,'actual_run_exit':0},indent=2)+'\n')
    text=script.read_text()
    old="    checks['real_main_and_sound_transactions']=int(frames[-1]['main_transactions'])>0 and int(frames[-1]['sound_transactions'])>0"
    new="""    audio_rows=list(csv.DictReader((capture/'audio_events.csv').open()))
    checks['real_main_transactions']=int(frames[-1]['main_transactions'])>0
    z80_observation={'observed_sound_bus_addresses':sorted(set(int(r['sound_address']) for r in frames)),
                     'actual_audio_event_rows':len(audio_rows),'first_audio_events':audio_rows[:12],
                     'real_T80_compiled_source_pin':actual_hashes.get('T80s.v'),
                     'limit':'No aggregate sound transaction counter is exported in frames.csv; bus addresses/audio events are actual observations only.'}"""
    assert text.count(old)==1;text=text.replace(old,new,1)
    old="    log=(JOB/'run.log').read_text(errors='replace')"
    new="""    import io
    instruction=capture/'instruction_events.csv'
    with instruction.open('rb') as f:
        header=f.readline().decode().strip()
        f.seek(max(0,instruction.stat().st_size-32768))
        tail=f.read().decode(errors='replace').splitlines()[1:]
    native_tail=list(csv.DictReader(io.StringIO(header+'\\n'+'\\n'.join(tail))))[-32:]
    rom_path=next(Path(x['path']) for x in provenance['ROM_regions'] if x['path'].endswith('maincpu.bin'))
    rom=rom_path.read_bytes();pcs=sorted(set(int(x['pc_after']) for x in native_tail))
    pc_evidence={'actual_last32_accepted_bus_rows':native_tail,'request_PC_is_dispatch':False,
                 'ROM_path':str(rom_path),'ROM_sha256':H(rom_path),
                 'reset_SP':int.from_bytes(rom[:4],'big'),'reset_PC':int.from_bytes(rom[4:8],'big'),
                 'observed_PC_windows':[{'pc':pc,'offset':max(0,pc-12),
                       'bytes_hex':rom[max(0,pc-12):min(len(rom),pc+16)].hex()} for pc in pcs if pc<len(rom)],
                 'reference_initial_snapshot':next(csv.DictReader((reference/'states.csv').open())),
                 'limit':'Accepted bus rows expose current PC/IR registers; they do not by themselves identify dispatch or prove a loop cause.'}
    log=(JOB/'run.log').read_text(errors='replace')"""
    assert text.count(old)==1;text=text.replace(old,new,1)
    old="             'frames_first':frames[0],'frames_last':frames[-1],'applied_input_rows':len(inputs),"
    new=old+"\n             'actual_Z80_observation':z80_observation,'actual_native_PC_bus_evidence':pc_evidence,"
    assert text.count(old)==1;text=text.replace(old,new,1)
    text=text.replace('Its recording starts after emulated machine startup.',
                      'Its reset/first-instruction capture epoch is not proven by retained traces.')
    old="    owned=[HERE/'prepare_coupled_boot16.py',HERE/'coupled_worker.py',Path(__file__),JOB/'reference_provenance.json'"
    new="    owned=[HERE/'prepare_coupled_boot16.py',HERE/'coupled_worker.py',Path(__file__),HERE/'verify_coupled_boot16_v1.py',HERE/'repair_verify_coupled_boot16.py',JOB/'verifier_v1_failure.json',JOB/'reference_provenance.json'"
    assert text.count(old)==1;text=text.replace(old,new,1)
    script.write_text(text,encoding='utf8',newline='\n')
    result=subprocess.run([sys.executable,'-X','utf8',str(script)],capture_output=True,text=True)
    (HERE/'coupled_boot16/verification_exit.json').write_text(json.dumps({
        'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
        'corrected_verifier_sha256':hashlib.sha256(script.read_bytes()).hexdigest(),
        'original_verifier_sha256':hashlib.sha256(prior.read_bytes()).hexdigest(),
        'new_build_or_replay':False},indent=2)+'\n')
    print(result.stdout,end='');print(result.stderr,file=sys.stderr,end='')
    raise SystemExit(result.returncode)

if __name__=='__main__':main()
