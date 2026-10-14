#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Bounded source-clock/PIO/real-private-PROM qualifier, explicit Ubuntu WSL."""
from pathlib import Path
from datetime import datetime,timezone
import hashlib,json,subprocess,shutil,zlib
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 root=Path(__file__).resolve().parents[1]
 check=root/'_checks/agent-color-clock-review-20261010/native'
 snapshot=check/'source';snapshot.mkdir(parents=True,exist_ok=True)
 blob=root/'roms/sheriff.bin'
 expected_blob='082f0343064de9c9fc0c926aeae7d3414b7d890d3820c10899a37c64b80de997'
 assert sha(blob)==expected_blob,'private parent blob identity'
 prom=blob.read_bytes()[0x4400:0x4800]
 assert len(prom)==1024 and hashlib.sha1(prom).hexdigest()=='197eeb008c140558e7c1ab2b2bd0f6a27096877c'
 assert zlib.crc32(prom)==0x820f8cdd
 files=['rtl/n8080_horizontal_counter.sv','rtl/n8080_vertical_counter.sv',
  'rtl/n8080_video_register.sv','rtl/n8080_video_path.sv',
  'rtl/n8080_color_latch.sv','rtl/n8080_color_path.sv',
  'sim/color_clock_qualification.sv','sim/color_clock_qualification.cpp']
 original_hashes={f:sha(root/f) for f in files}
 for f in files:shutil.copyfile(root/f,snapshot/Path(f).name)
 snapshot_hashes={p.relative_to(root).as_posix():sha(p) for p in snapshot.iterdir() if p.is_file()}
 (check/'source-manifest.json').write_text(json.dumps({'original_sha256':original_hashes,'snapshot_sha256':snapshot_hashes},indent=2)+'\n',newline='')
 linux='/mnt/'+root.drive[0].lower()+root.as_posix()[2:]
 linux_check=linux+'/'+check.relative_to(root).as_posix();build=linux_check+'/build'
 base=['wsl.exe','-d','Ubuntu','--cd',str(root),'--exec']
 sv=[linux_check+'/source/'+Path(f).name for f in files if f.endswith('.sv')]
 cpp=linux_check+'/source/color_clock_qualification.cpp'
 commands=[base+['verilator','--cc','--exe','--build','--top-module','color_clock_qualification','--Mdir',build,'--threads','1','-j','2','-Wno-fatal',*sv,cpp],base+[build+'/Vcolor_clock_qualification',linux+'/roms/sheriff.bin']]
 receipts=[]
 for stage,cmd in zip(['build','native'],commands):
  started=datetime.now(timezone.utc).isoformat();v=subprocess.run(cmd,cwd=root,capture_output=True)
  (check/(stage+'-stdout.log')).write_bytes(v.stdout);(check/(stage+'-stderr.log')).write_bytes(v.stderr)
  receipt={'stage':stage,'argv':cmd,'started_utc':started,'finished_utc':datetime.now(timezone.utc).isoformat(),'exit_code':v.returncode}
  (check/(stage+'-receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n',newline='');receipts.append(receipt)
  print(stage+' exit='+str(v.returncode),flush=True)
  if v.returncode:print(v.stderr.decode(errors='replace')[-3000:]);raise SystemExit(v.returncode)
 result=v.stdout.decode().strip()
 assert result.startswith('PASS source_clock_captures=800 holds=12000 static_addresses=12800 spans=40 flip_holds=15 serializer_on='),result
 assert sha(blob)==expected_blob
 for f,digest in snapshot_hashes.items():assert sha(root/f)==digest,f
 source_reports=['docs/evidence/sheriff_pio_counter_bridge.json','docs/evidence/sheriff_prom_dump_pin_bridge.json','docs/evidence/sheriff_color_control_trace.json']
 artifacts=[check/'build/Vcolor_clock_qualification',check/'source-manifest.json',*check.glob('*-receipt.json'),*check.glob('*.log')]
 report={'scope':'Corrected source HREAD_n clock and PIO mapping with verified private parent PROM; digital pre-edge ordering only',
  'actual_build_exit':receipts[0]['exit_code'],'actual_native_exit':receipts[1]['exit_code'],'result':result,
  'clock':'CLK9=!4I_QD; ce_capture=ce_counter && phase_4i==15','capture_period_counter_clocks':16,
  'ordering':'Each edge samples settled pre-edge PROM pins; the common clock updates phase/counters/serializer/latch together. Gate and PROM propagation are not emulated.',
  'original_source_sha256':original_hashes,'snapshot_sha256':snapshot_hashes,'producer_sha256':sha(Path(__file__)),
  'source_report_sha256':{f:sha(root/f) for f in source_reports},
  'private_asset':{'path':'roms/sheriff.bin','sha256':expected_blob,'PROM_offset':0x4400,'PROM_size':1024,'PROM_crc32':'820f8cdd','PROM_sha1':hashlib.sha1(prom).hexdigest(),'bytes_copied_to_artifacts':False},
  'receipts':receipts,'artifact_sha256':{p.relative_to(root).as_posix():sha(p) for p in artifacts},
  'limits':['Exact Sheriff PCB revision','Physical pre/post-edge data capture and setup/hold','No MAME raster/gameplay equivalence claimed','Diagnostic reset and fixed RAM data stimulus are not physical RAM arbitration qualification'],
  'production_integrated':False,'physical_timing_qualified':False,'strict_graphics_gate_pass':False,'quartus_executed':False,'rbf_built':False}
 target=root/'docs/evidence/sheriff_color_clock_native.json'
 target.write_text(json.dumps(report,indent=2)+'\n',newline='')
 review=root/'docs/evidence/sheriff_color_clock_review.json';d=json.loads(review.read_text())
 d['verification']['new_native_qualifier']={'path':target.relative_to(root).as_posix(),'actual_build_exit':0,'actual_native_exit':0,'result':result,'physical_ordering_qualified':False}
 review.write_text(json.dumps(d,indent=2)+'\n',newline='')
 doc=root/'docs/COLOR_CLOCK_REVIEW.md';text=doc.read_text();marker='\nFocused corrected-clock native result:'
 text=text.split(marker)[0]
 doc.write_text(text+marker+' build0/native0. The source-snapshot producer checked800 captures,12000 holds,12800 static PROM addresses,40 bounded320-clock spans and15 flip-before-capture holds using the verified private parent PROM and existing counters/serializer/control. It models settled pre-edge pin sampling; this is not physical propagation or MAME gameplay qualification. Native ELF, producer, source manifests and actual command receipts are retained under `_checks/agent-color-clock-review-20261010/native/`; complete result/asset hashes are in `docs/evidence/sheriff_color_clock_native.json`.\n',newline='')
 print(result,flush=True)
if __name__=='__main__':main()
