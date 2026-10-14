"""Preserve stale job, prove original children absent, launch unique same-source fixture."""
from pathlib import Path
import hashlib, json, subprocess, sys, time

HERE=Path(__file__).resolve().parent
H=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    scope=HERE/'next_coupled_scope_v2'; old=scope/'frame0_constant_fixture'
    assert not (old/'build_exit.json').exists() and not (old/'run_exit.json').exists()
    win=subprocess.run(['powershell.exe','-NoProfile','-Command',
       'Get-CimInstance Win32_Process -Filter "ProcessId = 45032 OR ProcessId = 24900" | Select-Object ProcessId,CreationDate,CommandLine | ConvertTo-Json -Compress'],capture_output=True,text=True)
    linux=subprocess.run(['wsl.exe','-d','Ubuntu','--exec','/bin/ps','-eo','pid,ppid,etime,comm,args'],capture_output=True,text=True)
    assert win.returncode==linux.returncode==0 and not win.stdout.strip()
    assert not any(x in linux.stdout for x in ['frame0_constant_fixture','alpha68kn-render.7KfD3q','Valpha68kn_render_fixture'])
    report=old/'interruption_recovery.json';assert not report.exists()
    report.write_text(json.dumps({'schema':'owned_fixture_interruption_v1','observed':time.time(),
      'windows_query_exit':win.returncode,'windows_matches':win.stdout,
      'linux_query_exit':linux.returncode,'linux_processes':linux.stdout,
      'original_worker_absent':True,'original_child_absent':True,
      'no_terminal_receipt_no_acceptance':True,'root_fixture_sources_unchanged':True},indent=2)+'\n')
    original=HERE/'run_frame0_constant_fixture.py'
    assert H(original)=='00f2359a4758f6cb33127f9b43fdd4600b1d712a03ba098affa3defec60edb06'
    text=original.read_text();needle="JOB=SCOPE/'frame0_constant_fixture'";assert text.count(needle)==1
    helper=HERE/'run_frame0_constant_fixture_recovery_v2.py';assert not helper.exists()
    helper.write_text(text.replace(needle,"JOB=SCOPE/'frame0_constant_fixture_recovery_v2'"),encoding='utf8',newline='\n')
    launch=subprocess.run([sys.executable,'-X','utf8',str(helper),'launch'],capture_output=True,text=True)
    print(json.dumps({'launch_exit':launch.returncode,'stdout':launch.stdout,'stderr':launch.stderr,
       'original_interruption_sha256':H(report),'helper_sha256':H(helper)}))
    raise SystemExit(launch.returncode)
if __name__=='__main__':main()
