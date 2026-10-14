"""Publish immutable fitted resource proof, separately from STA diagnostics."""
from pathlib import Path
import hashlib,json
base=Path(__file__).resolve().parent
dest=base/'case2_fit_sta'
work=base/'case2_full_map'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
fit=json.loads((dest/'native_fit_result.json').read_text())
meta=json.loads((work/'prepared.json').read_text())
assert fit['fit_actual_exit']==0 and fit['fit_tool_chunk']=='f19aa0'
assert sha(work/'output_files/Alpha68k_N.fit.rpt')==fit['report_sha256']
numbers={'alm_pct':(17377/41910*100,80),'labs_pct':(2833/4191*100,90),'peak_interconnect_pct':(55.8,85),'average_interconnect_pct':(22.9,60),'m10k_pct':(331/553*100,90),'block_memory_bits_pct':(2439512/5662720*100,85),'dsp_pct':(41/112*100,90)}
assert any('55.8%' in row and 'Peak' in row for row in fit['resource_rows'])
assert any('22.9%' in row and 'Average' in row for row in fit['resource_rows'])
assert all(value<limit for value,limit in numbers.values())
resource={'qualification':'Complete fitted private sys_top candidate resource pass only; excludes later P6/SSG/all-game join and release qualification.','source_board_sha256':meta['candidate_board_sha256'],'qsf_sha256':meta['qsf_sha256'],'fit_actual_exit':0,'fit_tool_chunk':'f19aa0','strict_comparison':'<','limits':{name:{'measured_pct':value,'hard_limit_pct':limit,'pass':value<limit} for name,(value,limit) in numbers.items()},'peak_source':'max(H40.3%,V55.8%)','average_source':'reported total22.9%; H23.4%, V21.5% also below60%.','counts':{'ALMs':[17377,41910],'occupied_LABs':[2833,4191],'M10K':[331,553],'block_bits':[2439512,5662720],'DSP':[41,112]},'resource_pass':True,'timing_pass':False,'warning_review':'No Critical Warning rows in fit report;1274 warnings retained. Largehold-routing demand requires actualSTA qualification.','source_pins_161_verified':all(sha(work/'source'/n)==p for n,p in meta['canonical_source_pins'].items()),'RBF':False}
(dest/'fitted_resource_gates.json').write_text(json.dumps(resource,indent=2)+'\n')
constraint_names=['Alpha68k_N.sdc','sys/sys_top.sdc']
constraints=[{'path':str(work/'source'/name),'sha256':sha(work/'source'/name)} for name in constraint_names]
clock_rows=[('emu|pll|pll|general[0].gpll~FRACTIONAL_PLL|vcoph[0]',2.083),('emu|pll|pll|general[0].gpll~PLL_OUTPUT_COUNTER|divclk',20.833),('emu|pll|pll|general[1].gpll~PLL_OUTPUT_COUNTER|divclk',20.833),('FPGA_CLK1_50',20.000),('FPGA_CLK2_50',20.000),('FPGA_CLK3_50',20.000),('hdmi_sck',100.000),('pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~FRACTIONAL_PLL|vcoph[0]',2.393),('pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk',40.682),('pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk',6.732),('pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|fpll_0|fpll|vcoph[0]',2.244),('spi_sck',10.000),('sysmem|fpga_interfaces|clocks_resets|h2f_user0_clk',10.000)]
inventory={'source':'Native fitter console clock inventory chunk7bf663; roundedperiods preserved, game/framework clocks enumerated separately.','clock_count':13,'clock_rows':[{'name':name,'period_ns':period} for name,period in clock_rows],'game_clock_target_hz':48000000,'constraints':constraints,'clock_and_crossing_gate':'OPEN; inventory alone does not qualify constraints, relationships, crossings or reset paths.','constraints_unchanged':True}
(dest/'fit_clock_inventory.json').write_text(json.dumps(inventory,indent=2)+'\n')
names=['stage_fit_launch.py','summarize_native_fit.py','observe_owned_fit.py','recover_original_reader_receipt.py','publish_native_fit.py','case2_fit_sta/fit_launch.json','case2_fit_sta/native_fit_result.json','case2_fit_sta/fitted_resource_gates.json','case2_fit_sta/fit_clock_inventory.json','case2_fit_sta/pre_fit_owned_jobs_observation.json','case2_fit_sta/reader_receipt_recovery.json','case2_fit_sta/reader_receipt_exact_recovery.json']
manifest={'files':[{'path':name,'bytes':(base/name).stat().st_size,'sha256':sha(base/name)} for name in names],'large_recovery_only':[{'path':str(work/'output_files/Alpha68k_N.fit.rpt'),'sha256':fit['report_sha256']},{'path':str(work/'output_files/Alpha68k_N.fit.summary'),'sha256':fit['summary_sha256']}],'source_manifest':{'path':str(base/'case2_import_manifest.json'),'sha256':sha(base/'case2_import_manifest.json')},'scope':'Fullsys_top resourcepass, no timing releasepass','fit_exit':0,'fit_tool_chunk':'f19aa0','STA_diagnostics_included':False,'RBF':False}
target=base/'fit_import_manifest.json'
target.write_text(json.dumps(manifest,indent=2)+'\n')
print(json.dumps({'manifest':str(target),'sha256':sha(target),'files':len(names),'resource_gate_sha256':sha(dest/'fitted_resource_gates.json'),'resources_pass':True,'timing_pass':False}))
