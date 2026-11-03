//============================================================================
//  MC68705P3 Soft-Core — Cycle-Accurate Implementation (I/O de-glued)
//============================================================================

module mc68705p3 (
    input             clk,
    input             ce,
    input             reset,

    // External interrupt pin (active-low)
    input             int_n,

    // Exposed port registers + inputs
    output reg  [7:0] port_a_out,
    input       [7:0] port_a_in,
    output reg  [7:0] port_a_ddr,

    output reg  [7:0] port_b_out,
    input       [7:0] port_b_in,
    output reg  [7:0] port_b_ddr,

    output reg  [7:0] port_c_out,
    input       [7:0] port_c_in,
    output reg  [7:0] port_c_ddr,

    // ROM interface
    output     [10:0] rom_addr,
    input      [7:0]  rom_data
);

wire int_pin_n = int_n;

//============================================================================
// Registers
//============================================================================
reg  [7:0]  reg_a;
reg  [7:0]  reg_x;
reg  [6:0]  reg_sp;
reg  [10:0] reg_pc;
reg  [4:0]  reg_ccr;        // bit4=H, bit3=I, bit2=N, bit1=Z, bit0=C

// Timer
reg  [7:0]  timer_data;
reg  [7:0]  timer_ctrl;
reg  [7:0]  timer_counter;
reg  [6:0]  prescaler;
reg         timer_irq_flag;

// RAM
reg  [7:0]  ram [0:111];

//============================================================================
// Internal Memory Bus
//============================================================================
reg  [10:0] mem_addr;       // READ address (also drives rom_addr)
reg  [10:0] wr_addr;        // WRITE address (separate from read path)
reg  [7:0]  mem_wdata;      // Write data
reg         mem_we;         // Write enable (fires on NEXT ce tick)

assign rom_addr = mem_addr;

wire [7:0] port_a_pins = (port_a_out & port_a_ddr) | (port_a_in & ~port_a_ddr);
wire [7:0] port_b_pins = (port_b_out & port_b_ddr) | (port_b_in & ~port_b_ddr);
wire [7:0] port_c_pins = (port_c_out & port_c_ddr) | (port_c_in & ~port_c_ddr);

reg [7:0] mem_rd_data;
always @(*) begin
    if (mem_addr <= 11'h00F) begin
        case (mem_addr[3:0])
            4'h0: mem_rd_data = port_a_pins;
            4'h1: mem_rd_data = port_b_pins;
            4'h2: mem_rd_data = port_c_pins;
            4'h3: mem_rd_data = 8'h00;

            4'h4: mem_rd_data = port_a_ddr;
            4'h5: mem_rd_data = port_b_ddr;
            4'h6: mem_rd_data = port_c_ddr;
            4'h7: mem_rd_data = 8'h00;

            4'h8: mem_rd_data = timer_counter;
            4'h9: mem_rd_data = timer_ctrl;

            default: mem_rd_data = 8'h00;
        endcase
    end else if (mem_addr >= 11'h010 && mem_addr <= 11'h07F) begin
        mem_rd_data = ram[mem_addr[6:0] - 7'h10];
    end else begin
        mem_rd_data = rom_data;
    end
end

//============================================================================
// CPU State Machine — Cycle-Accurate
//============================================================================
localparam [5:0]
    S_RESET     = 6'd0,
    S_VEC_HI    = 6'd1,
    S_VEC_LO    = 6'd2,
    S_FETCH     = 6'd3,
    S_OP1       = 6'd4,
    S_OP2       = 6'd5,
    S_MEM_RD    = 6'd6,
    S_EXEC      = 6'd7,
    S_RMW_RD    = 6'd8,
    S_RMW_CALC  = 6'd9,
    S_RMW_WR    = 6'd10,
    S_BTB_OFF   = 6'd11,
    S_BTB_RD    = 6'd12,
    S_BTB_EX    = 6'd13,
    S_JSR_P1    = 6'd14,
    S_JSR_P2    = 6'd15,
    S_INT_P1    = 6'd16,
    S_INT_P2    = 6'd17,
    S_INT_P3    = 6'd18,
    S_INT_P4    = 6'd19,
    S_INT_P5    = 6'd20,
    S_INT_VEC   = 6'd21,
    S_RTI_1     = 6'd22,
    S_RTI_2     = 6'd23,
    S_RTI_3     = 6'd24,
    S_RTI_4     = 6'd25,
    S_RTS_1     = 6'd26,
    S_RTS_2     = 6'd27,
    S_RTS_3     = 6'd28,
    S_WAIT      = 6'd29,
    S_MUL_EXEC  = 6'd30,
    S_DIR_WR2   = 6'd31,
    S_IX_SETUP  = 6'd32,
    S_IX1_CALC  = 6'd33,
    S_IX2_CALC  = 6'd34,
    S_BSR_CALC  = 6'd35,
    S_SWI_SETUP = 6'd36;

reg [5:0]  state;
reg [7:0]  opcode;
reg [7:0]  op1, op2;
reg [7:0]  mem_data;
reg [7:0]  rmw_data;
reg [10:0] ea;
reg [1:0]  int_type;
reg [3:0]  wait_count;

reg [7:0]  tmp_r;
reg        tmp_co;
reg        tmp_take;
reg [7:0]  tmp_mask;
reg [8:0]  tmp_res9;

// Interrupt pending signals
wire int_ext_pending   = ~reg_ccr[3] & ~int_pin_n;
wire int_timer_pending = ~reg_ccr[3] & timer_irq_flag;

//============================================================================
// Main State Machine
//============================================================================
always @(posedge clk) begin
    if (reset) begin
        state      <= S_RESET;
        reg_a      <= 8'h00;
        reg_x      <= 8'h00;
        reg_sp     <= 7'h7F;
        reg_pc     <= 11'h000;
        reg_ccr    <= 5'b01000;

        port_a_out <= 8'h00;
        port_a_ddr <= 8'h00;
        port_b_out <= 8'hFF;
        port_b_ddr <= 8'h00;
        port_c_out <= 8'h00;
        port_c_ddr <= 8'h00;

        timer_data <= 8'hFF;
        timer_ctrl <= 8'h00;
        timer_counter <= 8'hFF;
        prescaler     <= 7'h00;
        timer_irq_flag <= 1'b0;

        mem_we     <= 1'b0;
        wr_addr    <= 11'd0;
        wait_count <= 4'd0;

        mem_addr   <= 11'h000;
    end else if (ce) begin
        mem_we <= 1'b0;

        // === Delayed I/O register writes (use wr_addr, not mem_addr) ===
        if (mem_we) begin
            if (wr_addr <= 11'h00F) begin
                case (wr_addr[3:0])
                    4'h0: port_a_out <= mem_wdata;
                    4'h1: port_b_out <= mem_wdata;
                    4'h2: port_c_out <= mem_wdata;

                    4'h4: port_a_ddr <= mem_wdata;
                    4'h5: port_b_ddr <= mem_wdata;
                    4'h6: port_c_ddr <= mem_wdata;

                    4'h8: begin
                        timer_data    <= mem_wdata;
                        timer_counter <= mem_wdata;
                    end
                    4'h9: begin
                        timer_ctrl <= mem_wdata;
                        timer_irq_flag <= 1'b0;
                    end
                    default: ;
                endcase
            end else if (wr_addr >= 11'h010 && wr_addr <= 11'h07F) begin
                ram[wr_addr[6:0] - 7'h10] <= mem_wdata;
            end
        end

        // === Timer ===
        prescaler <= prescaler + 1'b1;
        if (&prescaler) begin
            if (timer_counter == 8'h00) begin
                timer_counter <= timer_data;
                timer_irq_flag <= 1'b1;
            end else begin
                timer_counter <= timer_counter - 1'b1;
            end
        end

        case (state)

        //=====================================================================
        // RESET + VECTOR LOAD
        //=====================================================================
        S_RESET: begin
            mem_addr <= 11'h7FE;
            state <= S_VEC_HI;
        end

        S_VEC_HI: begin
            reg_pc[10:8] <= mem_rd_data[2:0];
            mem_addr <= mem_addr + 11'd1;
            state <= S_VEC_LO;
        end

        S_VEC_LO: begin
            reg_pc[7:0] <= mem_rd_data;
            mem_addr <= {reg_pc[10:8], mem_rd_data};
            state <= S_FETCH;
        end

        //=====================================================================
        // FETCH — Cycle 1 of every instruction
        //=====================================================================
        S_FETCH: begin
            opcode <= mem_rd_data;
            reg_pc <= reg_pc + 11'd1;
            mem_addr <= reg_pc + 11'd1;

            casez (mem_rd_data)
                8'b0000_????: state <= S_OP1;
                8'b0001_????: state <= S_OP1;
                8'b0010_????: state <= S_OP1;
                8'b0011_????: state <= S_OP1;

                8'b0100_????: begin
                    if (mem_rd_data == 8'h42) begin
                        wait_count <= 4'd9;
                        state <= S_MUL_EXEC;
                    end else begin
                        wait_count <= 4'd0;
                        state <= S_WAIT;
                    end
                end

                8'b0101_????: begin
                    wait_count <= 4'd0;
                    state <= S_WAIT;
                end

                8'b0110_????: state <= S_OP1;

                8'b0111_????: begin
                    ea <= {3'b000, reg_x};
                    mem_addr <= {3'b000, reg_x};
                    state <= S_IX_SETUP;
                end

                8'h80: begin wait_count <= 4'd1; state <= S_WAIT; end
                8'h81: begin wait_count <= 4'd1; state <= S_WAIT; end

                8'h83: begin
                    int_type <= 2'd2;
                    state <= S_SWI_SETUP;
                end

                8'h8E, 8'h8F: state <= S_EXEC;

                8'b1001_????: state <= S_EXEC;

                8'hAD: state <= S_OP1;
                8'b1010_????: state <= S_OP1;

                8'b1011_????: state <= S_OP1;
                8'b1100_????: state <= S_OP1;
                8'b1101_????: state <= S_OP1;
                8'b1110_????: state <= S_OP1;

                8'b1111_????: begin
                    ea <= {3'b000, reg_x};
                    if (mem_rd_data[3:0] == 4'hC) begin
                        reg_pc <= {3'b000, reg_x};
                        mem_addr <= {3'b000, reg_x};
                        if (int_ext_pending) begin
                            int_type <= 2'd0;
                            state <= S_INT_P1;
                        end else if (int_timer_pending) begin
                            int_type <= 2'd1;
                            state <= S_INT_P1;
                        end else
                            state <= S_FETCH;
                    end else if (mem_rd_data[3:0] == 4'hD) begin
                        ea <= {3'b000, reg_x};
                        state <= S_JSR_P1;
                    end else if (mem_rd_data[3:0] == 4'h7 || mem_rd_data[3:0] == 4'hF) begin
                        mem_addr <= {3'b000, reg_x};
                        state <= S_IX_SETUP;
                    end else begin
                        mem_addr <= {3'b000, reg_x};
                        state <= S_MEM_RD;
                    end
                end

                default: state <= S_EXEC;
            endcase
        end

        //=====================================================================
        // S_OP1
        //=====================================================================
        S_OP1: begin
            op1 <= mem_rd_data;
            reg_pc <= reg_pc + 11'd1;

            casez (opcode)
                8'b0000_????: begin
                    mem_addr <= reg_pc + 11'd1;
                    state <= S_BTB_OFF;
                end

                8'b0001_????: begin
                    ea <= {3'b000, mem_rd_data};
                    mem_addr <= {3'b000, mem_rd_data};
                    state <= S_RMW_RD;
                end

                8'b0010_????: state <= S_EXEC;

                8'hAD: state <= S_BSR_CALC;

                8'b0011_????: begin
                    ea <= {3'b000, mem_rd_data};
                    mem_addr <= {3'b000, mem_rd_data};
                    state <= S_RMW_RD;
                end

                8'b0110_????: state <= S_IX1_CALC;

                8'b1010_????: state <= S_EXEC;

                8'b1011_????: begin
                    ea <= {3'b000, mem_rd_data};
                    if (opcode[3:0] == 4'hC) begin
                        reg_pc <= {3'b000, mem_rd_data};
                        mem_addr <= {3'b000, mem_rd_data};
                        if (int_ext_pending) begin
                            int_type <= 2'd0;
                            state <= S_INT_P1;
                        end else if (int_timer_pending) begin
                            int_type <= 2'd1;
                            state <= S_INT_P1;
                        end else
                            state <= S_FETCH;
                    end else if (opcode[3:0] == 4'hD) begin
                        ea <= {3'b000, mem_rd_data};
                        state <= S_JSR_P1;
                    end else if (opcode[3:0] == 4'h7 || opcode[3:0] == 4'hF) begin
                        // STA/STX DIR — 4 cycles: write, then finish
                        wr_addr <= {3'b000, mem_rd_data};
                        mem_wdata <= (opcode[3:0] == 4'hF) ? reg_x : reg_a;
                        mem_we <= 1'b1;
                        state <= S_DIR_WR2;
                    end else begin
                        mem_addr <= {3'b000, mem_rd_data};
                        state <= S_MEM_RD;
                    end
                end

                8'b1100_????: begin
                    mem_addr <= reg_pc + 11'd1;
                    state <= S_OP2;
                end

                8'b1101_????: begin
                    mem_addr <= reg_pc + 11'd1;
                    state <= S_OP2;
                end

                8'b1110_????: state <= S_IX1_CALC;

                default: state <= S_EXEC;
            endcase
        end

        //=====================================================================
        // S_OP2
        //=====================================================================
        S_OP2: begin
            op2 <= mem_rd_data;
            reg_pc <= reg_pc + 11'd1;

            casez (opcode)
                8'b1100_????: begin
                    ea <= {op1[2:0], mem_rd_data};
                    if (opcode[3:0] == 4'hC) begin
                        reg_pc <= {op1[2:0], mem_rd_data};
                        mem_addr <= {op1[2:0], mem_rd_data};
                        if (int_ext_pending) begin
                            int_type <= 2'd0;
                            state <= S_INT_P1;
                        end else if (int_timer_pending) begin
                            int_type <= 2'd1;
                            state <= S_INT_P1;
                        end else
                            state <= S_FETCH;
                    end else if (opcode[3:0] == 4'hD) begin
                        ea <= {op1[2:0], mem_rd_data};
                        state <= S_JSR_P1;
                    end else if (opcode[3:0] == 4'h7 || opcode[3:0] == 4'hF) begin
                        // STA/STX EXT — 5 cycles
                        wr_addr <= {op1[2:0], mem_rd_data};
                        mem_wdata <= (opcode[3:0] == 4'hF) ? reg_x : reg_a;
                        mem_we <= 1'b1;
                        state <= S_DIR_WR2;
                    end else begin
                        mem_addr <= {op1[2:0], mem_rd_data};
                        state <= S_MEM_RD;
                    end
                end

                8'b1101_????: state <= S_IX2_CALC;

                default: state <= S_EXEC;
            endcase
        end

        //=====================================================================
        // S_IX_SETUP — Indexed no-offset setup cycle
        //=====================================================================
        S_IX_SETUP: begin
            casez (opcode)
                8'b0111_????: begin
                    state <= S_RMW_RD;
                end
                8'b1111_????: begin
                    if (opcode[3:0] == 4'h7 || opcode[3:0] == 4'hF) begin
                        wr_addr <= ea;
                        mem_wdata <= (opcode[3:0] == 4'hF) ? reg_x : reg_a;
                        mem_we <= 1'b1;
                        state <= S_DIR_WR2;
                    end else
                        state <= S_EXEC;
                end
                default: state <= S_EXEC;
            endcase
        end

        //=====================================================================
        // S_IX1_CALC — Compute EA = X + op1
        //=====================================================================
        S_IX1_CALC: begin
            ea <= ({3'b000, reg_x} + {3'b000, op1}) & 11'h7FF;
            mem_addr <= ({3'b000, reg_x} + {3'b000, op1}) & 11'h7FF;

            casez (opcode)
                8'b0110_????: begin
                    state <= S_RMW_RD;
                end
                8'b1110_????: begin
                    if (opcode[3:0] == 4'hC) begin
                        reg_pc <= ({3'b000, reg_x} + {3'b000, op1}) & 11'h7FF;
                        mem_addr <= ({3'b000, reg_x} + {3'b000, op1}) & 11'h7FF;
                        if (int_ext_pending) begin
                            int_type <= 2'd0;
                            state <= S_INT_P1;
                        end else if (int_timer_pending) begin
                            int_type <= 2'd1;
                            state <= S_INT_P1;
                        end else
                            state <= S_FETCH;
                    end else if (opcode[3:0] == 4'hD) begin
                        ea <= ({3'b000, reg_x} + {3'b000, op1}) & 11'h7FF;
                        state <= S_JSR_P1;
                    end else if (opcode[3:0] == 4'h7 || opcode[3:0] == 4'hF) begin
                        // STA/STX IX1 — 5 cycles
                        wr_addr <= ({3'b000, reg_x} + {3'b000, op1}) & 11'h7FF;
                        mem_wdata <= (opcode[3:0] == 4'hF) ? reg_x : reg_a;
                        mem_we <= 1'b1;
                        state <= S_DIR_WR2;
                    end else begin
                        state <= S_MEM_RD;
                    end
                end
                default: state <= S_EXEC;
            endcase
        end

        //=====================================================================
        // S_IX2_CALC — Compute EA = X + {op1, op2}
        //=====================================================================
        S_IX2_CALC: begin
            ea <= ({3'b000, reg_x} + {op1[2:0], op2}) & 11'h7FF;
            mem_addr <= ({3'b000, reg_x} + {op1[2:0], op2}) & 11'h7FF;

            if (opcode[3:0] == 4'hC) begin
                reg_pc <= ({3'b000, reg_x} + {op1[2:0], op2}) & 11'h7FF;
                if (int_ext_pending) begin
                    int_type <= 2'd0;
                    state <= S_INT_P1;
                end else if (int_timer_pending) begin
                    int_type <= 2'd1;
                    state <= S_INT_P1;
                end else
                    state <= S_FETCH;
            end else if (opcode[3:0] == 4'hD) begin
                ea <= ({3'b000, reg_x} + {op1[2:0], op2}) & 11'h7FF;
                state <= S_JSR_P1;
            end else if (opcode[3:0] == 4'h7 || opcode[3:0] == 4'hF) begin
                // STA/STX IX2 — 6 cycles
                wr_addr <= ({3'b000, reg_x} + {op1[2:0], op2}) & 11'h7FF;
                mem_wdata <= (opcode[3:0] == 4'hF) ? reg_x : reg_a;
                mem_we <= 1'b1;
                state <= S_DIR_WR2;
            end else begin
                state <= S_MEM_RD;
            end
        end

        //=====================================================================
        // S_MEM_RD
        //=====================================================================
        S_MEM_RD: begin
            mem_data <= mem_rd_data;
            state <= S_EXEC;
        end

        //=====================================================================
        // S_DIR_WR2 — Last cycle of store instructions
        //=====================================================================
        S_DIR_WR2: begin
            if (opcode[3:0] == 4'hF) begin
                reg_ccr[1] <= (reg_x == 8'd0);
                reg_ccr[2] <= reg_x[7];
            end else begin
                reg_ccr[1] <= (reg_a == 8'd0);
                reg_ccr[2] <= reg_a[7];
            end
            mem_addr <= reg_pc;
            if (int_ext_pending) begin
                int_type <= 2'd0;
                state <= S_INT_P1;
            end else if (int_timer_pending) begin
                int_type <= 2'd1;
                state <= S_INT_P1;
            end else
                state <= S_FETCH;
        end

        //=====================================================================
        // RMW sequence
        //=====================================================================
        S_RMW_RD: begin
            rmw_data <= mem_rd_data;
            state <= S_RMW_CALC;
        end

        S_RMW_CALC: begin
            tmp_r = rmw_data;
            tmp_co = reg_ccr[0];

            casez (opcode)
                8'b0001_???0: tmp_r = rmw_data | (8'd1 << opcode[3:1]);
                8'b0001_???1: tmp_r = rmw_data & ~(8'd1 << opcode[3:1]);
                default: begin
                    case (opcode[3:0])
                        4'h0: begin tmp_r = 8'd0 - rmw_data; tmp_co = (rmw_data != 8'd0); end
                        4'h3: begin tmp_r = ~rmw_data; tmp_co = 1'b1; end
                        4'h4: begin tmp_co = rmw_data[0]; tmp_r = {1'b0, rmw_data[7:1]}; end
                        4'h6: begin tmp_co = rmw_data[0]; tmp_r = {reg_ccr[0], rmw_data[7:1]}; end
                        4'h7: begin tmp_co = rmw_data[0]; tmp_r = {rmw_data[7], rmw_data[7:1]}; end
                        4'h8: begin tmp_co = rmw_data[7]; tmp_r = {rmw_data[6:0], 1'b0}; end
                        4'h9: begin tmp_co = rmw_data[7]; tmp_r = {rmw_data[6:0], reg_ccr[0]}; end
                        4'hA: tmp_r = rmw_data - 8'd1;
                        4'hC: tmp_r = rmw_data + 8'd1;
                        4'hD: tmp_r = rmw_data;
                        4'hF: tmp_r = 8'd0;
                        default: ;
                    endcase
                end
            endcase

            casez (opcode)
                8'b0001_????: ;
                default: begin
                    case (opcode[3:0])
                        4'h0, 4'h3, 4'h4, 4'h6, 4'h7, 4'h8, 4'h9:
                            reg_ccr[0] <= tmp_co;
                        default: ;
                    endcase
                    reg_ccr[1] <= (tmp_r == 8'd0);
                    reg_ccr[2] <= tmp_r[7];
                end
            endcase

            // TST: no write-back
            if (opcode[3:0] == 4'hD && opcode[7:4] != 4'h1) begin
                mem_addr <= reg_pc;
                if (int_ext_pending) begin
                    int_type <= 2'd0;
                    state <= S_INT_P1;
                end else if (int_timer_pending) begin
                    int_type <= 2'd1;
                    state <= S_INT_P1;
                end else
                    state <= S_FETCH;
            end else begin
                wr_addr <= ea;
                mem_wdata <= tmp_r;
                mem_we <= 1'b1;
                state <= S_RMW_WR;
            end
        end

        S_RMW_WR: begin
            mem_addr <= reg_pc;
            if (int_ext_pending) begin
                int_type <= 2'd0;
                state <= S_INT_P1;
            end else if (int_timer_pending) begin
                int_type <= 2'd1;
                state <= S_INT_P1;
            end else
                state <= S_FETCH;
        end

        //=====================================================================
        // Bit test and branch
        //=====================================================================
        S_BTB_OFF: begin
            op2 <= mem_rd_data;
            reg_pc <= reg_pc + 11'd1;
            ea <= {3'b000, op1};
            mem_addr <= {3'b000, op1};
            state <= S_BTB_RD;
        end

        S_BTB_RD: begin
            rmw_data <= mem_rd_data;
            state <= S_BTB_EX;
        end

        S_BTB_EX: begin
            tmp_mask = 8'd1 << opcode[3:1];
            if (opcode[0])
                tmp_take = (rmw_data & tmp_mask) == 8'd0;
            else
                tmp_take = (rmw_data & tmp_mask) != 8'd0;

            reg_ccr[0] <= (rmw_data & tmp_mask) != 8'd0;

            if (tmp_take) begin
                if (op2[7]) begin
                    reg_pc <= reg_pc - {3'b000, (~op2 + 8'd1)};
                    mem_addr <= reg_pc - {3'b000, (~op2 + 8'd1)};
                end else begin
                    reg_pc <= reg_pc + {3'b000, op2};
                    mem_addr <= reg_pc + {3'b000, op2};
                end
            end else begin
                mem_addr <= reg_pc;
            end

            if (int_ext_pending) begin
                int_type <= 2'd0;
                state <= S_INT_P1;
            end else if (int_timer_pending) begin
                int_type <= 2'd1;
                state <= S_INT_P1;
            end else
                state <= S_FETCH;
        end

        //=====================================================================
        // BSR: Compute target address
        //=====================================================================
        S_BSR_CALC: begin
            if (op1[7])
                ea <= reg_pc - {3'b000, (~op1 + 8'd1)};
            else
                ea <= reg_pc + {3'b000, op1};
            state <= S_JSR_P1;
        end

        //=====================================================================
        // S_WAIT — Burn cycles then proceed
        //=====================================================================
        S_WAIT: begin
            if (wait_count > 4'd0) begin
                wait_count <= wait_count - 4'd1;
            end else begin
                casez (opcode)
                    8'b0100_????, 8'b0101_????: state <= S_EXEC;
                    8'h80: begin
                        reg_sp <= reg_sp + 7'd1;
                        mem_addr <= {4'b0000, reg_sp + 7'd1};
                        state <= S_RTI_1;
                    end
                    8'h81: begin
                        reg_sp <= reg_sp + 7'd1;
                        mem_addr <= {4'b0000, reg_sp + 7'd1};
                        state <= S_RTS_1;
                    end
                    default: state <= S_EXEC;
                endcase
            end
        end

        //=====================================================================
        // MUL — 11 cycles total
        //=====================================================================
        S_MUL_EXEC: begin
            if (wait_count > 4'd1) begin
                wait_count <= wait_count - 4'd1;
            end else begin
                {reg_x, reg_a} <= reg_x * reg_a;
                reg_ccr[4] <= 1'b0;
                reg_ccr[0] <= 1'b0;
                mem_addr <= reg_pc;
                if (int_ext_pending) begin
                    int_type <= 2'd0;
                    state <= S_INT_P1;
                end else if (int_timer_pending) begin
                    int_type <= 2'd1;
                    state <= S_INT_P1;
                end else
                    state <= S_FETCH;
            end
        end

        //=====================================================================
        // S_EXEC — Execute + last cycle of instruction
        //=====================================================================
        // (unchanged from your original except ext_int_ack removal)
        S_EXEC: begin
            mem_addr <= reg_pc;

            casez (opcode)
                //--- Acc inherent ($40-$4F) ---
                8'b0100_????: begin
                    tmp_r = reg_a;
                    tmp_co = reg_ccr[0];
                    case (opcode[3:0])
                        4'h0: begin tmp_r = 8'd0 - reg_a; tmp_co = (reg_a != 8'd0); end
                        4'h3: begin tmp_r = ~reg_a; tmp_co = 1'b1; end
                        4'h4: begin tmp_co = reg_a[0]; tmp_r = {1'b0, reg_a[7:1]}; end
                        4'h6: begin tmp_co = reg_a[0]; tmp_r = {reg_ccr[0], reg_a[7:1]}; end
                        4'h7: begin tmp_co = reg_a[0]; tmp_r = {reg_a[7], reg_a[7:1]}; end
                        4'h8: begin tmp_co = reg_a[7]; tmp_r = {reg_a[6:0], 1'b0}; end
                        4'h9: begin tmp_co = reg_a[7]; tmp_r = {reg_a[6:0], reg_ccr[0]}; end
                        4'hA: tmp_r = reg_a - 8'd1;
                        4'hC: tmp_r = reg_a + 8'd1;
                        4'hD: tmp_r = reg_a;
                        4'hF: tmp_r = 8'd0;
                        default: ;
                    endcase
                    case (opcode[3:0])
                        4'h0, 4'h3, 4'h4, 4'h6, 4'h7, 4'h8, 4'h9: reg_ccr[0] <= tmp_co;
                        default: ;
                    endcase
                    reg_ccr[1] <= (tmp_r == 8'd0);
                    reg_ccr[2] <= tmp_r[7];
                    if (opcode[3:0] != 4'hD) reg_a <= tmp_r;
                end

                //--- X reg inherent ($50-$5F) ---
                8'b0101_????: begin
                    tmp_r = reg_x;
                    tmp_co = reg_ccr[0];
                    case (opcode[3:0])
                        4'h0: begin tmp_r = 8'd0 - reg_x; tmp_co = (reg_x != 8'd0); end
                        4'h3: begin tmp_r = ~reg_x; tmp_co = 1'b1; end
                        4'h4: begin tmp_co = reg_x[0]; tmp_r = {1'b0, reg_x[7:1]}; end
                        4'h6: begin tmp_co = reg_x[0]; tmp_r = {reg_ccr[0], reg_x[7:1]}; end
                        4'h7: begin tmp_co = reg_x[0]; tmp_r = {reg_x[7], reg_x[7:1]}; end
                        4'h8: begin tmp_co = reg_x[7]; tmp_r = {reg_x[6:0], 1'b0}; end
                        4'h9: begin tmp_co = reg_x[7]; tmp_r = {reg_x[6:0], reg_ccr[0]}; end
                        4'hA: tmp_r = reg_x - 8'd1;
                        4'hC: tmp_r = reg_x + 8'd1;
                        4'hD: tmp_r = reg_x;
                        4'hF: tmp_r = 8'd0;
                        default: ;
                    endcase
                    case (opcode[3:0])
                        4'h0, 4'h3, 4'h4, 4'h6, 4'h7, 4'h8, 4'h9: reg_ccr[0] <= tmp_co;
                        default: ;
                    endcase
                    reg_ccr[1] <= (tmp_r == 8'd0);
                    reg_ccr[2] <= tmp_r[7];
                    if (opcode[3:0] != 4'hD) reg_x <= tmp_r;
                end

                //--- Control inherent ($90-$9F) ---
                8'b1001_????: begin
                    case (opcode[3:0])
                        4'h7: reg_x <= reg_a;
                        4'h8: reg_ccr[0] <= 1'b0;
                        4'h9: reg_ccr[0] <= 1'b1;
                        4'hA: reg_ccr[3] <= 1'b0;
                        4'hB: reg_ccr[3] <= 1'b1;
                        4'hC: reg_sp <= 7'h7F;
                        4'hD: ;
                        4'hF: reg_a <= reg_x;
                        default: ;
                    endcase
                end

                //--- STOP/WAIT ---
                8'h8E: reg_ccr[3] <= 1'b0;
                8'h8F: reg_ccr[3] <= 1'b0;

                //--- Branches ($20-$2F) ---
                8'b0010_????: begin
                    case (opcode[3:0])
                        4'h0: tmp_take = 1'b1;
                        4'h1: tmp_take = 1'b0;
                        4'h2: tmp_take = ~reg_ccr[0] & ~reg_ccr[1];
                        4'h3: tmp_take = reg_ccr[0] | reg_ccr[1];
                        4'h4: tmp_take = ~reg_ccr[0];
                        4'h5: tmp_take = reg_ccr[0];
                        4'h6: tmp_take = ~reg_ccr[1];
                        4'h7: tmp_take = reg_ccr[1];
                        4'h8: tmp_take = ~reg_ccr[4];
                        4'h9: tmp_take = reg_ccr[4];
                        4'hA: tmp_take = ~reg_ccr[2];
                        4'hB: tmp_take = reg_ccr[2];
                        4'hC: tmp_take = ~reg_ccr[3];
                        4'hD: tmp_take = reg_ccr[3];
                        4'hE: tmp_take = ~int_pin_n;
                        4'hF: tmp_take = int_pin_n;
                        default: tmp_take = 1'b0;
                    endcase
                    if (tmp_take) begin
                        if (op1[7]) begin
                            reg_pc <= reg_pc - {3'b000, (~op1 + 8'd1)};
                            mem_addr <= reg_pc - {3'b000, (~op1 + 8'd1)};
                        end else begin
                            reg_pc <= reg_pc + {3'b000, op1};
                            mem_addr <= reg_pc + {3'b000, op1};
                        end
                    end
                end

                //--- Immediate ALU ($A0-$AF) ---
                8'b1010_????: begin
                    case (opcode[3:0])
                        4'h0: begin
                            tmp_res9 = {1'b0, reg_a} - {1'b0, op1};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h1: begin
                            tmp_res9 = {1'b0, reg_a} - {1'b0, op1};
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h2: begin
                            tmp_res9 = {1'b0, reg_a} - {1'b0, op1} - {8'd0, reg_ccr[0]};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h3: begin
                            tmp_res9 = {1'b0, reg_x} - {1'b0, op1};
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h4: begin
                            reg_a <= reg_a & op1;
                            reg_ccr[1] <= ((reg_a & op1)==8'd0); reg_ccr[2] <= (reg_a & op1) >> 7;
                        end
                        4'h5: begin
                            reg_ccr[1] <= ((reg_a & op1)==8'd0); reg_ccr[2] <= (reg_a & op1) >> 7;
                        end
                        4'h6: begin
                            reg_a <= op1;
                            reg_ccr[1] <= (op1==8'd0); reg_ccr[2] <= op1[7];
                        end
                        4'h8: begin
                            reg_a <= reg_a ^ op1;
                            reg_ccr[1] <= ((reg_a ^ op1)==8'd0); reg_ccr[2] <= (reg_a ^ op1) >> 7;
                        end
                        4'h9: begin
                            tmp_res9 = {1'b0, reg_a} + {1'b0, op1} + {8'd0, reg_ccr[0]};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                            reg_ccr[4] <= ((reg_a[3:0] + op1[3:0] + {3'b0, reg_ccr[0]}) > 5'd15);
                        end
                        4'hA: begin
                            reg_a <= reg_a | op1;
                            reg_ccr[1] <= ((reg_a | op1)==8'd0); reg_ccr[2] <= (reg_a | op1) >> 7;
                        end
                        4'hB: begin
                            tmp_res9 = {1'b0, reg_a} + {1'b0, op1};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                            reg_ccr[4] <= ((reg_a[3:0] + op1[3:0]) > 5'd15);
                        end
                        4'hE: begin
                            reg_x <= op1;
                            reg_ccr[1] <= (op1==8'd0); reg_ccr[2] <= op1[7];
                        end
                        default: ;
                    endcase
                end

                //--- Memory ALU ($B0-$FF, read ops) ---
                8'b1011_????, 8'b1100_????, 8'b1101_????,
                8'b1110_????, 8'b1111_????: begin
                    case (opcode[3:0])
                        4'h0: begin
                            tmp_res9 = {1'b0, reg_a} - {1'b0, mem_data};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h1: begin
                            tmp_res9 = {1'b0, reg_a} - {1'b0, mem_data};
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h2: begin
                            tmp_res9 = {1'b0, reg_a} - {1'b0, mem_data} - {8'd0, reg_ccr[0]};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h3: begin
                            tmp_res9 = {1'b0, reg_x} - {1'b0, mem_data};
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                        end
                        4'h4: begin
                            reg_a <= reg_a & mem_data;
                            reg_ccr[1] <= ((reg_a & mem_data)==8'd0); reg_ccr[2] <= (reg_a & mem_data) >> 7;
                        end
                        4'h5: begin
                            reg_ccr[1] <= ((reg_a & mem_data)==8'd0); reg_ccr[2] <= (reg_a & mem_data) >> 7;
                        end
                        4'h6: begin
                            reg_a <= mem_data;
                            reg_ccr[1] <= (mem_data==8'd0); reg_ccr[2] <= mem_data[7];
                        end
                        4'h7: begin
                            reg_ccr[1] <= (reg_a==8'd0); reg_ccr[2] <= reg_a[7];
                        end
                        4'h8: begin
                            reg_a <= reg_a ^ mem_data;
                            reg_ccr[1] <= ((reg_a ^ mem_data)==8'd0); reg_ccr[2] <= (reg_a ^ mem_data) >> 7;
                        end
                        4'h9: begin
                            tmp_res9 = {1'b0, reg_a} + {1'b0, mem_data} + {8'd0, reg_ccr[0]};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                            reg_ccr[4] <= ((reg_a[3:0] + mem_data[3:0] + {3'b0, reg_ccr[0]}) > 5'd15);
                        end
                        4'hA: begin
                            reg_a <= reg_a | mem_data;
                            reg_ccr[1] <= ((reg_a | mem_data)==8'd0); reg_ccr[2] <= (reg_a | mem_data) >> 7;
                        end
                        4'hB: begin
                            tmp_res9 = {1'b0, reg_a} + {1'b0, mem_data};
                            reg_a <= tmp_res9[7:0];
                            reg_ccr[0] <= tmp_res9[8]; reg_ccr[1] <= (tmp_res9[7:0]==8'd0); reg_ccr[2] <= tmp_res9[7];
                            reg_ccr[4] <= ((reg_a[3:0] + mem_data[3:0]) > 5'd15);
                        end
                        4'hE: begin
                            reg_x <= mem_data;
                            reg_ccr[1] <= (mem_data==8'd0); reg_ccr[2] <= mem_data[7];
                        end
                        4'hF: begin
                            reg_ccr[1] <= (reg_x==8'd0); reg_ccr[2] <= reg_x[7];
                        end
                        default: ;
                    endcase
                end

                default: ;
            endcase

            // Last cycle: check interrupts
            if (int_ext_pending) begin
                int_type <= 2'd0;
                state <= S_INT_P1;
            end else if (int_timer_pending) begin
                int_type <= 2'd1;
                state <= S_INT_P1;
            end else
                state <= S_FETCH;
        end

        //=====================================================================
        // JSR/BSR PUSH SEQUENCE
        //=====================================================================
        S_JSR_P1: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= reg_pc[7:0];
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            state <= S_JSR_P2;
        end

        S_JSR_P2: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= {5'b00000, reg_pc[10:8]};
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            reg_pc <= ea;
            mem_addr <= ea;
            if (int_ext_pending) begin
                int_type <= 2'd0;
                state <= S_INT_P1;
            end else if (int_timer_pending) begin
                int_type <= 2'd1;
                state <= S_INT_P1;
            end else
                state <= S_FETCH;
        end

        //=====================================================================
        // SWI SETUP
        //=====================================================================
        S_SWI_SETUP: begin
            state <= S_INT_P1;
        end

        //=====================================================================
        // INTERRUPT PUSH SEQUENCE
        //=====================================================================
        S_INT_P1: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= reg_pc[7:0];
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            state <= S_INT_P2;
        end

        S_INT_P2: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= {5'b00000, reg_pc[10:8]};
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            state <= S_INT_P3;
        end

        S_INT_P3: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= reg_x;
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            state <= S_INT_P4;
        end

        S_INT_P4: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= reg_a;
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            state <= S_INT_P5;
        end

        S_INT_P5: begin
            wr_addr <= {4'b0000, reg_sp};
            mem_wdata <= {3'b111, reg_ccr};
            mem_we <= 1'b1;
            reg_sp <= reg_sp - 7'd1;
            reg_ccr[3] <= 1'b1;
            state <= S_INT_VEC;
        end

        //=====================================================================
        // INTERRUPT VECTOR LOAD
        //=====================================================================
        S_INT_VEC: begin
            case (int_type)
                2'd0: mem_addr <= 11'h7FA; // ext int
                2'd1: mem_addr <= 11'h7F8; // timer
                2'd2: mem_addr <= 11'h7FC; // SWI
                default: mem_addr <= 11'h7FE;
            endcase
            state <= S_VEC_HI;
        end

        //=====================================================================
        // RTI — 9 cycles
        //=====================================================================
        S_RTI_1: begin
            reg_ccr <= mem_rd_data[4:0];
            reg_sp <= reg_sp + 7'd1;
            mem_addr <= {4'b0000, reg_sp + 7'd1};
            state <= S_RTI_2;
        end

        S_RTI_2: begin
            reg_a <= mem_rd_data;
            reg_sp <= reg_sp + 7'd1;
            mem_addr <= {4'b0000, reg_sp + 7'd1};
            state <= S_RTI_3;
        end

        S_RTI_3: begin
            reg_x <= mem_rd_data;
            reg_sp <= reg_sp + 7'd1;
            mem_addr <= {4'b0000, reg_sp + 7'd1};
            state <= S_RTI_4;
        end

        S_RTI_4: begin
            reg_pc[10:8] <= mem_rd_data[2:0];
            reg_sp <= reg_sp + 7'd1;
            mem_addr <= {4'b0000, reg_sp + 7'd1};
            state <= S_RTS_2;
        end

        //=====================================================================
        // RTS — 6 cycles
        //=====================================================================
        S_RTS_1: begin
            reg_pc[10:8] <= mem_rd_data[2:0];
            reg_sp <= reg_sp + 7'd1;
            mem_addr <= {4'b0000, reg_sp + 7'd1};
            state <= S_RTS_2;
        end

        S_RTS_2: begin
            reg_pc[7:0] <= mem_rd_data;
            state <= S_RTS_3;
        end

        S_RTS_3: begin
            mem_addr <= reg_pc;
            if (int_ext_pending) begin
                int_type <= 2'd0;
                state <= S_INT_P1;
            end else if (int_timer_pending) begin
                int_type <= 2'd1;
                state <= S_INT_P1;
            end else
                state <= S_FETCH;
        end

        default: state <= S_RESET;

        endcase
    end
end

endmodule
