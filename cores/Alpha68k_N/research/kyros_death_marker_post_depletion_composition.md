# Finite Kyros post-depletion noise masking

The real CPU snapshot1260 has energy2, depletionflag0 and active AY2-B noise (latest write1259: mixerEF,volume6). Snapshot1290 has energy0, depletionflag1 and noise disabled (latest write1289: mixerFC,volume7). Accepted register states keep noise disabled through1380, where packed lives fall3to2. All61 overlapping MAME marker cases and all7732 AY2 write sequences/field labels match.

The same compiled/current production AY source and passed chip contract support masking composition: mixer bit4 excludes the noise generator from channelB. This allows legitimate nonzero tone. Exact unsampled depletion ticks and direct CPU-channel PCM remain unobserved. Full B03 and whole-game acceptance stay false.
