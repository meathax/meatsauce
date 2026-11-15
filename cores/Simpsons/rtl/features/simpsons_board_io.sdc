# Board-owned exceptions for verified observation/analogue aliases only.
# Evidence: reference/review/board-io-classification.json, pinned native fit.
# Real HDMI/I2S, DB15 and I2C paths remain unconstrained pending contracts.
proc simpsons_io_count {collection expected description} {
    if {[get_collection_size $collection] != $expected} {
        error "Simpsons board IO: expected $expected $description"
    }
}
set board_led_indicators [get_ports {LED[0] LED[2] LED[6]}]
simpsons_io_count $board_led_indicators 3 "human LED indicator pins"
# sys_top.v:157: DE10 LED bank, no external synchronous receiver.
set_false_path -to $board_led_indicators

set board_hdmi_interrupt [get_ports {HDMI_TX_INT}]
simpsons_io_count $board_hdmi_interrupt 1 "HDMI asynchronous interrupt pin"
# sys_top.v:234,281: ADV7513 INT is software-observed HPS GP status.
# No fabric capture clock/edge is defined for this asynchronous event.
set_false_path -from $board_hdmi_interrupt

set board_carddetect [get_ports {SDCD_SPDIF}]
set board_carddetect_targets [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*]}]
simpsons_io_count $board_carddetect 1 "multiplexed card-detect/SPDIF pin"
simpsons_io_count $board_carddetect_targets 6 "card-detect controlled pin mux targets"
# sys_top.v:131,137: asynchronous card-detect selects analogue/SD mode.
# Scope ONLY combinational routing/OE control; no data capture is cut.
set_false_path -from $board_carddetect -to $board_carddetect_targets

set board_analog_alias_targets [get_ports {SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS}]
simpsons_io_count $board_analog_alias_targets 7 "analogue-only path aliases"
set board_analog_producers [get_keepers {vga_out*|* yc_out*|*}]
if {[get_collection_size $board_analog_producers] == 0} {error "Missing analogue source keepers"}
# sys_top.v:134,137,1527..1529: these source->pin paths are resistor-DAC
# colour bits and CRT composite sync, with no external capture clock.
# Reuse stock sys_top.sdc VGA_* observation policy ONLY for VGA/YC sources.
# SD/SPI-producing paths to the same physical pins remain analyzable.
set_false_path -from $board_analog_producers -to $board_analog_alias_targets

set board_spdif_producers [get_keepers {audio_out*|spdif*|*}]
if {[get_collection_size $board_spdif_producers] == 0} {error "Missing self-clocked SPDIF source keepers"}
# sys_top.v:1559: alias of the self-clocked biphase SPDIF stream, identical
# to stock AUDIO_SPDIF exception. I2S/audio-clock pins are NOT cut.
set_false_path -from $board_spdif_producers -to $board_carddetect
