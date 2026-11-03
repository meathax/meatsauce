# Target-derived physical HDMI repair, 2026-11-02.
# b074a73880d8: D5=0, scaler setup -0.230ns/hold +0.713ns across all
# eight native corners. Required additional clock-pad delay is inside that
# window; tap14 is a provisional ~0.45ns centring request, not a timing waiver.
# Every native/scaler/audio pad/corner and the fitted D5 readback must pass.
set_instance_assignment -name D5_DELAY 14 -to HDMI_TX_CLK

# Only explicit compressed Arcade- CPF output is produced/published.
set_global_assignment -name COMPRESSION_MODE ON
set_global_assignment -name ON_CHIP_BITSTREAM_DECOMPRESSION ON
set_global_assignment -name GENERATE_RBF_FILE OFF
