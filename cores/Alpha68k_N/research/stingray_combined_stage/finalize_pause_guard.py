"""Preserve the first private overlay, repair pause arbitration, regenerate once."""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

HERE=Path(__file__).resolve().parent
def main():
    archive=HERE/'v1_archive'
    assert not archive.exists(), 'Already finalized; preserve terminal receipts.'
    manifest=json.loads((HERE/'import_manifest.json').read_text())
    archive.mkdir()
    pins=[]
    # Copy original runtime helper and every original receipt before replacement.
    for source in [HERE/'prepare_candidate.py', HERE/'import_manifest.json',
                   HERE/'stingray_integration.patch',HERE/'integration_contract.json',
                   HERE/'integration_contract.md',HERE/'static_preparation.json']:
        dest=archive/source.name;shutil.copy2(source,dest)
        pins.append({'path':str(dest),'sha256':hashlib.sha256(dest.read_bytes()).hexdigest()})
    shutil.copytree(HERE/'candidate',archive/'candidate')
    (archive/'archive_pins.json').write_text(json.dumps({'preserved':pins,'reason':'Pause-entry MCU/HS collision guard superseded; no build or replay.'},indent=2)+'\n')
    script=HERE/'prepare_candidate.py';text=script.read_text()
    def once(old,new):
        nonlocal text
        assert text.count(old)==1, (old,text.count(old))
        text=text.replace(old,new,1)
    once('    // Drain a pre-pause MCU write before advertising the work-RAM borrow.\n    always @(posedge clk) paused<=pause_game && !held_reset &&\n        !(is_stingray && sting_mcu_shared_write);',
         '''    // Existing wrapper P2 observation and board write are registered stages.
    // Hold the HS borrow through their pre-pause drain; guard the port directly too.
    logic [1:0] sting_pause_drain=0;
    always @(posedge clk) begin
        if(held_reset || !is_stingray || !pause_game) sting_pause_drain<=0;
        else if(sting_pause_drain!=3) sting_pause_drain<=sting_pause_drain+1'b1;
        paused<=pause_game && !held_reset &&
            (!is_stingray || (sting_pause_drain==3 && !sting_mcu_shared_write));
    end''')
    once('    board=replace_once(board,"wire hle_service=ram_bus_service && !iack",',
         '''    board=replace_once(board,"    // Exact accepted edge; no CPU enable, AS, byte-strobe or DTACK change.",
                       "    // Kyros accepted edge retained; profile2 work collision defers DTACK below.")
    board=replace_once(board,"wire hs_work_service=!held_reset && pause_game && paused && hs_access",
                       "wire hs_work_service=!held_reset && pause_game && paused && hs_access && !sting_mcu_work_service")
    board=replace_once(board,"wire hle_service=ram_bus_service && !iack",''')
    once('"generator_python_syntax":True}',
         '''"pause_MCUpulse_excludes_HS_port":"hs_access && !sting_mcu_work_service" in board,
             "profile2_pause_drain_initialized":"logic [1:0] sting_pause_drain=0;" in board,
             "generator_python_syntax":True}''')
    once('sstingray_combined_private_candidate_v1','sstingray_combined_private_candidate_v2')
    once('Wrapper stops on pause. A pre-pause shared_write is serviced before paused advertises borrow; HS and CPU read OLD_DATA and prior response hold remain existing paths.',
         'Wrapper clock enables stop on pause; three master edges hold HS borrow while registered control/write drains. MCU pulse directly excludes HS port even if paused was already asserted. HS and CPU OLD_DATA/prior response hold remain existing paths; actual pause-pipeline timing still unqualified.')
    once('Pause advertises the HS borrow after servicing the pre-pause MCU write.',
         'Pause holds the HS borrow for three master edges while the registered MCU control/write pipeline drains; a shared_write also directly excludes HS service. This ordering remains to be observed in the coupled run.')
    once('owned=[Path(__file__),pp,','owned=[Path(__file__),HERE / "finalize_pause_guard.py",pp,')
    once('"High command-read byteff is a candidate unmappedlane value;',
         '"Pause-drain depth follows the visible registered wrapper/board pipeline but needs coupled capture, including a pre-pause control strobe; no physical delay is claimed.",\n             "High command-read byteff is a candidate unmappedlane value;')
    script.write_text(text,encoding='utf8',newline='\n')
    # Only remove the generation guard after its immutable archived receipt exists.
    (HERE/'integration_contract.json').unlink()
    result=subprocess.run([sys.executable,'-X','utf8',str(script)],capture_output=True,text=True)
    receipt={'exit_code':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
             'v1_manifest_sha256':hashlib.sha256((archive/'import_manifest.json').read_bytes()).hexdigest(),
             'finalizer_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
             'canonical_written':False,'build_or_replay_launched':False}
    (HERE/'finalize_exit.json').write_text(json.dumps(receipt,indent=2)+'\n')
    print(result.stdout,end='');print(result.stderr,file=sys.stderr,end='')
    if result.returncode:raise SystemExit(result.returncode)
    # Exhaustive combinational arbitration obligations; static model, no HDL proof.
    combinations=0
    for pulse in (False,True):
      for hs in (False,True):
       for high in (False,True):
        service=hs and not pulse
        assert not(pulse and service)
        assert not(pulse and service and high)
        combinations+=1
    print(json.dumps({'static_arbitration_combinations':combinations,
                      'manifest_sha256':hashlib.sha256((HERE/'import_manifest.json').read_bytes()).hexdigest(),
                      'HDL_compiled':False,'simulation_launched':False}))

if __name__=='__main__':main()
