#!/usr/bin/env python3
"""Fit an isolated physical SDRAM forwarding route at unchanged clock frequency.

A low-fanout PLL counter feeds the DDR clock pin. Real backend/controller and
actual board pin assignments; not full-core timing or game acceptance. No ASM.
"""
import argparse,hashlib,json,re,shutil,subprocess,time
from pathlib import Path

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
TOP=r"""module cs_forward_probe(
 input FPGA_CLK2_50, input reset, input [73:0] command,
 output reg [34:0] response, inout [15:0] SDRAM_DQ,
 output [12:0] SDRAM_A, output [1:0] SDRAM_BA,
 output SDRAM_CLK, SDRAM_CKE, SDRAM_nCS, SDRAM_nRAS, SDRAM_nCAS, SDRAM_nWE,
 output SDRAM_DQML,SDRAM_DQMH);
wire clk_sys,locked;
(* keep = "true" *) wire clk_forward;
pll pll(.refclk(FPGA_CLK2_50),.rst(1'b0),.outclk_0(clk_sys),.outclk_1(clk_forward),.locked(locked));
reg [73:0] cmd=0;reg reset_q=1;
wire ready,valid,error,initialized;wire [31:0] data;wire [15:0] dq_out;wire dq_oe;wire [1:0] dqm;
always @(posedge clk_sys) begin cmd<=command;reset_q<=reset;response<={initialized,ready,valid,data};end
assign SDRAM_DQ=dq_oe?dq_out:16'hzzzz;
assign {SDRAM_DQMH,SDRAM_DQML}=dqm;
cs_sdram_backend #(.REGISTERED_IO(1),.PHASED_CAPTURE(0)) ram(
 .clk(clk_sys),.reset(reset_q||!locked),.sdram_capture_clk(clk_sys),.initialized(initialized),
 .req_valid(cmd[73]),.req_ready(ready),.req_target(cmd[72:69]),.req_offset(cmd[68:37]),
 .req_data(cmd[36:5]),.req_strobe(cmd[4:1]),.req_write(cmd[0]),.rsp_valid(valid),.rsp_data(data),.rsp_error(error),
 .sdram_data_in(SDRAM_DQ),.sdram_clk(),.sdram_cke(SDRAM_CKE),.sdram_cs_n(SDRAM_nCS),
 .sdram_ras_n(SDRAM_nRAS),.sdram_cas_n(SDRAM_nCAS),.sdram_we_n(SDRAM_nWE),
 .sdram_dqm(dqm),.sdram_ba(SDRAM_BA),.sdram_address(SDRAM_A),.sdram_data_out(dq_out),.sdram_data_oe(dq_oe));
altddio_out #(.width(1),.power_up_high("OFF"),.oe_reg("UNREGISTERED"),.intended_device_family("Cyclone V")) clock_pin(
 .datain_h(1'b1),.datain_l(1'b0),.outclock(clk_forward),.dataout(SDRAM_CLK),
 .aclr(1'b0),.aset(1'b0),.sclr(1'b0),.sset(1'b0),.outclocken(1'b1),.oe(1'b1));
endmodule
"""
SDC=r"""create_clock -name ref50 -period 20 [get_ports FPGA_CLK2_50]
derive_pll_clocks
set sys [get_pins -compatibility_mode {*pll_inst*general[0]*divclk}]
set forwarded [get_pins -compatibility_mode {*pll_inst*general[1]*divclk}]
foreach_in_collection pin $sys {set master [get_node_info -name $pin]}
create_generated_clock -name cs_sdram_clk -source $forwarded -divide_by 1 [get_ports SDRAM_CLK]
set_input_delay -clock cs_sdram_clk -max 7.5 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock cs_sdram_clk -min 2.7 [get_ports {SDRAM_DQ[*]}]
set sdr_outputs [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_CKE SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE}]
set_output_delay -clock cs_sdram_clk -max 2.0 $sdr_outputs
set_output_delay -clock cs_sdram_clk -min -1.3 $sdr_outputs
set_input_delay -clock $master -max 2.0 [get_ports {command[*] reset}]
set_input_delay -clock $master -min 0.0 [get_ports {command[*] reset}]
set_output_delay -clock $master -max 2.0 [get_ports {response[*]}]
set_output_delay -clock $master -min 0.0 [get_ports {response[*]}]
derive_clock_uncertainty
"""
TCL=r"""package require ::quartus::sta
project_open cs_forward_probe
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir pin_paths
report_clocks -file pin_paths/clocks.rpt
set waves [open pin_paths/waves.txt w]
foreach_in_collection c [get_clocks *] {
 puts $waves "[get_clock_info -name $c]|[get_clock_info -waveform $c]|[get_clock_info -period $c]"
}
close $waves
set i 0
foreach_in_collection op [get_available_operating_conditions] {
 set_operating_conditions $op
 update_timing_netlist
 report_timing -setup -from [get_ports {SDRAM_DQ[*]}] -npaths 1 -detail full_path -file pin_paths/corner${i}_input_setup.rpt
 report_timing -hold -from [get_ports {SDRAM_DQ[*]}] -npaths 1 -detail full_path -file pin_paths/corner${i}_input_hold.rpt
 report_timing -setup -to $sdr_outputs -npaths 1 -detail full_path -file pin_paths/corner${i}_output_setup.rpt
 report_timing -hold -to $sdr_outputs -npaths 1 -detail full_path -file pin_paths/corner${i}_output_hold.rpt
 incr i
}
project_close -dont_export_assignments
"""
def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--global-route',choices=['auto','off'],default='off')
 args=ap.parse_args()
 stage=ROOT/'sim/obj_dir/sdram_forward_probe'/str(time.time_ns());stage.mkdir(parents=True)
 sources=['rtl/pll.v','rtl/pll/pll_0002.v','rtl/memory/cs_sdram_backend.sv','donors/sdram/src_v/sdram_axi_core.v']
 hashes={}
 for name in sources:
  dest=stage/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,dest)
  hashes[name]=hashlib.sha256(dest.read_bytes()).hexdigest()
 p=stage/'rtl/pll/pll_0002.v';s=p.read_text();assert '.phase_shift1("3175 ps")' in s
 p.write_text(s.replace('.phase_shift1("3175 ps")','.phase_shift1("1058 ps")'))
 (stage/'top.sv').write_text(TOP);(stage/'pins.sdc').write_text(SDC);(stage/'probe.tcl').write_text(TCL)
 pin_lines=[s for s in (ROOT/'sys/sys.tcl').read_text().splitlines() if s.startswith('set_') and re.search(r'\b(?:SDRAM_|FPGA_CLK2_50)',s)]
 qsf=['set_global_assignment -name FAMILY "Cyclone V"','set_global_assignment -name DEVICE 5CSEBA6U23I7',
 'set_global_assignment -name TOP_LEVEL_ENTITY cs_forward_probe','set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files',
 'set_global_assignment -name NUM_PARALLEL_PROCESSORS 2','set_global_assignment -name GENERATE_RBF_FILE OFF',
 'set_global_assignment -name SDC_FILE pins.sdc','set_global_assignment -name SYSTEMVERILOG_FILE top.sv',
 'set_instance_assignment -name VIRTUAL_PIN ON -to command[*]','set_instance_assignment -name VIRTUAL_PIN ON -to response[*]',
 'set_instance_assignment -name VIRTUAL_PIN ON -to reset']+pin_lines
 for name in sources:qsf.append('set_global_assignment -name '+('SYSTEMVERILOG_FILE' if name.endswith('.sv') else 'VERILOG_FILE')+' '+name)
 if args.global_route=='off':qsf.append('set_instance_assignment -name GLOBAL_SIGNAL OFF -to clk_forward')
 (stage/'cs_forward_probe.qsf').write_text('\n'.join(qsf)+'\n');(stage/'cs_forward_probe.qpf').write_text('PROJECT_REVISION = "cs_forward_probe"\n')
 result={'scope':'isolated routing experiment; not production or gameplay signoff','stage':str(stage),'global_route':args.global_route,'requested_forward_phase_ps':1058,'clock_frequency_mhz':85.909080,'rbf_built':False,'copied_source_sha256':hashes,'steps':[]}
 result['staged_source_sha256']={str(p.relative_to(stage)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [stage/name for name in sources]+[stage/'top.sv',stage/'pins.sdc',stage/'cs_forward_probe.qsf']}
 print('FORWARD_ROUTE_SNAPSHOT '+str(stage),flush=True)
 for tool,argv in [('quartus_map',['cs_forward_probe']),('quartus_fit',['cs_forward_probe','--write_settings_files=off']),('quartus_sta',['-t',str(stage/'probe.tcl')])]:
  log=stage/(tool+'.log');started=time.monotonic()
  with log.open('w') as output:
   proc=_sq_route_checked(subprocess.Popen, ['D:/q17/quartus/bin64/'+tool+'.exe',*argv],cwd=stage,stdout=output,stderr=subprocess.STDOUT)
   print('QUARTUS_PID '+tool+' '+str(proc.pid),flush=True);code=proc.wait()
  body=log.read_text(errors='replace');errors=[s for s in body.splitlines() if re.match(r'\s*(?:Error|Fatal Error)\b',s)][:8]
  result['steps'].append({'tool':tool,'returncode':code,'seconds':round(time.monotonic()-started,3),'errors':errors,'log':str(log)})
  print(json.dumps(result['steps'][-1]),flush=True)
  if code or errors:break
 result['status']='PROBE_ERROR' if any(x['returncode'] or x['errors'] for x in result['steps']) else 'PROBE_COMPLETE'
 if result['status']=='PROBE_COMPLETE':
  result['paths']=[]
  for p in sorted((stage/'pin_paths').glob('corner*.rpt')):
   match=re.search(r'Path #1: (?:Setup|Hold) slack is (-?\d+(?:\.\d+)?)',p.read_text())
   if not match:raise RuntimeError('missing physical timing path '+str(p))
   result['paths'].append({'report':str(p),'slack_ns':float(match.group(1))})
  result['resources']=(stage/'output_files/cs_forward_probe.fit.summary').read_text()
  fit_report=(stage/'output_files/cs_forward_probe.fit.rpt').read_text(errors='replace')
  ignored=fit_report.split('; Ignored Assignments',1)[1].split('\n\n',1)[0] if '; Ignored Assignments' in fit_report else ''
  result['ignored_global_assignments']=[line.strip() for line in ignored.splitlines() if 'Global Signal' in line]
  result['requested_route_applied']=args.global_route=='auto' or not result['ignored_global_assignments']
  result['clock_waveforms']=(stage/'pin_paths/waves.txt').read_text()
 (stage/'result.json').write_text(json.dumps(result,indent=2)+'\n')
 (ROOT/('docs/sdram_forward_'+args.global_route+'_probe.json')).write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps({k:result[k] for k in ('status','stage','global_route')}),flush=True)
 return int(result['status']=='PROBE_ERROR')
if __name__=='__main__':raise SystemExit(main())
