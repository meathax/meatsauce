#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Record connected horizontal reload/blanking and retained negative scope."""
import hashlib
import json
from pathlib import Path


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    native_path=Path('docs/evidence/sheriff_horizontal_video_path.json')
    native=json.loads(native_path.read_text())
    assert native['build_exit_code']==native['test_exit_code']==0
    for path,digest in native['evidence_sha256'].items():
        assert sha(path)==digest,path
    views=[dict(page=34,box=[0,250,1750,1190],path='_checks/manuals/bandido-horizontal-reload-top.png'),
           dict(page=34,box=[50,720,690,1200],path='_checks/manuals/bandido-horizontal-load-carry-pins.png'),
           dict(page=33,box=[4320,720,5088,1300],path='_checks/manuals/bandido-horizontal-reload-parallel-ab.png'),
           dict(page=34,box=[1350,380,2700,1320],path='_checks/manuals/bandido-hb-output-connected.png'),
           dict(page=34,box=[2120,1240,2450,1890],path='_checks/manuals/bandido-blank-load-input-joins.png',viewport_scale=2),
           dict(page=33,box=[3990,1050,4670,2240],path='_checks/manuals/bandido-4i-output-clock-pin-trace.png')]
    failed=Path('_checks/horizontal-video-path-20261010/test-receipt.json')
    old=json.loads(failed.read_text());assert old['exit_code']==1 and 'replacement before eight bits' in old['stderr']
    failed_binding=Path('_checks/horizontal-video-path-20261010/failed-source-v1/binding.json')
    for source,record in json.loads(failed_binding.read_text()).items():
        assert sha(record['saved'])==record['sha256'],source
    result=dict(scope='Related-Bandido horizontal reload/blanking connectivity and joined native conditional model; not complete physical raster.',
                connections={'4J_clock':'Common3B Q10 clock, same as4I/5I/5J/1L.',
                             '4J_EN_T10':'4I RCO15; count carries from the free-running low nibble.',
                             '4J_data':'A3/B4 grounded; C5/D6 share4G Qbar6.',
                             '4J_LOAD_n9':'4J RCO15 through4H inverter13->12,11->10,9->8; C5 1000pF on middle output.',
                             '4G_H':'D2=Qbar6; CLK3 is the same inverted RCO signal; PRE_n4/CLR_n1 high. Positive inverted-RCO edge follows the counter reload.',
                             'HB':'4G Q5->TP4; Qbar6 reaches5T pin1, active high.',
                             'VB':'4G Q9->TP5; Qbar8 reaches5T pin2, active high.',
                             'QC_fanout':'4I QC12 feeds both2L inverter inputs3 and5; output6 is HREAD_n. QD11 crosses this branch and continues separately; the previous QC phase model remains valid.'},
                manufacturer_counter=dict(url='https://www.ti.com/product/SN74LS161A',
                                          facts='Low LOAD overrides enable inputs; RCO includes enableT and all counter bits. Manufacturer warns of possible RCO counting spikes.',
                                          limit='Drawing labels161; exact fitted family/vendor and electrical characteristics remain unqualified.'),
                zero_delay_order='At pre255,4J captures old Qbar as parallel preset0/12; RCO then falls and4G toggles active state.',
                measured_native_period_pixels=320,active_pixels_per_period=256,blank_pixels_per_period=64,
                measured_first_byte_after_active_counter_clocks=8,
                failed_first_case=dict(exit_code=1,cause='Bench completion check demanded index8 after eight output bits0..7; corrected to permit completed index7.'),
                successful_second_case=dict(build_exit_code=0,test_exit_code=0,generated_RTL_model_reused=True,
                                            receipt='_checks/horizontal-video-path-20261010/attempt-v2/test-receipt.json'),
                viewports=views,
                evidence_sha256={p.as_posix():sha(p) for p in [Path(__file__),native_path,failed,failed_binding,
                   Path('rtl/n8080_horizontal_counter.sv'),Path('rtl/n8080_video_path.sv'),
                   Path('docs/evidence/sheriff_video_control_network.json'),
                   Path('_checks/manuals/bandido-1980.pdf'),*[Path(v['path']) for v in views]]},
                limitations=['Counter reset is an artificial reproducible origin; exact Sheriff net/revision and physical reset not qualified.',
                             'Pre-edge/post-propagation digital ordering does not characterize C5/inverter/4G setup/hold or RCO glitches.',
                             'Eight-clock byte pipeline is derived and observed, not a fitted MAME offset; analog visible window and PROM/RGB gate timing remain open.',
                             'Vertical counter/enable and actual flip-latch mapping need connected derivation before production integration.',
                             'Original field2760 graphics failure remains; no reference shift, tolerance, complete timing/resource or release pass.'],
                integrated_in_board=False,physical_memory_timing_qualified=False,strict_graphics_gate_pass=False,
                quartus_executed=False,rbf_built=False)
    output=Path('docs/evidence/sheriff_horizontal_network.json')
    output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(dict(report=output.as_posix(),polarity_corrected=True,period_pixels=320,
                          actual_build_exit=0,actual_test_exit=0,integrated_in_board=False)))


if __name__=='__main__':
    main()
