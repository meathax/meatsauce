"""One bounded verification of saved preparation; no network, simulation or FPGA build."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def run(args):
    result = subprocess.run(args,cwd=ROOT,capture_output=True,text=True,encoding='utf-8',errors='replace')
    if result.returncode:
        raise RuntimeError(f'{args}: exit {result.returncode}: {result.stderr[-1000:]} {result.stdout[-1000:]}')
    return result.stdout.strip()


def main():
    required = ['AGENTS.md','plan.md','progress.md','mamebug.md','mamebugs.md','donormap.md',
                'goal_prompt.md','docs/HARDWARE_NOTES.md','resource_limits.json','donors.lock.json',
                'research/source_manifest.json','research/rom_manifest.json','research/online_manifest.json',
                'research/tool_versions.json','Alpha68k_N.qpf','Alpha68k_N.qsf','Alpha68k_N.sdc','Alpha68k_N.sv','files.qip']
    for name in required:
        if not (ROOT/name).is_file() or not (ROOT/name).stat().st_size:
            raise AssertionError('Missing/empty '+name)
    run(['git','diff','--check'])
    run(['git','diff','--cached','--check'])
    lock = json.loads((ROOT/'donors.lock.json').read_text())
    assert not lock['failures'] and len(lock['donors']) == 12
    donor_checks = []
    for donor in lock['donors']:
        dest = ROOT/donor['path']
        actual = run(['git','-C',str(dest),'rev-parse','HEAD'])
        assert actual == donor['commit'], donor['name']+' revision mismatch'
        assert not run(['git','-C',str(dest),'diff','--name-only']), donor['name']+' tracked changes'
        assert (dest/'STAGED_PROVENANCE.json').exists()
        for name in donor['license_files']:
            assert (dest/name).is_file(),name
        donor_checks.append({'name':donor['name'],'commit':actual,'status':'present/pinned/tracked source unchanged'})
    manifest = json.loads((ROOT/'research/source_manifest.json').read_text())
    for entry in manifest['mame']+manifest['roms']:
        assert hashlib.sha256((ROOT/entry['path']).read_bytes()).hexdigest() == entry['sha256'], entry['path']
    expected = {'kyros':26,'kyrosj':26,'sstingry':18}
    roms = json.loads((ROOT/'research/rom_manifest.json').read_text())
    for name,count in expected.items():
        record = roms[name]
        assert record['roms_checked'] == count
        for region in record['regions']:
            p=ROOT/region['path']
            assert p.stat().st_size == region['bytes']
            assert hashlib.sha256(p.read_bytes()).hexdigest() == region['sha256']
            for load in region['loads']:
                if 'raw_path' in load:
                    assert hashlib.sha1((ROOT/load['raw_path']).read_bytes()).hexdigest() == load['sha1']
    for path in ['roms/kyros.zip','roms/sstingry.zip','donors/fx68k/fx68k.sv','mister.env']:
        assert run(['git','check-ignore',path]), path+' must be ignored'
    qpf=(ROOT/'Alpha68k_N.qpf').read_text()
    assert 'Alpha68k_N' in qpf and 'Template' not in qpf
    qip=(ROOT/'files.qip').read_text()
    assert 'Alpha68k_N.sv' in qip and 'Alpha68k_N.sdc' in qip
    assert not run(['git','diff','--name-only','--','sys']), 'Template sys changed'
    assert not run(['git','diff','--cached','--name-only','--','sys']), 'Template sys index changed'
    plan=(ROOT/'plan.md').read_text()
    catalogue=(ROOT/'mamebug.md').read_text()
    for i in range(1,16):
        code=f'B{i:02d}'
        assert code in plan and code in catalogue, code+' not covered'
    for issue in ['1148','1149','3912','5959','2099']:
        assert (ROOT/f'research/online/mt{issue}.txt').is_file()
    limits=json.loads((ROOT/'resource_limits.json').read_text())
    assert [limits[x] for x in ['alm_pct','labs_pct','peak_interconnect_pct','average_interconnect_pct','m10k_pct','block_memory_bits_pct','dsp_pct']] == [80,90,85,60,90,85,90]
    upstream=(ROOT/'research/online/mame0289_driver.txt').read_text()
    local=(ROOT/'research/mame0289/src/mame/alpha/alpha68k_n.cpp').read_text()
    assert upstream == local,'Local source differs from 0289 tag after newline normalization'
    versions=json.loads((ROOT/'research/tool_versions.json').read_text())
    output={'preparation':'verified','template_commit':manifest['template']['commit'],
            'donors':donor_checks,'rom_required_files':expected,'driver_matches_mame0289_normalized':True,
            'issues_covered':15,'quartus':versions.get('quartus'),
            'reference_executable_limit':versions.get('mame'),
            'game_rtl_implemented':False,'simulation_gameplay_verified':False,
            'fpga_synthesis_fit_run':False,'rbf_built':False,'hardware_tested':False,
            'next_phase':'P1: obtain/select a matching executable with target drivers and capture references'}
    (ROOT/'research/preparation_verified.json').write_text(json.dumps(output,indent=2)+'\n')
    print('PREPARATION VERIFIED: 12 pinned donors; ROM audits 26/26/18; template/sys and project references; 15 issue obligations; strict resource ceilings; no build/hardware claims.')
    print('Evidence: research/preparation_verified.json. Next: P1 reference executable and captures.')


if __name__ == '__main__':
    main()
