# Sheriff-only completion goal

Paste this prompt. Its final build request applies only after the stated gates pass.

```text
/goal Finish the Sheriff-only MiSTer core (MAME 0.289 parent sheriff) following plan.md and AGENTS.md. Use parallel agents on independent tasks. Reuse passing evidence; fix the earliest divergence, then extend the same real-RTL Verilator run through complete gameplay, both players, rounds, sound and lifecycle with zero unexplained graphics mismatches. Finish Sheriff controls, MiSTer features, MRA and applicable mamebug.md items. Support no other games or clones. Maintain timing closure with necessary analysis/synthesis, full-framework fit and all-corner STA; enforce config/resource_limits.json and one game clock plus enables. Keep progress.md and scoped commits current. After complete simulation and exact final-source timing/resource gates pass, I explicitly request final Sheriff RBF builds/rebuilds through the shared queue and MiSTer hardware testing LAST. Continue to the verified playable release; preserve licenses/private assets and do not publish or push.
```
