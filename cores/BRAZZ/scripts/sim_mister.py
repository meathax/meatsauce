"""Focused MiSTer frontend tests using the project's native Verilator runner."""
import sim

sim.TARGETS.update({
    "mister_scale": {"top": "cs_video_freak", "files": ['rtl/video/cs_video_freak.sv', 'sys/math.sv'], "main": "sim/mister/scale.cpp", "parameters": []},
    "mister_controls": {"top": "cs_mister_controls", "files": ["rtl/board/cs_mister_controls.sv"], "main": "sim/mister/controls.cpp", "parameters": []},
    "mister_nvram": {"top": "cs_nvram", "files": ["rtl/board/cs_nvram.sv"], "main": "sim/mister/nvram.cpp", "parameters": []},
    "mister_video": {"top": "cs_diagnostic_video", "files": ["rtl/video/cs_diagnostic_video.sv"], "main": "sim/mister/video.cpp", "parameters": []},
    "mister_audio_interp": {"top": "cs_audio_interp", "files": ["rtl/audio/cs_audio_interp.sv"], "main": "sim/mister/audio_interp.cpp", "parameters": []},
    "mister_audio_cdc": {"top": "cs_audio_interp", "files": ["rtl/audio/cs_audio_interp.sv"], "main": "sim/mister/audio_cdc.cpp", "parameters": []},
    "mister_hold": {"top": "cs_video_hold", "files": ["rtl/video/cs_video_hold.sv"], "main": "sim/mister/hold.cpp", "parameters": []},
    "mister_sys_video": {"top": "cs_sys_video", "files": ["rtl/video/cs_video_hold.sv", "rtl/vendor/crt_adjust.sv", "rtl/video/crystal_crt_adjust.sv", "sys/arcade_video.v", "sys/video_mixer.sv", "sys/scandoubler.v", "sys/hq2x.sv", "sys/gamma_corr.sv", "sys/video_freezer.sv", "sim/mister/sync_fix.v", "sim/mister/sys_video.sv"], "main": "sim/mister/sys_video.cpp", "parameters": ["-Wno-PROCASSWIRE", "--public-flat-rw"]},
    "mister_rotate": {"top": "cs_screen_rotate", "files": ["rtl/video/cs_screen_rotate.sv"], "main": "sim/mister/rotate.cpp", "parameters": ["-GWIDTH=8", "-GHEIGHT=6", "-GFIFO_BITS=4"]},
})

if __name__ == "__main__":
    raise SystemExit(sim.main())
