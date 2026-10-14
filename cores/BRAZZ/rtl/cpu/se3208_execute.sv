// SPDX-License-Identifier: GPL-3.0-or-later
// Register-only execution unit; memory/control operations use the CPU sequencer.
module se3208_execute #(parameter bit REGISTERED_MUL=1'b0,
    parameter bit REGISTERED_DECODE=1'b0,
    parameter bit REGISTERED_OPERANDS=1'b0) (
    input logic [15:0] opcode,
    input logic [7:0][31:0] registers,
    input logic [31:0] sr, er,
    input logic [63:0] multiply_product,
    input logic [31:0] prepared_a, prepared_b,
    input logic [4:0] prepared_shift_count,
    input se3208_pkg::operation_t decoded_operation,
    output logic supported, register_write,
    output logic [2:0] register_index,
    output logic [31:0] register_data, next_sr, next_er
);
    import se3208_pkg::*;
    operation_t operation;
    operation_t local_operation;
    se3208_decode decoder (.opcode, .operation(local_operation));
    assign operation=REGISTERED_DECODE ? decoded_operation : local_operation;
    logic [31:0] a, b, result, flag_mask;
    logic [63:0] product;
    logic immediate, arithmetic, logical_flags, carry, overflow;
    logic [4:0] shift_count;

    always_comb begin
        supported = 1;
        register_write = 1;
        register_index = opcode[2:0];
        next_sr = sr;
        next_er = er;
        immediate = 0;
        arithmetic = 0;
        logical_flags = 0;
        carry = 0;
        overflow = 0;
        flag_mask = 0;
        a = REGISTERED_OPERANDS ? prepared_a : registers[opcode[5:3]];
        b = REGISTERED_OPERANDS ? prepared_b : registers[opcode[11:9]];
        result = 0;
        product = 0;
        shift_count = REGISTERED_OPERANDS ? prepared_shift_count :
            (opcode[10] ? registers[opcode[7:5]][4:0] : opcode[9:5]);

        case (operation)
            OP_ADDI, OP_ADCI, OP_SUBI, OP_SBCI, OP_ANDI, OP_ORI,
            OP_XORI, OP_CMPI, OP_TSTI: begin
                immediate = 1;
                b = sr[11] ? {er[27:0], opcode[12:9]} : {{28{opcode[12]}},opcode[12:9]};
                next_sr = sr & ~SR_E;
            end
            default: begin end
        endcase

        case (operation)
            OP_ADD, OP_ADDI, OP_ADC, OP_ADCI: begin
                result = a + b + ((operation == OP_ADC || operation == OP_ADCI) ? {31'b0,sr[7]} : 32'b0);
                arithmetic = 1;
                carry = (a[31] & b[31]) | (~result[31] & (a[31] | b[31]));
                overflow = (a[31] ^ result[31]) & (b[31] ^ result[31]);
            end
            OP_SUB, OP_SUBI, OP_SBC, OP_SBCI, OP_CMP, OP_CMPI, OP_NEG: begin
                if (operation == OP_NEG) begin
                    b = a;
                    a = 0;
                    register_index = opcode[11:9];
                end
                result = a - b - ((operation == OP_SBC || operation == OP_SBCI) ? {31'b0,sr[7]} : 32'b0);
                arithmetic = 1;
                carry = (b[31] & result[31]) | (~a[31] & (b[31] | result[31]));
                overflow = (b[31] ^ a[31]) & (result[31] ^ a[31]);
                if (operation == OP_CMP || operation == OP_CMPI) register_write = 0;
            end
            OP_AND, OP_ANDI, OP_TST, OP_TSTI: begin
                result = a & b;
                logical_flags = 1;
                if (operation == OP_TST || operation == OP_TSTI) register_write = 0;
            end
            OP_OR, OP_ORI: begin result = a | b; logical_flags = 1; end
            OP_XOR, OP_XORI: begin result = a ^ b; logical_flags = 1; end
            OP_MOV: begin register_index = opcode[11:9]; result = a; end
            OP_LDI: begin
                register_index = opcode[10:8];
                // This encoding consumes four low bits with E set, as MAME does.
                result = sr[11] ? {er[27:0],opcode[3:0]} : {{24{opcode[7]}},opcode[7:0]};
                next_sr = sr & ~SR_E;
            end
            OP_LERI: begin
                register_write = 0;
                next_er = sr[11] ? {er[17:0],opcode[13:0]} : {{18{opcode[13]}},opcode[13:0]};
                next_sr = sr | SR_E;
            end
            OP_EXTB, OP_EXTS: begin
                // Four-bit register indices 8..15 access outside MAME's GPR array;
                // they remain unresolved reserved encodings, not invented aliases.
                supported = !opcode[3];
                if (!REGISTERED_OPERANDS) a = registers[opcode[2:0]];
                result = operation == OP_EXTB ? {{24{a[7]}},a[7:0]} : {{16{a[15]}},a[15:0]};
                logical_flags = 1;
                next_sr = sr & ~SR_E;
            end
            OP_MULS: begin
                if (!REGISTERED_OPERANDS) b = registers[opcode[8:6]];
                product = REGISTERED_MUL ? multiply_product : {32'b0,a} * {32'b0,b};
                result = product[31:0];
                next_sr = (sr & ~(SR_V | SR_E)) | ((product[63:32] != 0) ? SR_V : 0);
            end
            OP_ASR, OP_LSR, OP_ASL: begin
                if (!REGISTERED_OPERANDS) a = registers[opcode[2:0]];
                arithmetic = 1;
                next_sr = sr & ~SR_E;
                if (operation == OP_ASL) begin
                    result = a << shift_count;
                    // Zero count follows the reference's x86 masked bit indexing.
                    carry = a[(5'd0 - shift_count)];
                end else begin
                    result = operation == OP_ASR ? $unsigned($signed(a) >>> shift_count) : a >> shift_count;
                    carry = a[(shift_count - 5'd1)];
                end
            end
            OP_SET: begin register_write = 0; next_sr = sr | (32'd1 << opcode[3:0]); end
            OP_CLR: begin register_write = 0; next_sr = sr & ~(32'd1 << opcode[3:0]); end
            default: begin supported = 0; register_write = 0; end
        endcase
        if (arithmetic || logical_flags) begin
            flag_mask = arithmetic ? (SR_S | SR_Z | SR_C | SR_V) : (SR_S | SR_Z);
            next_sr = (next_sr & ~flag_mask) | (result[31] ? SR_S : 0) |
                ((result == 0) ? SR_Z : 0);
            if (arithmetic) next_sr = next_sr | (carry ? SR_C : 0) | (overflow ? SR_V : 0);
        end
        register_data = result;
    end
endmodule
