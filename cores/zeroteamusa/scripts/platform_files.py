"""Select production target modules, retaining the fixed MiSTer emu interface."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
wrapper=root/'ZeroTeam.sv'
text=wrapper.read_text()
if '///////// Unused ports' in text:
    header=text[:text.index('///////// Unused ports')]
    wrapper.write_text(header+'`include "rtl/ZeroTeam_platform.svh"\n\nendmodule\n')
sources=[
 'rtl/common/savestate.sv','rtl/common/savestate_ram.sv',
 'rtl/ucore/v30u_ss_pkg.sv','rtl/ucore/v30_core.sv','rtl/ucore/v30u_biu.sv',
 'rtl/ucore/v30u_ucrom.sv','rtl/ucore/v30u_eu.sv','rtl/ucore/v30_bus_demux.sv',
 'rtl/Raiden2/v30/cpu_v30_bridge.sv','rtl/Raiden2/raiden2_addr_main.sv',
 'rtl/Raiden2/raiden2_ce_gen.sv','rtl/Raiden2/raiden2_sdram_bridge_cpu.sv',
 'rtl/Raiden2/raiden2_sprite_mainbus.sv','rtl/Raiden2/Raiden2_seibu_crtc.sv',
 'rtl/Raiden2/Raiden2_cop3.sv','rtl/Raiden2/raiden2_rom_cache.sv','rtl/Raiden2/Raiden2_main_top.sv',
 'rtl/Raiden2/Raiden2_video_timing.sv','rtl/Raiden2/Raiden2_text_renderer.sv',
 'rtl/Raiden2/Raiden2_tile_layer.sv','rtl/Raiden2/Raiden2_sprite_renderer.sv',
 'rtl/Raiden2/spram_dp.sv','rtl/Raiden2/tile_rom_arbiter.sv','rtl/Raiden2/raiden2_mixer.sv',
 'rtl/Raiden2/crypt/zeroteam_sprite_decrypt.sv','rtl/Raiden2/crt_adjust.sv',
 'rtl/ZeroTeam_video.sv','rtl/ZeroTeam_inputs.sv','rtl/ZeroTeam_download.sv',
 'rtl/ZeroTeam_rom_bridge.sv','rtl/ZeroTeam_rotation.sv','rtl/hiscore.v','rtl/sdram.sv',
 'rtl/pll.v','ZeroTeam.sv']
lines=['# Target source graph: shared with native simulation. sys/ is unchanged.',
 'set_global_assignment -name SDC_FILE ZeroTeam.sdc',
 'set_global_assignment -name VERILOG_MACRO "MISTER_FB=1"',
 'set_global_assignment -name QIP_FILE rtl/pll.qip',
 'set_global_assignment -name QIP_FILE rtl/ZeroTeam_audio.qip',
 'set_global_assignment -name SEARCH_PATH rtl/ucore']
for path in sources:
    assert (root/path).is_file(),path
    kind='VERILOG_FILE' if path.endswith('.v') else 'SYSTEMVERILOG_FILE'
    lines.append(f'set_global_assignment -name {kind} {path}')
for macro in ['SYNTHESIS','CE_HALF_PLUS2','READY_FIXED_HIGH','CE_STALL_ON']:
    lines.append(f'set_global_assignment -name VERILOG_MACRO "{macro}=1"')
(root / 'files.qip').write_text('\n'.join(lines)+'\n')
print('Selected target video/cipher, loader, highscore and rotation source graph.')
