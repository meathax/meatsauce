# Isolated storage inference

Quartus Prime17.0.2Build602 analysis and synthesis of unchanged `n8080_dram_storage.sv` succeeded with actual process exit0, zero errors and zero warnings on exact Cyclone V device `5CSEBA6U23I7`.

The memory is an inferred `altsyncram` with `RAM_BLOCK_TYPE=M10K`, 16384 eight-bit words and16RAM segments. The report gives131072block-memory bits,0MLAB bits,34dedicated logic registers,53combinational ALUTs,33estimated ALMs and0DSP blocks. These unfitted component estimates rule out expansion of the large array into fabric registers.

The inferred `OPERATION_MODE` is `DUAL_PORT`: write portA and read portB, with `ADDRESS_REG_B=CLOCK0`, `OUTDATA_REG_B=UNREGISTERED` and mixed-port read-during-write `OLD_DATA`. The RTL uses mutually exclusive shared-address read/write operations, but this result does **not** establish physical `SINGLE_PORT` inference. RTL bytes remain unchanged from the native-qualified model. No alteration was made to force a preferred primitive.

The frozen isolated project is `_checks/agent-dram-storage-quartus-20261010`. It contains only the storage RTL plus QPF/QSF/SDC, exact device and one declared50.4MHz master-clock constraint. `GENERATE_RBF_FILE` is OFF. The explicit check-only command was `D:/q17/quartus/bin64/quartus_map.exe dram_storage --rev=dram_storage`. No fit, STA, assembly or RBF generation ran.

[The inference report](evidence/sheriff_dram_storage_inference.json) retains actual native-tool receipt, source/project hashes, synthesis reports, generated memory primitive and an independent hash audit. Resource evidence is in `output_files/dram_storage.map.rpt`, lines203/205/212/215/216/218; primitive evidence also appears in the retained console receipt.

This qualifies component M10K inference and rules out register-memory explosion. It does not qualify the strict physical single-port criterion, placement, Fmax, setup/hold, production integration or full-core utilization. CPU arbitration and physical DRAM/serializer timing remain open.
