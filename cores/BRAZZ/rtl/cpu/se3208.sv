// SPDX-License-Identifier: GPL-3.0-or-later
// SE3208 architectural CPU with real instruction fetch and stalled memory bus.
// ENABLE_STATE_LOAD exists only for isolated differential unit tests. Production
// instances keep its default zero and boot exclusively through the reset vector.
//
// INVALID_OP_NOP selects the treatment of encodings MAME decodes as INVALIDOP
// (an empty handler: PC advances by two, no register/SR/ER/E change) and of the
// vendor-named coprocessor-class words with no defined effect here (CCMD, GETC,
// EXC, LDC, STC). 0 (default) stops with fault/fault_pc/fault_opcode; 1 retires
// them as MAME's no-ops. Four-bit register indices 8..15 on EXTB/EXTS/JR/CALLR
// index outside MAME's GPR array (undefined behavior there) and always fault.
//
// CE_CATCHUP=1 treats ce as the nominal CPU cycle (MAME: one instruction per
// cycle) instead of the step enable. The FSM then steps on every system clock
// while retired instructions trail elapsed nominal cycles (bounded credit), so
// clocks lost to memory waits and multi-step instructions are repaid but the
// CPU can never get ahead of MAME's instruction rate. ce held low (pause)
// stops the CPU within two clocks. CE_CATCHUP=0 keeps ce as the step enable.
module se3208 #(
    parameter bit ENABLE_STATE_LOAD = 0,
    parameter bit INVALID_OP_NOP = 0,
    parameter bit CE_CATCHUP = 0,
    // FETCH_PAIR=1: after an ALU instruction fetched from an aligned word, take
    // the next sequential instruction from the other half of that same reply
    // (bus command size 3) instead of a second memory request.
    parameter bit FETCH_PAIR = 0,
    // FAST_BUS=1 lets the bus adapter present a command's request in the same
    // clock (no registered request stage).
    parameter bit FAST_BUS = 0,
    // PREFETCH=1 (needs FAST_BUS): when the fetch reply of an instruction in
    // the upper half of a word is consumed, the next word's fetch is issued in
    // the same clock, overlapping it with EXECUTE. A sequential ALU retire
    // then waits only for that reply; any other path discards it first. The
    // instruction executed after a discard is always fetched again.
    parameter bit PREFETCH = 0,
    parameter int CATCHUP_CREDIT = 255
) (
    input logic clk, reset, ce,
    output logic req_valid,
    input logic req_ready,
    output logic [31:0] req_address, req_data,
    output logic [3:0] req_strobe,
    output logic req_write,
    input logic rsp_valid,
    input logic [31:0] rsp_data,
    input logic rsp_error,
    output logic cp_req_valid, input logic cp_req_ready,
    output logic cp_req_write,
    output logic [1:0] cp_req_id,
    output logic [2:0] cp_req_register,
    output logic [31:0] cp_req_data,
    input logic cp_rsp_valid, output logic cp_rsp_ready,
    input logic [31:0] cp_rsp_data, input logic cp_rsp_error,
    input logic irq, nmi,
    input logic [7:0] irq_vector,
    output logic irq_ack,
    output logic machine_event,
    output logic [7:0] machine_code,
    output logic fault,
    output logic [31:0] fault_pc,
    output logic [15:0] fault_opcode,
    output logic retire,
    output logic [31:0] retire_pc,
    output logic [15:0] retire_opcode,
    output logic [7:0][31:0] registers,
    output logic [31:0] pc, sr, sp, er,
    input logic state_load,
    input logic [7:0][31:0] state_registers,
    input logic [31:0] state_pc, state_sr, state_sp, state_er
);
    import se3208_pkg::*;
    logic run;
    logic fetch_pair_ok;
    // instruction_pc + 2, kept as a register so the sequential/prefetch fetch
    // address presented to the bus adapter in the same clock has no adder.
    logic [31:0] instruction_pc_plus2;
    logic pf_pending /*verilator public_flat*/;
    typedef enum logic [3:0] {RESET_START,FETCH_START,EXECUTE,ACCESS_START,
        ACCESS_WAIT,STACK_SCAN,VECTOR_START,RETIRE,STOPPED,CP_START,CP_WAIT,LOAD_COMMIT} state_t;
    typedef enum logic [2:0] {READ_RESET,READ_FETCH,READ_LOAD,WRITE_STORE,
        WRITE_STACK,READ_STACK,READ_VECTOR} continuation_t;
    state_t state;
    continuation_t continuation;
    logic [15:0] opcode;
    logic [31:0] instruction_pc;
    operation_t operation,fetched_operation;
    logic alu_supported, alu_write;
    logic [2:0] alu_index;
    logic [31:0] alu_data, alu_sr, alu_er;
    logic [31:0] mul00,mul01,mul10,mul11;
    logic [32:0] mul_cross;
    logic [63:0] multiply_product;
    logic [31:0] operand_a,operand_b;
    logic [4:0] operand_shift_count;
    logic [31:0] multiply_a,multiply_b;
    logic multiply_ready;
    se3208_execute #(.REGISTERED_MUL(1'b1),.REGISTERED_DECODE(1'b1),.REGISTERED_OPERANDS(1'b1)) execute_unit (.opcode, .registers, .sr, .er,
        .multiply_product, .decoded_operation(operation),
        .prepared_a(operand_a),.prepared_b(operand_b),.prepared_shift_count(operand_shift_count),
        .supported(alu_supported), .register_write(alu_write),
        .register_index(alu_index), .register_data(alu_data),
        .next_sr(alu_sr), .next_er(alu_er));

    logic command_ready, result_valid, result_error;
    logic [31:0] result_data, command_address, command_data;
    logic [31:0] prepared_load;
    logic [1:0] command_size;
    logic command_write;
    // Decode while accepting the existing instruction-fetch reply. EXECUTE
    // then starts with a registered operation, removing decode before ALU
    // immediate selection/addition without adding an instruction cycle.
    se3208_decode decoder (.opcode(result_data[15:0]), .operation(fetched_operation));
    wire [31:0] fetch_a_lo = registers[result_data[2:0]], fetch_a_hi = registers[result_data[5:3]];
    wire [31:0] fetch_b_lo = registers[result_data[8:6]], fetch_b_hi = registers[result_data[11:9]];
    // Operand-field selects come straight from the opcode bits (identical to the decode of
    // EXTB/EXTS/ASR/LSR/ASL and MULS in se3208_decode) so the late fetch reply does not
    // traverse the decoder before the register-file select.
    wire fetch_a_low = (result_data[15:8]==8'hE0 && result_data[7:5]==3'd0) ||
                       (result_data[15:11]==5'b11110 && result_data[4:3]!=2'd3);
    wire fetch_b_low = result_data[15:12]==4'hF && result_data[11:9]==3'd4;
    wire load_state = ENABLE_STATE_LOAD && state_load;
    // Launch the next real fetch directly at the architectural retirement
    // boundary. A pending interrupt owns that boundary instead, so no fetch
    // crosses interrupt entry. Reset/load fallback also launches without a
    // separate address-setup state. The bus still supplies all backpressure.
    wire retire_interrupt = !interrupt_serviced &&
        (nmi_pending || (nmi && !nmi_previous) || (irq && sr[13]));
    // ALU operations complete on the execute edge. Use their updated enable
    // flag to decide whether that edge can also retire and launch the next
    // real sequential fetch; interrupt entry retains the full existing path.
    // Only SET/CLR change the interrupt-enable flag (SR bit 13; every other ALU result leaves it as is), so the
    // shortcut decides with the current flag and hands SET/CLR to the normal RETIRE path, which checks the
    // updated flag. This keeps the ALU result mux (alu_sr) off the next-fetch launch path.
    wire ie_change = operation == OP_SET || operation == OP_CLR;
    wire execute_retire_interrupt = !interrupt_serviced &&
        (nmi_pending || (nmi && !nmi_previous) || (irq && sr[13]));
    wire execute_retire = state == EXECUTE && alu_supported && !ie_change && !execute_retire_interrupt &&
        (operation != OP_MULS || multiply_ready);
    // FAST_BUS: a load also retires and launches the next fetch on its
    // register-commit edge (no separate RETIRE edge) when no interrupt is due.
    wire commit_retire = FAST_BUS && state == LOAD_COMMIT && !retire_interrupt;
    wire direct_fetch = state == FETCH_START || (state == RETIRE && !retire_interrupt) ||
        (execute_retire && !pf_pending) || commit_retire;
    wire fetch_consume = state == ACCESS_WAIT && continuation == READ_FETCH;
    // result_valid/result_error come from the bus adapter below.
    wire pf_issue = PREFETCH && FAST_BUS && run && fetch_consume && result_valid && !result_error &&
        instruction_pc[1:0] == 2'b10;
    // An outstanding prefetch that the CPU is not waiting for as its fetch is
    // consumed and dropped, except in EXECUTE where the retire decides.
    wire pf_discard = pf_pending && !fetch_consume && state != EXECUTE;
    // The command payload is chosen by the registered state alone (it is only
    // sampled while command_valid): ACCESS_START carries the prepared memory
    // command; EXECUTE/RETIRE/FETCH_START a sequential or pc instruction fetch.
    // Only command_valid depends on the execute-edge retire decision.
    wire command_slot = state == ACCESS_START;
    se3208_bus_access #(.PASS_THROUGH(FAST_BUS)) access_unit (.clk, .reset(reset || load_state),
        .command_valid((run && (state == ACCESS_START || direct_fetch)) || pf_issue), .command_ready,
        .command_address(command_slot ? command_address : (state == EXECUTE || state == ACCESS_WAIT) ? instruction_pc_plus2 : pc),
        .command_data(command_slot ? command_data : 32'b0),
        .command_size(command_slot ? command_size : (FETCH_PAIR && state == EXECUTE && fetch_pair_ok) ? 2'd3 : 2'd1),
        .command_write(command_slot ? command_write : 1'b0),
        .result_valid, .result_ready(run && (state == ACCESS_WAIT || pf_discard)),
        .result_data, .result_error,
        .req_valid, .req_ready, .req_address, .req_data, .req_strobe,
        .req_write, .rsp_valid, .rsp_data, .rsp_error);

    logic cp_command_ready, cp_result_valid, cp_result_error;
    logic [31:0] cp_result_data;
    se3208_cp_access coprocessor_access (.clk, .reset(reset || load_state),
        .command_valid(run && state == CP_START), .command_ready(cp_command_ready),
        .command_write(operation == OP_MVTC), .command_id(opcode[9:8]),
        .command_register(opcode[2:0]), .command_data(registers[0]),
        .result_valid(cp_result_valid), .result_ready(run && state == CP_WAIT),
        .result_data(cp_result_data), .result_error(cp_result_error),
        .cp_req_valid, .cp_req_ready, .cp_req_write, .cp_req_id,
        .cp_req_register, .cp_req_data, .cp_rsp_valid, .cp_rsp_ready,
        .cp_rsp_data, .cp_rsp_error);

    logic load_signed;
    logic [2:0] load_index;
    logic [10:0] stack_mask;
    logic [3:0] stack_step, stack_register, stack_next_step;
    logic [10:0] stack_step_mask;
    logic stack_pop, vector_pending;
    logic [31:0] stack_pc_value, stack_sr_value;
    logic [7:0] vector_number;
    logic nmi_previous, nmi_pending, interrupt_serviced;
    logic memory_operation, store_operation, signed_operation, branch_operation, branch_taken;
    logic [1:0] memory_size;
    logic [2:0] memory_register;
    logic [31:0] memory_address, base, offset, branch_offset, stack_value;

    always_comb begin
        memory_operation = 0; store_operation = 0; signed_operation = 0;
        memory_size = 2;
        memory_register = opcode[10:8];
        base = opcode[7:5] == 0 ? 32'b0 : registers[opcode[7:5]];
        offset = {27'b0,opcode[4:0]};
        case (operation)
            OP_LDB,OP_LDBU,OP_STB: begin memory_operation = 1; memory_size = 0; end
            OP_LDS,OP_LDSU,OP_STS: begin memory_operation = 1; memory_size = 1; offset = offset << 1; end
            OP_LD,OP_ST: begin memory_operation = 1; offset = offset << 2; end
            OP_LDSP,OP_STSP: begin memory_operation = 1; base = sp; offset = {22'b0,opcode[7:0],2'b0}; end
            OP_LDBSP,OP_LDBUSP,OP_STBSP: begin
                memory_operation = 1; memory_size = 0; base = sp;
                offset = {28'b0,opcode[3:0]}; memory_register = opcode[6:4];
            end
            OP_LDSSP,OP_LDSUSP,OP_STSSP: begin
                memory_operation = 1; memory_size = 1; base = sp;
                offset = {27'b0,opcode[3:0],1'b0}; memory_register = opcode[6:4];
            end
            default: begin end
        endcase
        if (sr[11]) offset = {er[27:0],offset[3:0]};
        memory_address = base + offset;
        case (operation)
            OP_STB,OP_STS,OP_ST,OP_STSP,OP_STBSP,OP_STSSP: store_operation = 1;
            default: begin end
        endcase
        case (operation)
            OP_LDB,OP_LDS,OP_LDBSP,OP_LDSSP: signed_operation = 1;
            default: begin end
        endcase
        branch_operation = 1;
        branch_taken = 0;
        case (operation)
            OP_JNV: branch_taken = !sr[4];
            OP_JV: branch_taken = sr[4];
            OP_JP: branch_taken = !sr[5];
            OP_JM: branch_taken = sr[5];
            OP_JNZ: branch_taken = !sr[6];
            OP_JZ: branch_taken = sr[6];
            OP_JNC: branch_taken = !sr[7];
            OP_JC: branch_taken = sr[7];
            OP_JGT: branch_taken = !(sr[6] || (sr[5] ^ sr[4]));
            OP_JLT: branch_taken = sr[5] ^ sr[4];
            OP_JGE: branch_taken = !(sr[5] ^ sr[4]);
            OP_JLE: branch_taken = sr[6] || (sr[5] ^ sr[4]);
            OP_JHI: branch_taken = !(sr[6] || sr[7]);
            OP_JLS: branch_taken = sr[6] || sr[7];
            OP_JMP,OP_CALL: branch_taken = 1;
            default: branch_operation = 0;
        endcase
        branch_offset = (sr[11] ? {er[23:0],opcode[7:0]} : {{24{opcode[7]}},opcode[7:0]}) << 1;
        stack_register = stack_pop ? stack_step : (4'd10 - stack_step);
        // Skip absent registers in one edge: next scan step whose register is
        // in the mask (11 = done). Same order, same accesses, fewer idle edges.
        for (int i=0;i<11;i=i+1) stack_step_mask[i] = stack_mask[stack_pop ? i : 10-i];
        stack_next_step = 4'd11;
        for (int i=10;i>=0;i=i-1)
            if (stack_step_mask[i] && 4'(i) > stack_step) stack_next_step = 4'(i);
        case (stack_register)
            8: stack_value = er;
            9: stack_value = stack_sr_value;
            10: stack_value = stack_pc_value;
            default: stack_value = registers[stack_register[2:0]];
        endcase
    end

    // Prepare products only from the registered opcode. Routing a returned
    // fetch through halfword assembly, register selection and multiplication
    // in one edge failed board timing. The normal CE-every-two schedule has
    // an idle board edge to prepare products; consecutive CE pulses wait one
    // edge for MULS. No bus access changes; preserve the full overflow product.
    // The multiplier operands get their own register stage: otherwise the DSP absorbed the
    // operand registers and the whole fetch-reply -> decode -> register-select path had to reach
    // the DSP input pins (setup failed by 0.15 ns). MULS now waits one more clock (multiply_ready).
    logic [31:0] multiply_a_q, multiply_b_q;
    logic fetch_reply_q;
    always_ff @(posedge clk) begin multiply_a_q<=operand_a; multiply_b_q<=operand_b; end
    always_comb begin
        multiply_a=multiply_a_q;
        multiply_b=multiply_b_q;
        mul_cross={1'b0,mul01}+{1'b0,mul10};
        multiply_product={32'b0,mul00}+{15'b0,mul_cross,16'b0}+{mul11,32'b0};
    end
    always_ff @(posedge clk) begin
        if(reset || load_state) begin mul00<=0;mul01<=0;mul10<=0;mul11<=0;multiply_ready<=0;fetch_reply_q<=0;end
        else begin
            fetch_reply_q <= run && state==ACCESS_WAIT && continuation==READ_FETCH && result_valid;
            multiply_ready <= !((run && state==ACCESS_WAIT && continuation==READ_FETCH && result_valid) || fetch_reply_q);
            mul00<=multiply_a[15:0]*multiply_b[15:0];
            mul01<=multiply_a[15:0]*multiply_b[31:16];
            mul10<=multiply_a[31:16]*multiply_b[15:0];
            mul11<=multiply_a[31:16]*multiply_b[31:16];
        end
    end
    generate if (CE_CATCHUP) begin : catchup
        // credit = nominal cycles elapsed - instructions retired, saturated to
        // [0,CATCHUP_CREDIT]. A registered enable keeps ce/credit logic out of
        // the FSM's enable fanout; requiring two credits covers the one-clock
        // lag between an enabled retiring edge and its retire pulse.
        localparam int CREDIT_BITS = $clog2(CATCHUP_CREDIT+1);
        logic ce_q, run_q;
        logic [CREDIT_BITS-1:0] credit, credit_next;
        always_comb begin
            credit_next = credit;
            if (ce && !retire && credit != CREDIT_BITS'(CATCHUP_CREDIT)) credit_next = credit + 1'b1;
            else if (!ce && retire && credit != 0) credit_next = credit - 1'b1;
        end
        always_ff @(posedge clk) begin
            if (reset) begin ce_q <= 0; run_q <= 0; credit <= 0; end
            else begin
                ce_q <= ce; credit <= credit_next;
                run_q <= (ce || ce_q) && credit_next >= CREDIT_BITS'(2);
            end
        end
        assign run = run_q;
    end else begin : step_enable
        assign run = ce;
    end endgenerate
    always_ff @(posedge clk) begin
        retire <= 0; irq_ack <= 0; machine_event <= 0;
        nmi_previous <= nmi;
        if (nmi && !nmi_previous) nmi_pending <= 1;
        if (reset) begin
            state <= RESET_START;
            registers <= 0; pc <= 0; sr <= 0; sp <= 0; er <= 0;
            opcode <= 0; instruction_pc <= 0; instruction_pc_plus2 <= 2;
            operand_a<=0;operand_b<=0;operand_shift_count<=0;
            operation <= operation_t'(0);
            fault <= 0; fault_pc <= 0; fault_opcode <= 0;
            retire_pc <= 0; retire_opcode <= 0;
            machine_code <= 0; nmi_previous <= 0; nmi_pending <= 0;
            interrupt_serviced <= 0; continuation <= READ_RESET; fetch_pair_ok <= 0; pf_pending <= 0;
            command_address <= 0; command_data <= 0; command_size <= 2; command_write <= 0;
            load_signed <= 0; load_index <= 0; prepared_load <= 0;
            stack_mask <= 0; stack_step <= 0; stack_pop <= 0;
            stack_pc_value <= 0; stack_sr_value <= 0;
            vector_pending <= 0; vector_number <= 0;
        end else if (load_state) begin
            state <= FETCH_START; fault <= 0; fetch_pair_ok <= 0; pf_pending <= 0;
            registers <= state_registers; pc <= state_pc; sr <= state_sr;
            sp <= state_sp; er <= state_er; nmi_pending <= 0;
            interrupt_serviced <= 0;
        end else if (state==LOAD_COMMIT) begin
            // Commit the already extended word on the intervening system edge.
            // Normal CE=/2 reaches RETIRE on the same next CPU-enable edge;
            // consecutive enables take the explicit additional pipeline edge.
            registers[load_index]<=prepared_load;
            if (commit_retire && run && command_ready) begin
                retire <= 1; retire_pc <= instruction_pc; retire_opcode <= opcode;
                instruction_pc <= pc;
                instruction_pc_plus2 <= pc + 2;
                command_address <= pc; command_size <= 1; command_write <= 0;
                continuation <= READ_FETCH; state <= ACCESS_WAIT;
                interrupt_serviced <= 0;
            end else state<=RETIRE;
        end else if (run) case (state)
            RESET_START: begin
                command_address <= 0; command_size <= 2; command_write <= 0;
                continuation <= READ_RESET; state <= ACCESS_START;
            end
            FETCH_START: if (command_ready) begin
                instruction_pc <= pc;
                instruction_pc_plus2 <= pc + 2;
                command_address <= pc; command_size <= 1; command_write <= 0;
                continuation <= READ_FETCH; state <= ACCESS_WAIT;
                interrupt_serviced <= 0;
            end
            ACCESS_START: if (command_ready) state <= ACCESS_WAIT;
            CP_START: if (cp_command_ready) state <= CP_WAIT;
            CP_WAIT: if (cp_result_valid) begin
                if (cp_result_error) begin
                    fault <= 1; fault_pc <= instruction_pc; fault_opcode <= opcode;
                    state <= STOPPED;
                end else begin
                    // ADChips Jupiter data book 4.17.6 establishes implicit R0.
                    // No flag or ER change is introduced by the transfer.
                    if (operation == OP_MVFC) registers[0] <= cp_result_data;
                    state <= RETIRE;
                end
            end
            ACCESS_WAIT: if (result_valid) begin
                if (result_error) begin
                    fault <= 1; fault_pc <= instruction_pc; fault_opcode <= opcode; state <= STOPPED;
                end else case (continuation)
                    READ_RESET: begin pc <= result_data; state <= FETCH_START; end
                    READ_FETCH: begin
                        opcode <= result_data[15:0]; operation <= fetched_operation;
                        fetch_pair_ok <= instruction_pc[1:0] == 2'b00;
                        pf_pending <= pf_issue;
                        // GPRs are architecturally stable throughout this fetch reply.
                        // Select operands here so EXECUTE no longer chains opcode muxes
                        // through the barrel shifter or multiply input on one edge.
                        // Both candidate register reads depend only on result_data bits (not on the
                        // decoder), so only a 2:1 select follows the decode in this timing path.
                        operand_a<=fetch_a_low ? fetch_a_lo : fetch_a_hi;
                        operand_b<=fetch_b_low ? fetch_b_lo : fetch_b_hi;
                        operand_shift_count<=result_data[10] ? registers[result_data[7:5]][4:0] : result_data[9:5];
                        state <= EXECUTE;
                    end
                    READ_LOAD: begin
                        case (command_size)
                            0: prepared_load <= load_signed ? {{24{result_data[7]}},result_data[7:0]} : {24'b0,result_data[7:0]};
                            1: prepared_load <= load_signed ? {{16{result_data[15]}},result_data[15:0]} : {16'b0,result_data[15:0]};
                            default: prepared_load <= result_data;
                        endcase
                        state <= LOAD_COMMIT;
                    end
                    WRITE_STORE: state <= RETIRE;
                    WRITE_STACK: begin stack_step <= stack_step + 1'b1; state <= STACK_SCAN; end
                    READ_STACK: begin
                        sp <= sp + 4;
                        case (stack_register)
                            8: er <= result_data;
                            9: sr <= result_data;
                            10: pc <= result_data;
                            default: registers[stack_register[2:0]] <= result_data;
                        endcase
                        stack_step <= stack_step + 1'b1; state <= STACK_SCAN;
                    end
                    READ_VECTOR: begin pc <= result_data; state <= RETIRE; end
                    default: state <= STOPPED;
                endcase
            end
            EXECUTE: if (operation != OP_MULS || multiply_ready) begin
                pc <= instruction_pc + 2;
                state <= RETIRE;
                if (alu_supported) begin
                    if (alu_write) registers[alu_index] <= alu_data;
                    sr <= alu_sr; er <= alu_er;
                end else if (memory_operation) begin
                    command_address <= memory_address;
                    command_size <= memory_size; command_write <= store_operation;
                    command_data <= registers[memory_register];
                    load_signed <= signed_operation; load_index <= memory_register;
                    sr <= sr & ~SR_E;
                    continuation <= store_operation ? WRITE_STORE : READ_LOAD;
                    state <= ACCESS_START;
                end else if (branch_operation) begin
                    if (branch_taken) pc <= instruction_pc + branch_offset + 2;
                    sr <= sr & ~SR_E;
                    if (operation == OP_CALL) begin
                        stack_mask <= 11'h400; stack_pop <= 0; stack_step <= 0;
                        stack_pc_value <= instruction_pc + 2; vector_pending <= 0;
                        state <= STACK_SCAN;
                    end
                end else case (operation)
                    OP_MVTC, OP_MVFC: state <= CP_START;
                    OP_JR, OP_CALLR: begin
                        if (opcode[3]) begin
                            fault <= 1; fault_pc <= instruction_pc; fault_opcode <= opcode; state <= STOPPED;
                        end else begin
                            pc <= registers[opcode[2:0]]; sr <= sr & ~SR_E;
                            if (operation == OP_CALLR) begin
                                stack_mask <= 11'h400; stack_pop <= 0; stack_step <= 0;
                                stack_pc_value <= instruction_pc + 2; vector_pending <= 0;
                                state <= STACK_SCAN;
                            end
                        end
                    end
                    OP_PUSH, OP_POP: begin
                        stack_mask <= opcode[10:0]; stack_step <= 0;
                        stack_pop <= operation == OP_POP;
                        stack_pc_value <= instruction_pc; stack_sr_value <= sr;
                        vector_pending <= 0; state <= STACK_SCAN;
                    end
                    OP_LEATOSP: begin
                        sp <= ((opcode[5:3] == 0 ? 32'b0 : registers[opcode[5:3]]) +
                            (sr[11] ? {er[27:0],opcode[12:9]} : {{28{opcode[12]}},opcode[12:9]})) & 32'hfffffffc;
                        sr <= sr & ~SR_E;
                    end
                    OP_LEAFROMSP: begin
                        registers[opcode[5:3]] <= sp + (sr[11] ? {er[27:0],opcode[12:9]} : {{28{opcode[12]}},opcode[12:9]});
                        sr <= sr & ~SR_E;
                    end
                    OP_LEASPTOSP: begin
                        sp <= (sp + (sr[11] ? {er[23:0],opcode[5:0],2'b00} : {{22{opcode[7]}},opcode[7:0],2'b00})) & 32'hfffffffc;
                        sr <= sr & ~SR_E;
                    end
                    OP_SWI: if (sr[13]) begin
                        stack_mask <= 11'h600; stack_pop <= 0; stack_step <= 0;
                        stack_pc_value <= instruction_pc; stack_sr_value <= sr;
                        vector_number <= 8'h10 + {4'b0,opcode[3:0]};
                        vector_pending <= 1; state <= STACK_SCAN;
                        sr <= sr & ~(SR_ENI | SR_E | SR_M);
                    end
                    OP_HALT: begin machine_event <= 1; machine_code <= 8'h10 | {4'b0,opcode[3:0]}; end
                    OP_EXTB, OP_EXTS: begin
                        // Register index 8..15 is outside MAME's GPR array: undefined.
                        fault <= 1; fault_pc <= instruction_pc; fault_opcode <= opcode; state <= STOPPED;
                    end
                    default: if (!INVALID_OP_NOP) begin
                        // Unknown coprocessor instructions and invalid encodings
                        // stop with explicit evidence. With INVALID_OP_NOP they
                        // retire as MAME's empty INVALIDOP handler (PC+2 only).
                        fault <= 1; fault_pc <= instruction_pc; fault_opcode <= opcode; state <= STOPPED;
                    end
                endcase
                if (execute_retire) begin
                    retire <= 1; retire_pc <= instruction_pc; retire_opcode <= opcode;
                    // With a prefetch outstanding its reply is this next fetch.
                    if (command_ready || pf_pending) begin
                        instruction_pc <= instruction_pc + 2;
                        instruction_pc_plus2 <= instruction_pc_plus2 + 2;
                        command_address <= instruction_pc + 2; command_size <= 1; command_write <= 0;
                        continuation <= READ_FETCH; state <= ACCESS_WAIT;
                        interrupt_serviced <= 0;
                    end else state <= FETCH_START;
                end
            end
            STACK_SCAN: begin
                if (stack_step == 11) state <= vector_pending ? VECTOR_START : RETIRE;
                else if (!stack_mask[stack_register]) stack_step <= stack_next_step;
                else begin
                    command_size <= 2; command_write <= !stack_pop;
                    command_address <= stack_pop ? sp : sp - 4;
                    command_data <= stack_value;
                    if (!stack_pop) sp <= sp - 4;
                    continuation <= stack_pop ? READ_STACK : WRITE_STACK;
                    state <= ACCESS_START;
                end
            end
            VECTOR_START: begin
                command_address <= {22'b0,vector_number,2'b00}; command_size <= 2; command_write <= 0;
                continuation <= READ_VECTOR; state <= ACCESS_START;
            end
            RETIRE: begin
                if (retire_interrupt) begin
                    stack_mask <= 11'h600; stack_pop <= 0; stack_step <= 0;
                    stack_pc_value <= pc; stack_sr_value <= sr;
                    vector_pending <= 1; interrupt_serviced <= 1; state <= STACK_SCAN;
                    machine_event <= 1;
                    if (nmi_pending || (nmi && !nmi_previous)) begin
                        nmi_pending <= 0; machine_code <= 0; vector_number <= 1;
                        sr <= sr & ~(SR_NMI | SR_ENI | SR_E | SR_M);
                    end else begin
                        irq_ack <= 1; machine_code <= 1;
                        vector_number <= sr[12] ? irq_vector : 8'd2;
                        sr <= sr & ~(SR_ENI | SR_E | SR_M);
                    end
                end else begin
                    retire <= 1; retire_pc <= instruction_pc; retire_opcode <= opcode;
                    if (command_ready) begin
                        instruction_pc <= pc;
                        instruction_pc_plus2 <= pc + 2;
                        command_address <= pc; command_size <= 1; command_write <= 0;
                        continuation <= READ_FETCH; state <= ACCESS_WAIT;
                        interrupt_serviced <= 0;
                    end else state <= FETCH_START;
                end
            end
            STOPPED: begin end
            default: state <= STOPPED;
        endcase
        if (!reset && !load_state && run && pf_discard && result_valid) pf_pending <= 0;
    end
endmodule
