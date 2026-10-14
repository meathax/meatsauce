# Cipher provenance

`zeroteam_sprite_decrypt.sv` adapts the pinned GPL-3.0-or-later
rmonic79 `raiden2_sprite_decrypt.sv` datapath. Original notice remains.
The three `*_zt.hex` tables are extracted from MAME 0.289
`src/mame/seibu/r2crypt.cpp`, BSD-3-Clause, copyright Andreas Naive
and Olivier Galibert. That original source is retained in `reference/mame/`.
Indexing/constants follow `zeroteam_decrypt_sprites`; only the first 4 MiB
are decrypted, and the upper 4 MiB pass through as in `init_zeroteam`.
