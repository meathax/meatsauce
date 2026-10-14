"""Materialize final primary evidence and tool versions; no FPGA compilation."""
from pathlib import Path
import concurrent.futures
import difflib
import hashlib
import html
import json
import re
import subprocess
import urllib.request
import xml.etree.ElementTree as ET

# Shared global Quartus routing: native stages require a registered whole-job recipe.
import hashlib as _sq_hashlib
import os as _sq_os
import pathlib as _sq_pathlib
import re as _sq_re

def _sq_qpf_guard(cwd, revision):
    if not isinstance(revision, str) or not _sq_re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", revision):
        raise RuntimeError("Shared Quartus queue: invalid project/revision")
    root = _sq_pathlib.Path(cwd)
    if not root.is_absolute():
        raise RuntimeError("Shared Quartus queue: absolute project root required")
    qpf = root / (revision + ".qpf")
    for part in (qpf, *qpf.parents):
        if part.is_symlink() or (part.exists() and getattr(part.lstat(), "st_file_attributes", 0) & 0x400):
            raise RuntimeError("Shared Quartus queue: reparse project refused")
    with qpf.open("rb") as stream:
        raw = stream.read(65537)
    if len(raw) > 65536:
        raise RuntimeError("Shared Quartus queue: QPF size exceeded")
    revisions = _sq_re.findall(r'^\s*PROJECT_REVISION\s*=\s*"([A-Za-z0-9_.-]+)"\s*$', raw.decode("utf-8-sig"), _sq_re.M)
    if revisions != [revision]:
        raise RuntimeError("Shared Quartus queue: project must equal the sole QPF revision")
    return {"bytes": len(raw), "sha256": _sq_hashlib.sha256(raw).hexdigest()}

def _sq_route_checked(execute, *args, **kwargs):
    command = args[0] if args else kwargs.get("args")
    tokens = list(command) if isinstance(command, (list, tuple)) else None
    native = _sq_re.compile(r'^(?:quartus_(?:sh|map|fit|sta|asm|eda|cdb|pow)|qsys-(?:script|generate))(?:\.exe)?$', _sq_re.I)
    if tokens:
        basename = str(tokens[0]).replace("\\", "/").rsplit("/", 1)[-1]
        is_native = bool(native.fullmatch(basename))
    else:
        is_native = isinstance(command, str) and bool(_sq_re.search(r'\b(?:quartus_(?:sh|map|fit|sta|asm|eda|cdb|pow)|qsys-(?:script|generate))(?:\.exe)?\b', command, _sq_re.I))
    if not is_native:
        return execute(*args, **kwargs)
    cwd = kwargs.get("cwd", _sq_os.getcwd())
    if tokens and basename.lower() in {"quartus_sh", "quartus_sh.exe"} and tokens[1:] == ["--version"]:
        replacement = [r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", r"C:\Users\meath\.claude\skills\mister-rbf-build\scripts\quartus_flow.ps1", "-Action", "Version", "-ProjectRoot", str(_sq_pathlib.Path(cwd).absolute())]
    elif tokens and len(tokens) == 6 and tokens[1:3] == ["--flow", "compile"] and tokens[4] == "-c" and tokens[3] == tokens[5]:
        _sq_qpf_guard(cwd, tokens[3])
        output = kwargs.get("stdout")
        outer = getattr(output, "name", None)
        suffix = ".queue-launch.log"
        if not isinstance(outer, str) or not outer.endswith(suffix):
            raise RuntimeError("Shared Quartus queue: full compile requires an owned native log and queue-launch log adapter")
        helper = _sq_pathlib.Path(r"C:\Users\meath\.claude\skills\mister-rbf-build\scripts\shared_quartus_full_compile.py")
        raw = helper.read_bytes()
        if len(raw) != 2883 or _sq_hashlib.sha256(raw).hexdigest() != "f72df4cd9c291947a026fb0dec80d8f66650f9d6eacc522ca9b1e4277fb4c86e":
            raise RuntimeError("Shared Quartus queue: canonical helper identity changed")
        replacement = [r"D:\vibes\fpga\toolchains\msys64\ucrt64\bin\python.exe", "-B", "-X", "utf8", str(helper), "--cwd", str(cwd), "--revision", tokens[3], "--log", outer[:-len(suffix)]]
    else:
        raise RuntimeError("Shared Quartus queue: standalone or mixed stages are refused; use quartus_flow.ps1 -Action Start with a reviewed complete -RecipeId. Version/provider reads use -Action Version. This refusal does not authorize assembly.")
    if args:
        return execute(replacement, *args[1:], **kwargs)
    return execute(**dict(kwargs, args=replacement))


ROOT = Path(__file__).resolve().parents[1]


def fetch(url, name):
    target = ROOT / 'research/online' / name
    if not target.exists():
        request = urllib.request.Request(url, headers={'User-Agent': 'Alpha68kN-local-research/1.0'})
        target.write_bytes(urllib.request.urlopen(request, timeout=25).read())
    return target


def main():
    source = (ROOT / 'research/mame0289/src/mame/alpha/alpha68k_n.cpp').read_text()
    upstream = (ROOT / 'research/online/mame0289_driver.txt').read_text()
    manifest = json.loads((ROOT / 'research/online_manifest.json').read_text())
    for record in manifest:
        if record['id'] in ('mame0289_driver', 'mame_master_driver'):
            record['matches_local_driver'] = (ROOT / record['path']).read_text() == source
    (ROOT / 'research/online_manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print('DRIVER normalized match to mame0289:', source == upstream)
    if source != upstream:
        print('DRIVER_DIFF', '\n'.join(list(difflib.unified_diff(upstream.splitlines(), source.splitlines()))[:45]))
    print('CONFIG', '\n'.join(f'{i}: {line.strip()}' for i,line in enumerate(source.splitlines(),1)
          if 700 <= i <= 825 and re.search(r'CPU|Z80|M68000|I8748|XTAL|Hz|set_|route|periodic',line)))
    print('GFX_INIT', '\n'.join(f'{i}: {line.strip()}' for i,line in enumerate(source.splitlines(),1)
          if re.search(r'm_tile_|m_coin_id|m_microcontroller_id|GAME\(',line) and i > 980))
    print('LAYOUT', '\n'.join(re.sub(r'\s+', ' ', m[0]) for m in re.finditer(r'static const gfx_layout\s+\w+\s*=\s*\{.*?\};', source,re.S)))
    histories = [json.loads((ROOT/'research/online'/p).read_text()) for p in ['driver_history.json','prior_driver_history.json']]
    selected = [x for rows in histories for x in rows if re.search(r'kyros|sstingry|MT2099|transparent color',x['commit']['message'],re.I)]
    jobs = {x['sha']: f'https://api.github.com/repos/mamedev/mame/commits/{x["sha"]}' for x in selected}
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        futures = {pool.submit(fetch,url,'commit_'+commit+'.json'):commit for commit,url in jobs.items()}
        for future in concurrent.futures.as_completed(futures):
            try:
                result = json.loads(future.result().read_text())
                if result['sha'].startswith(('d30361','d7d831','28192','12cc55','102be5','4536b6')):
                    changes = [f.get('patch','') for f in result['files'] if 'alpha68k' in f['filename']]
                    print('FIX', result['sha'], result['commit']['message'].splitlines()[0],
                          '\n'.join(changes)[:2100])
            except Exception as e:
                print('COMMIT_FETCH_LIMIT',futures[future],str(e))
    try:
        issue = fetch('https://mametesters.org/view.php?id=2099','mt2099.txt').read_text()
        issue = re.sub(r'\s+',' ',html.unescape(re.sub('<[^>]+>',' ',issue)))
        p = issue.find('Viewing Issue');print('MT2099',issue[p:p+1600])
    except Exception as e: print('MT2099_FETCH_LIMIT',str(e))
    mame = Path(r'D:\Arcade\AI\mame289\mame.exe')
    versions = {}
    if mame.exists():
        result = _sq_route_checked(subprocess.run, [str(mame),'-version'],capture_output=True,text=True,cwd=ROOT)
        versions['mame'] = {'path':str(mame),'version':result.stdout.strip(),'exit_code':result.returncode,'stderr':result.stderr.strip()}
        print('MAME_VERSION',versions['mame'])
        versions['mame']['supported_targets'] = []
        versions['mame']['missing_targets'] = []
        for name in ['kyros','kyrosj','sstingry']:
            result = _sq_route_checked(subprocess.run, [str(mame),'-listxml',name],capture_output=True,text=True,cwd=ROOT)
            if result.returncode:
                versions['mame']['missing_targets'].append(name)
                (ROOT/'research'/f'{name}_listxml_unavailable.txt').write_text(result.stdout+result.stderr)
                print('MAME_TARGET_UNAVAILABLE',name,result.returncode,result.stderr.strip())
                continue
            versions['mame']['supported_targets'].append(name)
            (ROOT/'research'/f'{name}.xml').write_text(result.stdout,encoding='utf-8')
            machine = ET.fromstring(result.stdout).find('machine')
            print('MAME_XML',name,[(x.get('tag'),x.get('type'),x.get('clock')) for x in machine.findall('chip')],
                  machine.find('driver').attrib,machine.find('display').attrib)
        for pattern in ['kyros*','sstingry']:
            if not versions['mame']['supported_targets']:
                break
            result = _sq_route_checked(subprocess.run, [str(mame),'-verifyroms',pattern,'-rompath',str(ROOT/'roms')],capture_output=True,text=True,cwd=ROOT)
            log = result.stdout + result.stderr
            (ROOT/'research'/f'verifyroms_{pattern.replace("*","all")}.txt').write_text(log)
            print('MAME_VERIFYROMS',pattern,result.returncode,log.strip()[-1300:])
    quartus = Path(r'D:\q17\quartus\bin64\quartus_sh.exe')
    if quartus.exists():
        result = _sq_route_checked(subprocess.run, [str(quartus),'--version'],capture_output=True,text=True)
        versions['quartus'] = {'path':str(quartus),'version':result.stdout.strip(),'exit_code':result.returncode,'stderr':result.stderr.strip()}
        print('QUARTUS_VERSION',result.stdout.strip())
    (ROOT/'research/tool_versions.json').write_text(json.dumps(versions,indent=2)+'\n')
    print('JTFRAME_CPUS', [p.relative_to(ROOT/'donors').as_posix() for d in ['cpu/t80','cpu/t48'] for p in (ROOT/'donors/jtcores/modules/jtframe/hdl'/d).glob('*.v')])
    for name in ['donors/jt49/hdl/jt49.v','donors/jt12/hdl/jt03.v','donors/jtcores/modules/jtframe/hdl/cpu/t80/T80s.v','donors/jtcores/modules/jt680x/hdl/jt6805.v']:
        p=ROOT/name;txt=p.read_text(errors='replace'); start=txt.find('module ')
        end=txt.find(');',start);print('PORTS',name,txt[start:min(end+2,start+1400)])
    print('DONE: evidence and ROM auditing only; no Quartus map/fit/assembly, simulation, hardware use or publication.')


if __name__ == '__main__':
    main()
