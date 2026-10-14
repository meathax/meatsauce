"""Frozen production-wrapper map/optional fit/STA. Never calls assembler."""
import argparse
import hashlib
import json
import re
import shutil
import subprocess
import time
from pathlib import Path
from timing_audit import audit

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


ROOT=Path(__file__).resolve().parents[1]
QUARTUS=Path(r"D:\q17\quartus\bin64")

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--fit',action='store_true',help='also fit and audit all four timing corners')
    parser.add_argument('--build-id',default='analysis-only',help='BUILD_DATE shown in the OSD (release: YYMMDD)')
    args=parser.parse_args()
    stamp=str(time.time_ns())
    stage=ROOT/"sim/obj_dir/production"/stamp
    stage.mkdir(parents=True)
    selected=[ROOT/"CrystalSystem.sv",ROOT/"files.qip",ROOT/"CrystalSystem.qsf",
              ROOT/"CrystalSystem.qpf",ROOT/"CrystalSystem.sdc"]
    for directory in ["rtl","sys","credits"]:
        selected += [f for f in (ROOT/directory).rglob("*") if f.is_file() and
                     not any(x in f.parts for x in ["db","incremental_db","output_files"])]
    selected.append(ROOT/"donors/sdram/src_v/sdram_axi_core.v")
    sources=[]
    for f in sorted(set(selected)):
        relative=f.relative_to(ROOT)
        destination=stage/relative
        destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(f,destination)
        sources.append({"path":relative.as_posix(),"sha256":hashlib.sha256(f.read_bytes()).hexdigest()})
    qsf=stage/"CrystalSystem.qsf"
    text=qsf.read_text().replace("GENERATE_RBF_FILE ON","GENERATE_RBF_FILE OFF")
    text=re.sub(r"NUM_PARALLEL_PROCESSORS ALL","NUM_PARALLEL_PROCESSORS 4",text)
    qsf.write_text(text)
    (stage/"build_id.v").write_text(chr(96)+'define BUILD_DATE "%s"'%args.build_id+chr(10))
    report={"scope":("real emu/sys_top production map/fit/STA with unchanged framework constraints; "
                     "closure requires nonnegative corners and constrained required paths; no RBF"
                     if args.fit else "real emu/sys_top production source analysis and resource inference; no fit/STA/pin closure or RBF"),
            "snapshot":str(stage),"sources":sources,"rbf_built":False,
             "stage_overrides":["GENERATE_RBF_FILE OFF","NUM_PARALLEL_PROCESSORS 4","build_id.v "+args.build_id]}
    report['configuration_sha256']={name:hashlib.sha256((stage/name).read_bytes()).hexdigest()
                                    for name in ['CrystalSystem.qsf','build_id.v']}
    (stage/"manifest.json").write_text(json.dumps(report,indent=2)+"\n")
    print("PRODUCTION_SNAPSHOT",stage,flush=True)
    report['steps']=[]
    started_all=time.monotonic()
    code=0
    for tool in ['quartus_map']+(['quartus_fit','quartus_sta'] if args.fit else []):
        command=[str(QUARTUS/(tool+'.exe')),'CrystalSystem']
        if tool!='quartus_sta':
            command+=['--read_settings_files=on','--write_settings_files=off']
        log=stage/(tool+'.log')
        started=time.monotonic()
        with log.open('w') as output:
            process=_sq_route_checked(subprocess.Popen, command,cwd=stage,stdout=output,stderr=subprocess.STDOUT)
            print('QUARTUS_PID',tool,process.pid,flush=True)
            code=process.wait()
        errors=[line for line in log.read_text(errors='replace').splitlines()
                if re.match(r'\s*(?:Error|Fatal Error)\b',line)][:20]
        step={'tool':tool,'returncode':code,'seconds':round(time.monotonic()-started,3),
              'command':command,'log':str(log),'errors':errors}
        report['steps'].append(step)
        print(json.dumps(step),flush=True)
        if code or errors:
            code=code or 1
            break
    report['status']='FAIL' if code else 'SYNTHESIS_PASS'
    if not code and args.fit:
        report['resources']=(stage/'output_files/CrystalSystem.fit.summary').read_text(errors='replace')
        report['timing_summary']=(stage/'output_files/CrystalSystem.sta.summary').read_text(errors='replace')
        try:
            report['path_audit']=audit(stage,QUARTUS,project='CrystalSystem')
        except (OSError,RuntimeError,ValueError) as error:
            report['path_audit']={'status':'AUDIT_ERROR','errors':[str(error)]}
        report['status']='TIMING_PASS' if report['path_audit']['status']=='AUDIT_PASS' else 'TIMING_FAIL'
        code=int(report['status']!='TIMING_PASS')
    changed=[item['path'] for item in sources if item['path']!='CrystalSystem.qsf'
             and hashlib.sha256((stage/item['path']).read_bytes()).hexdigest()!=item['sha256']]
    changed += [name for name,digest in report['configuration_sha256'].items()
                if hashlib.sha256((stage/name).read_bytes()).hexdigest()!=digest]
    if changed:
        report['changed_snapshot_inputs']=changed
        report['status']='FAIL'
        code=1
    report.update({'exit_code':code,'seconds':round(time.monotonic()-started_all,3),
                   'errors':[e for step in report['steps'] for e in step['errors']],
                   'source_bytes':sum((stage/item['path']).stat().st_size for item in sources)})
    (stage/"check_report.json").write_text(json.dumps(report,indent=2)+"\n")
    (ROOT/('docs/production_timing.json' if args.fit else 'docs/production_analysis.json')).write_text(json.dumps(report,indent=2)+"\n")
    print(json.dumps({key:report[key] for key in ['status',"exit_code","seconds","errors","scope","snapshot","source_bytes"]}),flush=True)
    return code or int(bool(report["errors"]))

if __name__=="__main__":
    raise SystemExit(main())
