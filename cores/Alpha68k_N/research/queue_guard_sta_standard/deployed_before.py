"""Short PreToolUse adapter. It never acquires a lease or launches a tool.

Only a literal single-command shell subset is rewritten. Ambiguous Quartus
execution fails closed through the supported hook deny response. Reports and
ordinary non-Quartus commands remain unchanged. RBF authority is separate.
"""
from __future__ import annotations
import argparse
import ast
import base64
import hashlib
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
CHECK_REFUSED_ARGS = {"--flow","--script","--eval","-t","-s","--tcl_eval","--tcl-eval","--shell"}
BUILD_TOOLS = {"quartus_asm","quartus_cpf"}
FAST_FRONTEND = r"C:\Users\meath\QuartusFast\quartus-fast.ps1"
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
        if c in "\r\n":raise Refusal("Multiple command lines are unsupported")
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
    return {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":reason+" Use the reviewed QuartusFast frontend for check-only work; full compiles require the shared queue and separate explicit RBF authorization."}}

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

def literal_flow_options(args: list[str]) -> dict[str,str]:
    """Inspect PowerShell parameter colon forms/unique abbreviations consistently."""
    protected={'-action','-stage','-globalslotroot','-globaltemproot','-quartusfast'}
    result={}
    for index,arg in enumerate(args):
        flag,sep,value=arg.lower().partition(':')
        matches=[name for name in protected if flag.startswith('-') and name.startswith(flag)]
        if len(matches)>1:raise Refusal('Ambiguous protected queue parameter')
        if not matches:continue
        name=matches[0]
        if name in result:raise Refusal('Duplicate protected queue parameter')
        if name=='-quartusfast':raise Refusal('Unknown fast delegate on canonical queue flow')
        if not sep:
            if index+1>=len(args):raise Refusal('Missing protected queue parameter value')
            value=args[index+1]
        result[name]=value
    return result


def validate_fast(args: list[str]) -> None:
    """Validate the visible canonical V2 CLI; assembly authority stays separate."""
    if not args: raise Refusal('Missing QuartusFast action')
    action=args[0]
    plain={'status','selftest','enable','performance-report','restore-v1'}
    if action in plain:
        if len(args)!=1: raise Refusal('Unexpected QuartusFast flag')
        return
    project_actions={'build','benchmark','quick-check','synth-only','turbo','turbo-rbf','release','memory-update','plan','autotune'}
    if action in project_actions:
        value_flags={'--project','--revision','--threads','--affinity','--wait-seconds'}
        bool_flags={'--force','--allow-rbf'}
        if action in {'build','benchmark'}:
            value_flags|={'--mode','--placement','--router','--reviewed-check-policy','--cache-namespace'}
            bool_flags|={'--no-fallback','--checks-only'}
        if action in {'benchmark','autotune'}: value_flags.add('--repeats')
        if action in {'turbo','turbo-rbf','autotune'}: value_flags|={'--placement','--router'}; bool_flags.add('--no-fallback')
        if action=='benchmark': bool_flags.add('--sweep')
        value_flags.add('--accept-critical-warning')
    elif action in {'profile','diagnose'}:
        value_flags=set(); bool_flags={'--atom-schema'}
        if action=='diagnose': value_flags|={'--project','--revision','--affinity','--accept-critical-warning'}
    elif action=='run':
        value_flags={'--recipe'};bool_flags={'--allow-rbf'}
    elif action=='verify':
        value_flags={'--receipt','--accept-critical-warning'};bool_flags=set()
    elif action=='doctor':
        value_flags=set();bool_flags={'--validate'}
    elif action=='rollback':
        value_flags=set();bool_flags={'--uninstall','--purge-data'}
    elif action=='install':
        value_flags={'--root'};bool_flags=set()
    else: raise Refusal('Unsupported QuartusFast action')
    seen=set();values={};index=1
    while index<len(args):
        flag=args[index]
        if flag not in value_flags|bool_flags or (flag in seen and flag!='--accept-critical-warning'):
            raise Refusal('Unknown or duplicate QuartusFast flag')
        seen.add(flag);index+=1
        if flag in value_flags:
            if index>=len(args) or args[index].startswith('--'): raise Refusal('Missing QuartusFast flag value')
            values[flag]=args[index];index+=1
            if flag=='--accept-critical-warning' and (not values[flag].isascii() or not values[flag].isdecimal()): raise Refusal('Invalid warning ID')
    if action in project_actions or (action=='diagnose' and '--project' in values):
        project=values.get('--project','')
        if not ntpath.isabs(project) or ntpath.splitext(project)[1].lower()!='.qpf':
            raise Refusal('QuartusFast requires a literal absolute QPF path')
        if not ntpath.splitdrive(project)[0]: raise Refusal('QuartusFast requires a drive-qualified or UNC QPF path')
        if '--revision' in values and not re.fullmatch(r'[\w. -]+',values['--revision']): raise Refusal('Invalid QuartusFast revision')
    if action=='diagnose' and '--revision' in values and '--project' not in values: raise Refusal('Diagnostic revision requires a project')
    if '--mode' in values and values['--mode'] not in {'dev-fast','dev-safe','release'}: raise Refusal('Unknown QuartusFast mode')
    for flag,maximum in (('--threads',32),('--wait-seconds',86400),('--repeats',5)):
        if flag in values:
            value=values[flag]; minimum=2 if flag=='--repeats' else 1
            if not value.isascii() or not value.isdecimal() or not minimum<=int(value)<=maximum:
                raise Refusal('Invalid QuartusFast '+flag+' value')
    if '--affinity' in values and values['--affinity'] not in {'queue-default','p-cores','physical-p-cores','all-cores','e-cores'}:
        raise Refusal('Unknown QuartusFast affinity')
    for flag,allowed in (('--placement',{0.2,0.35,0.5,0.75,1.0}),('--router',{0.75,1.0})):
        if flag in values:
            try: value=float(values[flag])
            except ValueError: raise Refusal('Invalid QuartusFast effort')
            if value not in allowed: raise Refusal('Invalid QuartusFast effort')
    if '--accept-critical-warning' in values and not values['--accept-critical-warning'].isascii(): raise Refusal('Invalid warning ID')
    if '--accept-critical-warning' in values and not values['--accept-critical-warning'].isdecimal(): raise Refusal('Invalid warning ID')
    if {'--allow-rbf','--checks-only'}<=seen: raise Refusal('Conflicting QuartusFast assembly/check flags')
    if action in {'turbo-rbf','release','memory-update','run'} and '--allow-rbf' not in seen:
        raise Refusal('Complete QuartusFast RBF jobs require --allow-rbf and separate explicit user authorization')
    if action=='run' and not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}',values.get('--recipe','')): raise Refusal('Invalid reviewed recipe ID')
    if action=='verify' and not ntpath.isabs(values.get('--receipt','')): raise Refusal('Receipt path must be absolute')
    if '--reviewed-check-policy' in values and not ntpath.isabs(values['--reviewed-check-policy']): raise Refusal('Reviewed policy path must be absolute')
    if action=='install' and '--root' in values and ntpath.normcase(ntpath.normpath(values['--root']))!=ntpath.normcase(ntpath.dirname(FAST_FRONTEND)):
        raise Refusal('Install uses the canonical QuartusFast root')
    if '--purge-data' in seen and '--uninstall' not in seen: raise Refusal('Data purge requires explicit uninstall')
    # This hook acquires no slot and never grants RBF authority. The allow flag
    # remains visible to approval review; the controller uses the existing FIFO.
    # This hook acquires no slot and never grants RBF authority. The allow flag
    # remains visible to approval review; the controller uses the existing FIFO.
    # --allow-rbf remains visible to ordinary approval review. Reviewed controller
    # routes that full compile through the shared FIFO; this hook acquires no lane.



class ReadonlyEvidence:
    """Finite typed AST grammar for literal Python evidence reads, never a runner.

    No eval/exec, subprocess, arbitrary imports/calls, attribute traversal, writes,
    user functions or dynamic Path values. Binding types prevent builtin shadowing.
    """
    def __init__(self):
        self.bindings={}; self.path_imported=False

    def bind(self, target, typ):
        if isinstance(target,ast.Name):
            if target.id in {'Path','print','enumerate','str','len'} or target.id.startswith('_'):
                raise ValueError('protected binding')
            self.bindings[target.id]=typ
        elif isinstance(target,(ast.Tuple,ast.List)) and isinstance(typ,tuple) and typ[0]=='tuple' and len(target.elts)==len(typ[1]):
            for item,value in zip(target.elts,typ[1]):self.bind(item,value)
        else:raise ValueError('unsupported binding')

    def element(self, typ):
        if typ=='str':return 'str'
        if isinstance(typ,tuple) and typ[0]=='seq':return typ[1]
        raise ValueError('not a bounded data sequence')

    def expr(self, node):
        if isinstance(node,ast.Constant) and type(node.value) in {str,int,bool,type(None)}:
            return type(node.value).__name__
        if isinstance(node,ast.Name):return self.bindings[node.id]
        if isinstance(node,(ast.List,ast.Tuple)):
            types=[self.expr(e) for e in node.elts]
            if isinstance(node,ast.Tuple):return ('tuple',types)
            if types and any(t!=types[0] for t in types):raise ValueError('mixed sequence')
            return ('seq',types[0] if types else 'str')
        if isinstance(node,ast.Subscript):
            typ=self.expr(node.value)
            if isinstance(node.slice,ast.Slice):
                for n in (node.slice.lower,node.slice.upper,node.slice.step):
                    if n is not None and self.expr(n)!='int':raise ValueError('slice type')
                self.element(typ);return typ
            if self.expr(node.slice)!='int':raise ValueError('index type')
            if isinstance(typ,tuple) and typ[0]=='tuple' and isinstance(node.slice,ast.Constant):return typ[1][node.slice.value]
            return self.element(typ)
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,(ast.USub,ast.UAdd)) and self.expr(node.operand)=='int':return 'int'
        if isinstance(node,ast.UnaryOp) and isinstance(node.op,ast.Not):self.expr(node.operand);return 'bool'
        if isinstance(node,ast.Compare):
            if any(not isinstance(op,(ast.Eq,ast.NotEq,ast.Lt,ast.LtE,ast.Gt,ast.GtE,ast.In,ast.NotIn)) for op in node.ops):raise ValueError('comparison')
            for item in [node.left]+node.comparators:self.expr(item)
            return 'bool'
        if isinstance(node,ast.BoolOp):
            for item in node.values:self.expr(item)
            return 'bool'
        if isinstance(node,ast.BinOp) and isinstance(node.op,ast.Add):
            left=self.expr(node.left);right=self.expr(node.right)
            if left==right and left in {'str','int'}:return left
            raise ValueError('addition type')
        if isinstance(node,ast.BinOp) and isinstance(node.op,ast.Div) and self.expr(node.left)=='path' and isinstance(node.right,ast.Constant) and isinstance(node.right.value,str):return 'path'
        if isinstance(node,ast.JoinedStr):
            for item in node.values:
                if isinstance(item,ast.FormattedValue):
                    typ=self.expr(item.value)
                    if typ not in {'str','int','bool','NoneType'} or item.format_spec is not None:raise ValueError('format type')
                elif not isinstance(item,ast.Constant):raise ValueError('format node')
            return 'str'
        if isinstance(node,(ast.ListComp,ast.GeneratorExp)):
            for gen in node.generators:
                if gen.is_async:raise ValueError('async')
                self.bind(gen.target,self.element(self.expr(gen.iter)))
                for test in gen.ifs:self.expr(test)
            return ('seq',self.expr(node.elt))
        if isinstance(node,ast.Call):return self.call(node)
        raise ValueError('unsupported expression')

    def call(self,node):
        if any(kw.arg is None for kw in node.keywords):raise ValueError('expanded call')
        if isinstance(node.func,ast.Name):
            name=node.func.id
            if name=='print':
                if any(kw.arg not in {'sep','end'} or self.expr(kw.value)!='str' for kw in node.keywords):raise ValueError('print target')
                for arg in node.args:self.expr(arg)
                return 'NoneType'
            if name=='Path' and self.path_imported and len(node.args)==1 and not node.keywords and isinstance(node.args[0],ast.Constant) and isinstance(node.args[0].value,str) and ntpath.isabs(node.args[0].value):return 'path'
            if name=='enumerate' and len(node.args)==1 and not node.keywords:return ('seq',('tuple',['int',self.element(self.expr(node.args[0]))]))
            if name=='len' and len(node.args)==1 and not node.keywords:self.element(self.expr(node.args[0]));return 'int'
            if name=='str' and len(node.args)==1 and not node.keywords and self.expr(node.args[0]) in {'str','int','bool','NoneType','path'}:return 'str'
            raise ValueError('untrusted function')
        if not isinstance(node.func,ast.Attribute):raise ValueError('call shape')
        typ=self.expr(node.func.value);method=node.func.attr
        if typ=='path' and method=='read_text' and not node.args and all(kw.arg in {'encoding','errors'} and isinstance(kw.value,ast.Constant) and isinstance(kw.value.value,str) for kw in node.keywords):return 'str'
        if typ=='path' and method=='exists' and not node.args and not node.keywords:return 'bool'
        if typ=='str' and method=='splitlines' and not node.args and not node.keywords:return ('seq','str')
        if typ=='str' and method in {'lower','upper'} and not node.args and not node.keywords:return 'str'
        if typ=='str' and method=='join' and len(node.args)==1 and not node.keywords and self.element(self.expr(node.args[0]))=='str':return 'str'
        raise ValueError('untrusted method')

    def stmt(self,node):
        if isinstance(node,ast.ImportFrom) and node.module=='pathlib' and node.level==0 and len(node.names)==1 and node.names[0].name=='Path' and node.names[0].asname is None:
            self.path_imported=True;return
        if isinstance(node,ast.Assign) and len(node.targets)==1:self.bind(node.targets[0],self.expr(node.value));return
        if isinstance(node,ast.Expr) and isinstance(node.value,ast.Call) and isinstance(node.value.func,ast.Name) and node.value.func.id=='print':
            if any(kw.arg not in {'sep','end'} or self.expr(kw.value)!='str' for kw in node.value.keywords):raise ValueError('print target')
            for arg in node.value.args:self.expr(arg)
            return
        if isinstance(node,ast.For) and not node.orelse:
            self.bind(node.target,self.element(self.expr(node.iter)))
            for item in node.body:self.stmt(item)
            return
        if isinstance(node,ast.If):
            self.expr(node.test)
            # Each branch is independently checked; no unsafe callable bindings exist.
            for item in node.body+node.orelse:self.stmt(item)
            return
        if isinstance(node,ast.Expr):self.expr(node.value);return
        raise ValueError('unsupported statement')


def readonly_python(args: list[str]) -> bool:
    rest=list(args)
    if rest[:1]==['-B']:rest=rest[1:]
    if rest[:2]==['-X','utf8']:rest=rest[2:]
    if len(rest)!=2 or rest[0]!='-c' or len(rest[1])>16000:return False
    try:
        tree=ast.parse(rest[1])
        if sum(1 for _ in ast.walk(tree))>1500:return False
        checker=ReadonlyEvidence()
        for item in tree.body:checker.stmt(item)
        return True
    except (SyntaxError,ValueError,KeyError,IndexError,TypeError):return False


def readonly_powershell_projection(command: str, shell: str) -> bool:
    """Finite literal local evidence pipeline; no expressions or executable stages."""
    if shell != 'powershell' or not isinstance(command,str) or len(command)>32768 or '\0' in command:return False
    # Split only unquoted pipes. words() still validates every complete stage,
    # including its existing outside-quote CR/LF and expression refusals.
    stages=[]; start=0; quote=None; i=0
    while i<len(command):
        c=command[i]
        if quote:
            if c==quote:
                if quote=="'" and i+1<len(command) and command[i+1]=="'":
                    i+=2;continue
                quote=None
        elif c in "'\"":quote=c
        elif c=='|':stages.append(command[start:i]);start=i+1
        i+=1
    stages.append(command[start:])
    if not 1<=len(stages)<=3:return False
    try:
        tokens=[words(stage,shell) for stage in stages]
        if any(not item for item in tokens):return False
        first=tokens[0]; name=first[0].lower(); args=first[1:]
        def unsigned(value,maximum,minimum=0):
            return value.isascii() and value.isdecimal() and minimum<=int(value)<=maximum
        def properties(value):
            return all(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*',p) for p in value.split(','))
        if name=='get-content':
            # This exception is only for bounded file projections, not lone reads
            # (which retain the previous single-command grammar).
            if len(tokens)<2:return False
            seen=set(); index=0
            while index<len(args):
                flag=args[index].lower();index+=1
                if flag not in {'-literalpath','-path','-totalcount','-tail'} or flag in seen or index>=len(args):return False
                seen.add(flag);value=args[index];index+=1
                if flag in {'-totalcount','-tail'} and not unsigned(value,10000,1):return False
                if flag in {'-literalpath','-path'} and (not value or value.startswith('-')):return False
            if len(seen & {'-literalpath','-path'})!=1:return False
            if '-totalcount' in seen and '-tail' in seen:return False
        elif name=='get-ciminstance':
            # Local, intrinsically read-only process enumeration; no session,
            # remote credentials, method execution, or arbitrary provider.
            index=0;seen=set();classname=None
            if args and not args[0].startswith('-'):classname=args[0];index=1
            while index<len(args):
                flag=args[index].lower();index+=1
                if flag not in {'-classname','-filter'} or flag in seen or index>=len(args):return False
                seen.add(flag);value=args[index];index+=1
                if flag=='-classname':
                    if classname is not None:return False
                    classname=value
                elif not value or len(value)>2048:return False
            if classname is None or classname.lower()!='win32_process':return False
        else:return False
        bounded=name=='get-ciminstance'
        for index,item in enumerate(tokens[1:],1):
            stage_name=item[0].lower();args=item[1:]
            if stage_name=='select-object':
                seen=set();j=0
                while j<len(args):
                    flag=args[j].lower();j+=1
                    if not flag.startswith('-') and j==1:
                        if not properties(flag):return False
                        seen.add('-property');continue
                    if flag not in {'-skip','-first','-property'} or flag in seen or j>=len(args):return False
                    seen.add(flag);value=args[j];j+=1
                    if flag=='-skip' and not unsigned(value,1000000):return False
                    if flag=='-first':
                        if not unsigned(value,10000,1):return False
                        bounded=True
                    if flag=='-property' and not properties(value):return False
                if not seen:return False
            elif stage_name=='format-list' and index==len(tokens)-1 and name=='get-ciminstance':
                if args[:1] and args[0].lower()=='-property':args=args[1:]
                if len(args)>1 or (args and not properties(args[0])):return False
            else:return False
        return bounded
    except (Refusal,ValueError,IndexError):return False


def readonly_shell_evidence(command: str, shell: str) -> bool:
    """Literal reads or finite evidence projections; no executable preprocessor."""
    if readonly_powershell_projection(command,shell):return True
    try:
        tokens=words(command,shell)
        if not tokens:return False
        if tokens[0].lower() in READERS:
            if tokens[0].lower()=='rg' and any(a.lower()=='--pre' or a.lower().startswith('--pre=') for a in tokens[1:]):return False
            return True
        exe,args=unwrap(tokens,shell)
        if ntpath.basename(exe).lower() in {'python','python.exe','python3','python3.exe'}:
            return readonly_python(args)
        return False
    except (Refusal,ValueError,IndexError):return False


def reviewed_sta_collector(exe: str, args: list[str]) -> bool:
    """One reviewed, hash-pinned report-only collector on this fitted database.

    Never delegate arbitrary Tcl. Exact project/output arguments also keep report
    writes inside the already reviewed isolated check workspace. No tool launches
    or queue/RBF authority are granted by this predicate.
    """
    if canonical(exe)!=canonical(r'D:/q17/quartus/bin64/quartus_sta.exe'):return False
    if len(args)!=5 or args[0]!='-t':return False
    collector_root=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/'
    approved_collectors={
        canonical(collector_root+'all-corners.tcl'):'3309f3c72b10bdc50443f4891f5791f08748dd4ce9df5fc451d4ec650176780a',
        canonical(collector_root+'all-corners-detail.tcl'):'ab3bffea354fa2dd1aa70cc98d8e128cd7c6bf64045c7b14e86e0f93bac02aab',
    }
    collector=args[1]
    expected_hash=approved_collectors.get(canonical(collector))
    if expected_hash is None:return False
    project=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_full_map/Alpha68k_N'
    output=r'D:/Arcade/AI/aCORES/Alpha68k N/research/sound_write_width/case2_fit_sta/all-corners'
    if canonical(args[2])!=canonical(project):return False
    if args[3]!='Alpha68k_N' or canonical(args[4])!=canonical(output):return False
    try:
        with open(collector,'rb') as evidence:content=evidence.read(65537)
        return len(content)<=65536 and hashlib.sha256(content).hexdigest()==expected_hash
    except (OSError,ValueError):return False


def classify(exe: str,args: list[str]) -> str:
    path=canonical(exe);stem=ntpath.splitext(ntpath.basename(path))[0].lower()
    low=[a.lower() for a in args]
    if path==canonical(FAST_FRONTEND):
        validate_fast(args)
        # Visible command stays unchanged: no permission allow, lease or launch here.
        return "pass"
    if stem=="quartus-fast":raise Refusal("Noncanonical QuartusFast frontend")
    if path in PROGRESS or path==canonical(CANONICAL+r"\..\..\tools\quartus_report.py") or stem=="quartus_report":return "pass"
    if path==canonical(FLOW):
        if any(a=="-quartusfast" or a.startswith("-quartusfast=") for a in low):raise Refusal("Unknown fast delegate on canonical queue flow")
        flow_options=literal_flow_options(args)
        if any(name in flow_options for name in {"-globalslotroot","-globaltemproot"}):raise Refusal("Queue namespace override")
        action=flow_options.get("-action","").lower()
        stage=flow_options.get("-stage","compile").lower()
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
        if reviewed_sta_collector(exe,args):return "pass"
        if any(a==flag or a.startswith(flag+"=") for a in low for flag in CHECK_REFUSED_ARGS):raise Refusal("Delegated operation on a check-only Quartus tool")
        return "pass"
    if stem.startswith("quartus_"):
        if stem not in ALLOWED_TOOLS:raise Refusal("Unsupported Quartus tool")
        if path not in {canonical("D:\\q17\\quartus\\bin\\"+stem+".exe"),canonical("D:\\q17\\quartus\\bin64\\"+stem+".exe")}:raise Refusal("Quartus executable is not the fixed absolute tool path")
        if any(a in low for a in {"--flow","-t","--script","--eval"}):raise Refusal("Unsupported delegated Quartus operation")
        return "queue"
    raise Refusal("Unknown executable delegate containing Quartus is unsupported")

def is_check_only(command: str, shell: str) -> bool:
    # Classify the actual literal executable, never tool names inside code/comments.
    # Ambiguous compound forms must be expressed as a visible supported command.
    try:
        exe,args=unwrap(words(command,shell),shell)
        stem=ntpath.splitext(ntpath.basename(canonical(exe)))[0]
        if stem not in CHECK_TOOLS:return False
        if reviewed_sta_collector(exe,args):return True
        return not any(a.lower()==flag or a.lower().startswith(flag+'=')
                       for a in args for flag in CHECK_REFUSED_ARGS)
    except (Refusal,ValueError,IndexError):return False


def adapt_shell(command: str,shell: str,cwd: str) -> tuple[str|None,str|None]:
    # A literal reader is inert even when its quoted pattern names a process kill.
    if readonly_shell_evidence(command,shell):return None,None
    # Ambiguous or executable reader forms retain the original refusal.
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
    suspicious=bool(QT_TOKEN.search(command) or re.search(r"(?i)quartus-(?:safe|progress|fast)|quartus_(?:flow|worker)",command))
    if not suspicious:return None,None
    if is_check_only(command,shell):return None,None
    try:
        token=words(command,shell)
        if readonly_shell_evidence(command,shell):return None,None
        exe,args=unwrap(token,shell)
        if ntpath.basename(exe).lower() in {"python","python.exe","python3","python3.exe"}:
            if readonly_python(args):return None,None
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

def authorized_check_command(command: str, shell: str) -> bool:
    """Standing authorization for literal native checks and the reviewed partial CLI."""
    try:
        exe,args=unwrap(words(command,shell),shell)
        path=canonical(exe)
        stem=ntpath.splitext(ntpath.basename(path))[0]
        if stem in CHECK_TOOLS:
            if reviewed_sta_collector(exe,args):return True
            allowed={canonical("D:/q17/quartus/"+folder+"/"+stem+".exe") for folder in {"bin","bin64"}}
            return path in allowed and not any(a.lower()==flag or a.lower().startswith(flag+'=')
                        for a in args for flag in CHECK_REFUSED_ARGS)
        if path==canonical(FAST_FRONTEND):
            validate_fast(args)
            if '--allow-rbf' in args:return False
            return args[0] in {'quick-check','synth-only','turbo','plan'} or (
                args[0] in {'build','benchmark'} and '--checks-only' in args and
                not ('--mode' in args and args[args.index('--mode')+1]=='release'))
        return False
    except (Refusal,ValueError,IndexError):return False


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
        # Capsule run is a known command carrier. Exempt only the same finite
        # read grammar; never convert, forward, approve or launch Quartus here.
        if name=="mcp__capsule__capsule" and inp.get("action")=="run":
            packet=inp.get("payload")
            if isinstance(packet,dict) and packet.get("args",[])==[]:
                literal=packet.get("command")
                if isinstance(literal,str) and readonly_shell_evidence(literal,default_shell):return {}
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
    if replacement is None:
        if authorized_check_command(command,shell):
            return {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"User-authorized analysis/synthesis/fit/STA check: direct, unqueued; no RBF assembly."}}
        return {}
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
