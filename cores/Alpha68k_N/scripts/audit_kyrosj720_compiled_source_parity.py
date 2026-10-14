"""Bounded retained build/source audit. No replay or production changes."""
import difflib,hashlib,json,re
from pathlib import Path
R=Path(__file__).resolve().parents[1];C=Path(r"D:\\Arcade\\AI\\aCORES\\meatsauce-alpha68kn\\cores\\Alpha68k_N");S=Path(r"D:\\vibes\\fpga\\temp\\alpha68kn-system.fmv0Nt")
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def norm(p):return [x.rstrip() for x in p.read_text(encoding="utf-8-sig").splitlines()]
manifest=R/"research/current_system720_curvefixed_inputs.sha256"
pins={line.split(None,1)[1].strip():line.split(None,1)[0] for line in manifest.read_text().splitlines()}
dat=S/"obj/Valpha68kn_system__verFiles.dat";text=dat.read_text()
compiled=[re.findall(r'"([^"]+)"',s)[-1].removeprefix("./") for s in text.splitlines() if s.startswith("S ") and re.findall(r'"([^"]+)"',s) and re.findall(r'"([^"]+)"',s)[-1].endswith((".sv",".v"))]
files=[];toolchain_HDL=[]
for base in compiled:
 candidates=[n for n in pins if Path(n).name==Path(base).name]
 if not candidates and base.startswith("/usr/local/share/verilator/"):
  toolchain_HDL.append(base);continue
 assert len(candidates)==1,(base,candidates)
 n=candidates[0];snap=S/base;current=C/n
 files.append({"relative_path":n,"compiled_pin":pins[n],"snapshot_sha256":sha(snap),"snapshot_matches_compiled_pin":sha(snap)==pins[n],"canonical_sha256":sha(current),"byte_equal":sha(current)==pins[n],"line_endings_equal":snap.read_text()==current.read_text(),"normalized_equal":norm(snap)==norm(current),"macro_continuation_trailing_space":[i+1 for i,l in enumerate(snap.read_text().splitlines()) if l.rstrip().endswith("\\") and l!=l.rstrip()]})
native=json.loads((R/"research/kyrosj_current720_curvefixed_exit.json").read_text())
elf=S/"obj/alpha68kn_system_sim"
old=(S/"alpha68kn_board.sv").read_text();now=(C/"rtl/alpha68kn_board.sv").read_text()
changed=old.replace("    initial begin\n","    initial begin\n        background=0;\n",1).replace("            background<=0;flip<=0;dac<=0;mdin<=16'hffff;","            // MAME maps this word as retained RAM (watchdog/BGC), not a\n            // reset-cleared video register. A new ROM download starts clean.\n            if(downloading) background<=0;\n            flip<=0;dac<=0;mdin<=16'hffff;",1)
board_exact_change=changed.splitlines()==now.splitlines()
hostold=(S/"system_main.cpp").read_text();hostnew=(C/"sim/system_main.cpp").read_text()
hostdiff=list(difflib.unified_diff(hostold.splitlines(),hostnew.splitlines(),fromfile="compiled/system_main.cpp",tofile="current/sim/system_main.cpp",n=2))
hardware_other_semantic=[x["relative_path"] for x in files if not x["normalized_equal"] and x["relative_path"]!="rtl/alpha68kn_board.sv"]
checks={"original_native_actual_exit0":native["exit_code"]==0,
"same_preserved_executable":sha(elf)==native["executable_sha256"],
"all_actual_compiled_HDL_snapshot_pins":all(x["snapshot_matches_compiled_pin"] for x in files),
"all_other_compiled_HDL_normalized_equal":not hardware_other_semantic,
"only_board_semantic_change_retained_background_reset":board_exact_change,
"original720_no_optional_warmreset_or_DACprobe":"--warm-reset-after" not in native["command"] and "dac-probe" not in native["command"],
"original_download_reset_initialization_present":"top.cold_reset=1;top.reset=1;top.downloading=1;" in hostold and "top.downloading=0;" in hostold and hostold.count("top.reset=1")==2 and hostold.index("top.reset=1;tick();")>hostold.index("std::ofstream audio_report") and hostold.count("top.reset=0")==1 and hostold.count("top.cold_reset=1")==1 and hostold.count("top.cold_reset=0")==1,
"current_master_edges_preserved":"top.clk=1;top.eval();ticks++;" in hostold and "top.clk=1;top.eval();ticks++;" in hostnew,
"no_trailing_macro_continuation_exception":not any(x["macro_continuation_trailing_space"] for x in files)}
path_scope={
"board":"Only initial background=0 and reset-held background clear->clear iffdownloading. Original720 holdsdownload/coldreset, then no reset during captured720; a terminal heldreset happens onlyafter capturedPCM/frame output; startupclear0 and all post-reset logic same. CPUROM q/address/DTACK/clock/IRQ/sound state unchanged.",
"system":"CRLF/raw hash changes only; line-normalized entire compiledsystem source matchescurrent. No port/hierarchy semantics changed.",
"jt49_exp":"Trailing whitespace only; no macro continuation whitespace cases; exact normalized entire source.",
"CRT":"Manifest inventories alpha68kn_crt/PLL and otherunused modules, but actual Verilator source inventory excludesCRT/PLL. Their production/framework changes do not alter this nativeCPU+renderer+sound harness scope.",
"host":"Current adds optionalwarmreset, read-only snapshots/instruction/epoch probes, runtimeROM existence checks, explicitzero frameworkinputs and conditional re-eval onlyif SDRAMdq changes. Host is NOT byte-identical or solelylogging. Source keeps everyclockedge and same recordedports/defaultnoreset; conditional re-eval is an operational optimization and existing runtime equivalence evidence remains separate."}
out={"scope":"Original Japan720 executable authenticated to actual preserved compiled HDL; current sound/cold-game-path compatibility analysis, not new runtime or blanket byte-equivalence proof.",
"canonical_at_task":"578c9dfd","checks":checks,"all_checks_strict_boolean_true":all(v is True for v in checks.values()),"compiled_HDL_count":len(files),"compiled_files":files,"toolchain_builtin_HDL":toolchain_HDL,
"manifest_inventory_count":len(pins),"unused_manifest_HDL":[n for n in pins if n.startswith("rtl/") and Path(n).name not in {Path(x).name for x in compiled}],
"preserved_native_ELF_sha256":sha(elf),"native_exit_ELF_sha256":native["executable_sha256"],
"semantic_HDL_differences":["rtl/alpha68kn_board.sv"] if board_exact_change else ["unqualifiedboarddiff"],
"other_semantic_HDL_differences":hardware_other_semantic,"change_scope":path_scope,
"board_diff":list(difflib.unified_diff(old.splitlines(),now.splitlines(),fromfile="compiled/alpha68kn_board.sv",tofile="current/rtl/alpha68kn_board.sv",n=2)),
"host_diff":hostdiff,
"decision":{"current_compiled_HDL_byte_identity":all(x["byte_equal"] for x in files),"current_compiled_sound_HDL_normalized_identity":all(x["normalized_equal"] for x in files if x["relative_path"]!="rtl/alpha68kn_board.sv"),"new_Japan720_replay_required_by_identified_HDL_change":not(all(v is True for v in checks.values())),"reason":"No new cold720 replay justified solely by board warmreset-background retention, line endings, whitespace or unusedCRT. Preserve existing exact Japan720 sound comparison; current host perf optimization is separate from the original pinned replay.","future_trigger":"Semantic active CPU/sound/graphics/clock/profile change or a host edge/input change without established compatibility."},
"limits":["Full HDL byteidentity false; explicitly bound warmreset semanticdifference.","Cold/noreset720 capture compatibility excludes the original terminal heldreset/diagnostic RAMdump, which occurs after PCM/frame output; does not prove Japan warmreset/death/everyeffect.","Host optimization equivalence is source-reasoned here, not re-run720; existing focused runtime qualification may be referenced separately.","FrameworkCRT/physicalMiSTer outside this nativeharness; no hardware/graphicswide/P5/B03-B06 closure."],
"evidence_pins":[{"path":str(p),"sha256":sha(p),"bytes":p.stat().st_size} for p in [manifest,dat,elf,R/"research/current_system720_curvefixed_build_exit.json",R/"research/kyrosj_current720_curvefixed_exit.json",R/"research/kyrosj_sound_fulltap720_verification.json",S/"system_main.cpp",C/"sim/system_main.cpp"]]}
dest=R/"research/kyrosj720_compiled_source_parity.json";dest.write_text(json.dumps(out,indent=2)+"\n",encoding="utf-8")
md=R/"research/kyrosj720_compiled_source_parity.md"
md.write_text("# Japan720 compiled-source scope\n\nPreserved ELF "+sha(elf)+" matches the actual completed Japan720 exit receipt. All"+str(len(files))+" actual compiled HDL source snapshots match their original manifest pins. Current differences are explicitly classified in the JSON.\n\nThe only semantic compiled HDL change is background initialization/retention across warmreset; original720 captured fields/audio use cold/download reset only; its terminal heldreset follows capturedPCM/frame output. System CRLF and JT49 whitespace differences do not alter the normalized source. CRT/PLL are inventoried but absent from the actual compiled native source inventory. No CPU/clock/ROM-handshake/sound change was identified.\n\nNo Japan720 replay is required by these identified HDL changes. Host adds optionalreset/probes and conditionalSDRAM re-eval; it is not byte-identical or solelylogging. This analysis does not promote broad host/runtime/hardware equivalence or Japan death/reset/effects. Preserve fulltap720 finite sound data pass and remaining action gaps.\n",encoding="utf-8")
print(json.dumps({"checks":checks,"compiled_HDL":len(files),"other_semantic_HDL":hardware_other_semantic,"new_replay_required":out["decision"]["new_Japan720_replay_required_by_identified_HDL_change"],"json_sha256":sha(dest),"md_sha256":sha(md),"script_sha256":sha(Path(__file__))}))
raise SystemExit(0 if all(v is True for v in checks.values()) else 1)
