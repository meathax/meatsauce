"""Emit the real integrated board's transitive source list (no platform shells)."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sources = [
    'rtl/common/savestate.sv', 'rtl/common/savestate_ram.sv',
    'rtl/ucore/v30u_ss_pkg.sv', 'rtl/ucore/v30_core.sv',
    'rtl/ucore/v30u_biu.sv', 'rtl/ucore/v30u_ucrom.sv',
    'rtl/ucore/v30u_eu.sv', 'rtl/ucore/v30_bus_demux.sv',
    'rtl/Raiden2/v30/cpu_v30_bridge.sv', 'rtl/Raiden2/raiden2_addr_main.sv',
    'rtl/Raiden2/raiden2_ce_gen.sv', 'rtl/Raiden2/raiden2_sdram_bridge_cpu.sv',
    'rtl/Raiden2/raiden2_sprite_mainbus.sv', 'rtl/Raiden2/Raiden2_seibu_crtc.sv',
    'rtl/Raiden2/Raiden2_cop3.sv', 'rtl/Raiden2/raiden2_rom_cache.sv',
    'rtl/Raiden2/Raiden2_main_top.sv',
    'sim/zero_board_top.sv',
]
for source in sources:
    assert (root / source).is_file(), source
(root / 'sim/board_sources.f').write_text('\n'.join(sources) + '\n')
print(f'{len(sources)} board source files')
