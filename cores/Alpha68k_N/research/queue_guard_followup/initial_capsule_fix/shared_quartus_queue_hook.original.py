"""Short PreToolUse adapter. It never acquires a lease or launches a tool.

Only a literal single-command shell subset is rewritten. Ambiguous Quartus
execution fails closed through the supported hook deny response. Reports and
ordinary non-Quartus commands remain unchanged. RBF authority is separate.
"""
from __future__ import annotations
import argparse
import base64
import json
import ntpath
import re
import sys

CANONICAL = r"C:\Users\meath\.claude\skills\mister-rbf-build\scripts"
PYTHON = r"D:\vibes\fpga\toolchains\msys64\ucrt64\bin\python.exe"
FLOW = CANONICAL + r"\quartus_flow.ps1"
WORKER = CANONICAL + r"\quartus_worker.ps1"
RUNNER = CANONICAL + r"\shared_quartus_queue_run.py"
SAFE = {r"d:\vibes\fpga\bin\quartus-safe.ps1",r"d:\vibes\fpga\bin\quartus-safe.cmd"}
PROGRESS = {r"d:\vibes\fpga\bin\quartus-progress.ps1",r"d:\vibes\fpga\bin\quartus-progress.cmd",r"d:\vibes\fpga\bin\quartus-progress-launch.vbs"}
READERS = {"echo","printf","write-output","write-host","get-content","cat","type","rg","select-string","findstr","get-childitem","ls","grep","egrep","head","tail","wc","diff"}
# Killing Quartus by name/wildcard ends every session's queued build at once (exit -1 seen on two
# unrelated trees in the same second). Stop your own build with the canonical flow -Action Stop.
KILL_VERB = re.compile(r"(?i)(?<![a-z0-9_-])(stop-process|spps|taskkill|tskill|pkill|killall|kill)(?![a-z0-9_-])|\.kill\s*\(|terminateprocess|terminatejobobject")
QUARTUS_WORD = re.compile(r"(?i)quartus")
ALLOWED_TOOLS = set()  # Queued raw tools (none): full compiles go through the canonical flow.
# User scope 2026-10-10: analysis/synthesis/fit/STA checks run directly, unqueued and
# uncounted against the two lanes. Only full compiles and RBF/ASM/CPF are queued/gated.
CHECK_TOOLS = {"quartus_map","quartus_syn","quartus_fit","quartus_sta"}
CHECK_REFUSED_ARGS = {"--flow","--script","--eval"}
BUILD_TOOLS = {"quartus_asm","quartus_cpf"}
QT_TOKEN = re.compile(r"(?i)(?<![a-z0-9_-])(quartus_[a-z0-9_-]+)(?:\.(?:exe|ps1|cmd|py))?(?![a-z0-9_-])")

class Refusal(ValueError):
    pass

def canonical(value: str) -> str:
    return ntpath.normcase(ntpath.normpath(value.replace("/","\\")))

def words(command: str, shell: str) -> list[str]:
    if not isinstance(command,str) or len(command)>32768 or "\0" in command:
        raise Refusal("Invalid command extent")
    out=[]; token=[]; quote=None; active=False; i=0
    while i<len(command):
        c=command[i]
        if quote:
            if c==quote:
                if shell=="powershell" and quote=="'" and i+1<len(command) and command[i+1]=="'":
                    token.append("'");i+=2;continue
                quote=None;i+=1;continue
            if quote=='"' and c in "$`":raise Refusal("Interpolated shell argument")
            if shell=="bash" and quote=='"' and c=="\\":raise Refusal("Escaped double-quoted shell argument")
            token.append(c);i+=1;continue
        if c in "'\"":quote=c;active=True;i+=1;continue
        if c.isspace():
            if active:out.append("".join(token));token=[];active=False
            i+=1;continue
        if c in ";|<>(){}\r\n$`":raise Refusal("Compound, redirection or substitution syntax")
        if c=="&":
            if shell=="powershell" and not out and not active:
                out.append("&");i+=1;continue
            raise Refusal("Background/compound shell syntax")
        if shell=="bash" and c=="\\":raise Refusal("Unquoted shell escape")
        token.append(c);active=True;i+=1
    if quote:raise Refusal("Unterminated shell argument")
    if active:out.append("".join(token))
    if out and out[0]=="&":out=out[1:]
    return out

def deny(reason: str) -> dict:
    return {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":reason+" Use the canonical shared queue; queue admission does not authorize RBF assembly."}}

def shell_quote(value: str, shell: str) -> str:
    if shell=="powershell":return "'"+value.replace("'","''")+"'"
    return "'"+value.replace("'","'\"'\"'")+"'"

def unwrap(tokens: list[str], shell: str) -> tuple[str,list[str]]:
    if not tokens:raise Refusal("Empty command")
    exe=tokens[0];args=tokens[1:];stem=ntpath.basename(exe.replace("/","\\")).lower()
    if stem in {"powershell","powershell.exe","pwsh","pwsh.exe"}:
        lowered=[a.lower() for a in args]
        if "-file" not in lowered:raise Refusal("Delegated shell command has no literal -File")
        index=lowered.index("-file")
        if any(a.lower() not in {"-noprofile","-noninteractive","-executionpolicy","bypass"} for a in args[:index]):raise Refusal("Unsupported shell delegate options")
        if index+1>=len(args):raise Refusal("Missing script path")
        exe=args[index+1];args=args[index+2:]
    return exe,args

def classify(exe: str,args: list[str]) -> str:
    path=canonical(exe);stem=ntpath.splitext(ntpath.basename(path))[0].lower()
    low=[a.lower() for a in args]
    if path in PROGRESS or path==canonical(CANONICAL+r"\..\..\tools\quartus_report.py") or stem=="quartus_report":return "pass"
    if path==canonical(FLOW):
        if any(a in low for a in {"-globalslotroot","-globaltemproot"}):raise Refusal("Queue namespace override")
        action=low[low.index("-action")+1] if "-action" in low and low.index("-action")+1<len(low) else ""
        stage=low[low.index("-stage")+1] if "-stage" in low and low.index("-stage")+1<len(low) else "compile"
        if action=="convertrbf":raise Refusal("RBF conversion requires the separately approved mister-rbf-build workflow; no hook forwarding")
        if action=="start" and stage!="compile":raise Refusal("Independent stage tasks are refused; use one full canonical compile")
        # Pass the visible canonical flow unchanged; this hook does not grant an allow
        # decision or encode/hide an ASM-producing operation from other permissions.
        return "pass"
    if path==canonical(WORKER) or stem in {"quartus_flow","quartus_worker"}:raise Refusal("Direct worker or noncanonical flow delegation is unsupported")
    if path in SAFE or stem=="quartus-safe":
        if len(args)==1 and args[0].lower()=="status":return "pass"
        raise Refusal("Safe wrapper is held until its in-process shared lease patch is published")
    if stem in BUILD_TOOLS or stem=="quartus_sh":raise Refusal("Raw ASM/CPF/Quartus shell execution is not forwarded by the hook")
    if stem in CHECK_TOOLS:
        if any(a in low for a in CHECK_REFUSED_ARGS):raise Refusal("Delegated operation on a check-only Quartus tool")
        return "pass"
    if stem.startswith("quartus_"):
        if stem not in ALLOWED_TOOLS:raise Refusal("Unsupported Quartus tool")
        if path not in {canonical("D:\\q17\\quartus\\bin\\"+stem+".exe"),canonical("D:\\q17\\quartus\\bin64\\"+stem+".exe")}:raise Refusal("Quartus executable is not the fixed absolute tool path")
        if any(a in low for a in {"--flow","-t","--script","--eval"}):raise Refusal("Unsupported delegated Quartus operation")
        return "queue"
    raise Refusal("Unknown executable delegate containing Quartus is unsupported")

def is_check_only(command: str) -> bool:
    # Analysis/synth/fit/STA checks may use ordinary shell syntax (cd, pipes, &&) as long
    # as every Quartus token is a check tool and nothing names a build/queue delegate.
    tools={m.group(1).lower() for m in QT_TOKEN.finditer(command)}
    if not tools or not tools<=CHECK_TOOLS:return False
    if re.search(r"(?i)quartus-(?:safe|progress)|quartus_(?:flow|worker)|-encodedcommand|(?<![a-z0-9_-])-enc(?![a-z0-9_-])",command):return False
    low=command.lower()
    return not any(re.search(r"(?<![a-z0-9_-])"+re.escape(a)+r"(?![a-z0-9_-])",low) for a in CHECK_REFUSED_ARGS)

def adapt_shell(command: str,shell: str,cwd: str) -> tuple[str|None,str|None]:
    # A reader exemption is considered only after parsing one literal command.
    # Inspect only a bounded literal encoded PowerShell delegate; never execute it.
    encoded=re.search(r"(?i)(?:^|\s)-(?:encodedcommand|enc)\s+([A-Za-z0-9+/=]+)(?:\s|$)",command)
    if encoded:
        try:
            decoded=base64.b64decode(encoded.group(1),validate=True).decode("utf-16-le")
            if len(decoded)>32768:raise Refusal("Encoded delegate extent")
            if re.search(r"(?i)quartus[_-]",decoded):return None,"Encoded Quartus delegate is unsupported and must use the visible canonical flow"
        except (ValueError,UnicodeError):return None,"Malformed encoded shell delegate"
    if KILL_VERB.search(command) and QUARTUS_WORD.search(command):
        return None,"Killing Quartus processes by name/wildcard is refused: it ends other sessions' queued builds. Stop your own build with the canonical flow -Action Stop, or kill one exact PID you own without naming Quartus"
    suspicious=bool(QT_TOKEN.search(command) or re.search(r"(?i)quartus-(?:safe|progress)|quartus_(?:flow|worker)",command))
    if not suspicious:return None,None
    if is_check_only(command):return None,None
    try:
        token=words(command,shell)
        if token and token[0].lower() in READERS:return None,None
        exe,args=unwrap(token,shell)
        if ntpath.basename(exe).lower() in {"python","python.exe"}:
            rest=list(args)
            if rest[:1]==['-B']:rest=rest[1:]
            if rest[:2]==['-X','utf8']:rest=rest[2:]
            if rest and canonical(rest[0])==canonical(r"C:\Users\meath\.claude\tools\quartus_report.py"):return None,None
        kind=classify(exe,args)
        if kind=="pass":
            if ntpath.basename(exe).lower() in {"wsl","wsl.exe","bash","bash.exe","cmd","cmd.exe","python","python.exe"}:
                raise Refusal("Delegated Quartus shell/python command is unsupported")
            return None,None
        if not ntpath.isabs(cwd):raise Refusal("Absolute reviewed working directory required")
        packet={"schema":"shared-quartus-hook-command-v1","executable":exe,"arguments":args,"cwd":cwd}
        encoded=base64.b64encode(json.dumps(packet,ensure_ascii=False,separators=(",",":")).encode()).decode()
        prefix="& " if shell=="powershell" else ""
        rewritten=prefix+" ".join(shell_quote(a,shell) for a in [PYTHON,"-B","-X","utf8",RUNNER,"--request-base64",encoded])
        return rewritten,None
    except (Refusal,ValueError,IndexError) as e:return None,str(e)

def adapt(event: dict,client: str,default_shell: str,compat_exec: bool=False) -> dict:
    if not isinstance(event,dict):return deny("Malformed hook event")
    name=event.get("tool_name","");inp=event.get("tool_input");cwd=event.get("cwd","")
    if not isinstance(inp,dict):
        if "quartus" in str(name).lower():return deny("Unsupported structured Quartus input")
        return {}
    field=None;shell=default_shell
    if name in {"Bash","PowerShell"}:
        field="command";shell="powershell" if name=="PowerShell" else default_shell
    elif compat_exec and name in {"exec_command","functions.exec_command"}:field="cmd"
    else:
        # Unknown typed MCP execution cannot be safely converted into shell syntax.
        known=inp.get("command",inp.get("cmd",inp.get("executable","")))
        if isinstance(known,str) and re.search(r"(?i)quartus[_-]",known):return deny("Unsupported structured MCP Quartus execution")
        payload=inp.get("payload")
        if isinstance(payload,dict):
            known=payload.get("command",payload.get("executable",""))
            if isinstance(known,str) and re.search(r"(?i)quartus[_-]",known):return deny("Unsupported structured MCP Quartus execution")
        return {}
    command=inp.get(field)
    if not isinstance(command,str):return deny("Missing typed command field")
    if isinstance(inp.get("cwd"),str):cwd=inp["cwd"]
    if isinstance(inp.get("workdir"),str):cwd=inp["workdir"]
    replacement,error=adapt_shell(command,shell,cwd)
    if error:return deny(error)
    if replacement is None:return {}
    updated=dict(inp);updated[field]=replacement
    return {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":updated}}

def main() -> int:
    parser=argparse.ArgumentParser();parser.add_argument("--client",choices=["claude","codex"],required=True);parser.add_argument("--default-shell",choices=["bash","powershell"],required=True);parser.add_argument("--compat-exec-cmd",action="store_true");args=parser.parse_args()
    raw=sys.stdin.buffer.read(65537)
    try:
        if len(raw)>65536:raise Refusal("Hook input exceeds bound")
        event=json.loads(raw);result=adapt(event,args.client,args.default_shell,args.compat_exec_cmd)
    except Exception:result=deny("Malformed hook input; execution was not forwarded")
    sys.stdout.write(json.dumps(result,ensure_ascii=False,separators=(",",":"))+"\n");return 0

if __name__=="__main__":raise SystemExit(main())
