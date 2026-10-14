# Saved-fit SDRAM cycle diagnostic proposal

Status: **NOT EXECUTED — automatic approval review rejected this action.** Production memory constraints remain unchanged. This proposal does not authorize a production exception or an RBF build.

The +3.175 ns capture-clock fit succeeds but reports input setup -11.681/-11.297/-8.971/-8.572 ns. The actual delayed-return controller test passes all eight fitted endpoint profiles with 210 physical read/masked-write transactions each. Its discrete pin model checks word ownership and assembly; it does not include FPGA clock uncertainty/metastability. A +1-period arithmetic shift of the worst setup value still gives -0.041 ns, so a cycle relationship alone would not establish closure.

The question is whether the registered-input controller's READ_LATENCY=4 consumes the preceding external SDRAM beat at the late capture edge. The diagnostic would report both the unmodified setup/hold relationships and this candidate relationship on completed snapshot1791218297694219300. Exactly16 DQ inputs and16 sampled_dq capture FFs must match. It would apply only this temporary in-memory TimeQuest command:

```tcl
set_multicycle_path -setup 2 -end -from $dq -to $capture
```

There would be **no compensating hold override**: continuous BL2 returns can change each period, so the next-beat hold check must remain strict. Both before/after reports would retain all four corners, source/target clocks, edge relationships and complete paths. A negative result remains a failure. QSF/SDC bytes would be restored exactly; the production constraints, RTL, PLL frequency and assembler remain untouched. This cannot qualify the full core, CDC, remaining interfaces, game or hardware.

Approval sought: execute this saved-fit diagnostic only. Any production timing change requires separate evidence that its edge relationship describes the actual controller protocol and preserves the next-beat setup/hold aperture. Existing physical routing work continues independently.

Automatic review reason: "This retries the previously rejected setup multicycle exception, which can mask the real SDRAM timing violation contrary to the explicit no-masking requirement, even in a diagnostic probe." No workaround or indirect execution has been attempted after that rejection.
