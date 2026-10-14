cd /mnt/d/Arcade/AI/aCORES/zero
verilator --binary --timing -Wno-fatal -Wno-PROCASSWIRE -Wno-BLKANDNBLK -Wno-WIDTH -Wno-PINMISSING -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD -DSIMULATION --Mdir /mnt/r/Verilator/zero-video-chain --top-module tb \
  sys/arcade_video.v sys/video_mixer.sv sys/video_freezer.sv sys/gamma_corr.sv sys/scandoubler.v sys/hq2x.sv sys/math.sv sim/video_chain/sync_fix.sv sys/video_cleaner.sv sys/scanlines.v \
  rtl/Raiden2/Raiden2_video_timing.sv sim/video_chain/vbench.sv sim/video_chain/tb.sv > /tmp/vc.log 2>&1 || grep -E "%Error" /tmp/vc.log | head -8
/mnt/r/Verilator/zero-video-chain/Vtb | grep -E "OLD|NEW"
