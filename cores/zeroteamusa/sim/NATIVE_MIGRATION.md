# Lossless native migration for the blank sprite optimization

`scripts/migrate_sprite_blank_checkpoint.py` handles only this proven Zero Team
change. It rejects additional CPU/RTL/ROM/configuration changes. The generated
serialization and deserialization methods and model headers must be identical.
A passive load/save through the new compiled model must reproduce the original
`.rtl` stream byte for byte, without evaluation or clocks. Host bytes, current
input fixture identity and the actual saved cabinet/DIPs must agree too.

The original streams remain intact. The derived checkpoint keeps unchanged
native and host bytes, with explicit provenance and the new compiled-model
inventory. The normal strict resume validator remains in use. Resume branches
with the same input profile and the new binary. On any failed check, retain the
diagnostic and use the original model or a cold run; never patch saved bytes or
bypass the validator. No destructive contraction or hardware work is part of
this operation.
