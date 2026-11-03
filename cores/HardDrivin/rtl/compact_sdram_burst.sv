// Four-word burst SDRAM controller for Compact VRAM.
//
// Derived from the GPL-3.0 MiST/MiSTer controllers already reused by this
// project (Till Harbaum/Sorgelig). It retains their 100 MHz timing model,
// refresh interval, CAS latency, and auto-precharge policy, while exposing an
// explicit four-word read transaction interface.

`default_nettype none

module compact_sdram_burst #(parameter bit STUNRUN_TIMING = 0) (
  input  logic        init_i,
  input  logic        clk_i,
  input  logic        sample_clk_i,
  input  logic        dq_stage_clk_i,     // Stun Runner: capture edge of the first read-data stage
  input  logic        sdram_clk_i,

  inout  wire  [15:0] SDRAM_DQ,
  output wire  [12:0] SDRAM_A,
  output logic        SDRAM_DQML,
  output logic        SDRAM_DQMH,
  output wire  [1:0]  SDRAM_BA,
  output logic        SDRAM_nCS,
  output logic        SDRAM_nWE,
  output logic        SDRAM_nRAS,
  output logic        SDRAM_nCAS,
  output logic        SDRAM_CKE,
  output logic        SDRAM_CLK,

  input  logic        req_i,
  input  logic        we_i,
  input  logic [23:0] addr_i,
  input  logic [63:0] wdata_i,     // four words: a write is one BL=4 burst at the aligned column
  input  logic [7:0]  be_i,        // byte enables per word (word k: be_i[2k+1:2k]); masked beats use DQM
  output logic        accept_o,
  output logic        initialized_o,
  output logic        done_o,
  output logic [63:0] rdata_o
);
  localparam logic [2:0] CMD_NOP          = 3'b111;
  localparam logic [2:0] CMD_ACTIVE       = 3'b011;
  localparam logic [2:0] CMD_READ         = 3'b101;
  localparam logic [2:0] CMD_WRITE        = 3'b100;
  localparam logic [2:0] CMD_PRECHARGE    = 3'b010;
  localparam logic [2:0] CMD_AUTO_REFRESH = 3'b001;
  localparam logic [2:0] CMD_LOAD_MODE    = 3'b000;

  // BL=4, sequential, CAS=2, burst writes (four data beats, DQM per beat).
  localparam logic [12:0] MODE = {3'b000, 1'b0, 2'b00, 3'd2, 1'b0, 3'b010};
  localparam integer STARTUP_PRECHARGE = 12000;
  localparam integer STARTUP_REFRESH_1 = 12008;
  localparam integer STARTUP_REFRESH_2 = 12016;
  localparam integer STARTUP_MODE       = 12024;
  localparam integer STARTUP_DONE       = 12032;
  localparam integer REFRESH_CYCLES     = 780;

  typedef enum logic [4:0] {
    STARTUP,
    IDLE,
    ACTIVE_WAIT,
    ACTIVE_WAIT_2,
    ISSUE_COLUMN,
    READ_WAIT_1,
    READ_WAIT_2,
    READ_WAIT_3,
    READ_WAIT_4,
    READ_BEAT_0,
    READ_BEAT_1,
    READ_BEAT_2,
    READ_BEAT_3,
    WRITE_BEAT_1,
    WRITE_BEAT_2,
    WRITE_BEAT_3,
    WRITE_RECOVER,
    REFRESH_ISSUE,
    REFRESH_RECOVER
  } state_t;

  state_t state;
  logic [2:0] command;
  logic [2:0] command_stun_q;
  logic [2:0] stun_cmd_q;
  logic [2:0] command_o;
  logic [13:0] startup_count;
  logic [13:0] refresh_count;
  logic [3:0] recover_count;
  logic saved_we;
  logic [23:0] saved_addr;
  logic [63:0] saved_wdata;
  logic [7:0] saved_be;
  logic [7:0] saved_be_n;
  logic [15:0] dq_sample;
  (* preserve *) logic [15:0] dq_sample_local_q;
  (* preserve *) logic [15:0] dq_sample_local2_q;
  logic [15:0] dq_read_sample;
  logic [15:0] dq_out;
  (* preserve *) logic [15:0] dq_oe;
  logic [15:0] dq_preload_q;
  logic dq_oe_preload_q;
  logic [12:0] sdram_a_legacy_q;
  logic [1:0]  sdram_ba_legacy_q;
  logic [12:0] sdram_a_stun_q;
  logic [1:0]  sdram_ba_stun_q;
  logic [12:0] sdram_a_stun_pre_q;
  logic [1:0]  sdram_ba_stun_pre_q;
  logic [12:0] sdram_a_o;
  logic [1:0]  sdram_ba_o;

  assign sdram_a_o = STUNRUN_TIMING ? sdram_a_stun_q : sdram_a_legacy_q;
  assign sdram_ba_o = STUNRUN_TIMING ? sdram_ba_stun_q : sdram_ba_legacy_q;
  assign SDRAM_A = sdram_a_o;
  assign SDRAM_BA = sdram_ba_o;
  assign SDRAM_CKE  = 1'b1;
  assign SDRAM_nCS  = 1'b0;
  assign SDRAM_nRAS = command_o[2];
  assign SDRAM_nCAS = command_o[1];
  assign SDRAM_nWE  = command_o[0];
  assign SDRAM_DQMH = sdram_a_o[12];
  assign SDRAM_DQML = sdram_a_o[11];
  genvar dq_bit;
  generate
    for (dq_bit = 0; dq_bit < 16; dq_bit = dq_bit + 1) begin : g_sdram_dq_oe
    assign SDRAM_DQ[dq_bit] = dq_oe[dq_bit] ? dq_out[dq_bit] : 1'bz;
    end
  endgenerate

  // Capture DQ in the per-pin I/O cells. The low-edge output is intentionally
  // unused; only the late high-edge sample enters the controller datapath.
`ifdef TMS34010_QUARTUS
  altddio_in #(
    .intended_device_family("Cyclone V"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_in"),
    .power_up_high("OFF"),
    .width(16)
  ) sdram_dq_ddr (
    .datain(SDRAM_DQ),
    .inclock(sample_clk_i),
    .inclocken(1'b1),
    .dataout_h(dq_sample),
    .dataout_l(),
    .aclr(1'b0),
    .aset(1'b0),
    .sclr(1'b0),
    .sset(1'b0)
  );
`else
  always_ff @(posedge sample_clk_i)
    dq_sample <= SDRAM_DQ;
`endif

  // Stun Runner hands the late DQ sample to the controller in two falling-edge
  // stages. The DQ pins (and their input cells) sit on several die edges; the
  // first stage stays next to the pins and the second next to the read-data
  // registers, so neither hop has to cross the die inside a fixed budget.
  // The first stage (2500 ps) precedes the sample edge (2813 ps), so STA
  // times sample -> stage as a 9.687 ns path: each stage edge takes the
  // previous cycle's sample. The read FSM's wait-state count depends on this.
  generate
    if (STUNRUN_TIMING) begin : g_STUNRUN_TIMING
      always_ff @(posedge dq_stage_clk_i)
        dq_sample_local_q <= dq_sample;
      always_ff @(negedge clk_i)
        dq_sample_local2_q <= dq_sample_local_q;
      assign dq_read_sample = dq_sample_local2_q;
    end else begin : g_direct_dq_capture
      assign dq_read_sample = dq_sample;
    end
  endgenerate

  // Forward the SDRAM clock through a dedicated DDIO output cell rather than
  // routing the clock net into the pad through the fabric: the fabric route
  // was ~5 ns with a >2 ns min/max spread, which consumed the SDRAM interface
  // timing window. The cell sits at the pin like the address/command
  // registers, so launch and forwarded clock share a common tree.
`ifdef TMS34010_QUARTUS
  altddio_out #(
    .extend_oe_disable("OFF"),
    .intended_device_family("Cyclone V"),
    .invert_output("OFF"),
    .lpm_hint("UNUSED"),
    .lpm_type("altddio_out"),
    .oe_reg("UNREGISTERED"),
    .power_up_high("OFF"),
    .width(1)
  ) sdram_clk_ddio (
    .datain_h(1'b1),
    .datain_l(1'b0),
    .outclock(sdram_clk_i),
    .dataout(SDRAM_CLK),
    .aclr(1'b0),
    .aset(1'b0),
    .oe(1'b1),
    .oe_out(),
    .outclocken(1'b1),
    .sclr(1'b0),
    .sset(1'b0)
  );
`else
  assign SDRAM_CLK = sdram_clk_i;
`endif

  // Stun Runner's write data is preloaded on the late sample-clock rising
  // edge, then driven by an output register on the controller falling edge.
  // This gives the core-to-I/O handoff most of a cycle and moves DQ after the
  // SDRAM sampling edge to satisfy its output hold requirement. Commands are
  // registered before the forwarded SDRAM edge, with ACTIVE issued only after
  // the controller has accepted and captured the complete request.
  generate
    if (STUNRUN_TIMING) begin : g_stunrun_sdram_outputs
      always_ff @(negedge clk_i) begin
        dq_out <= dq_preload_q;
        dq_oe <= {16{dq_oe_preload_q}};
      end

      // The request is stable before the accepting controller edge. Sampling
      // the selected beat on sample_clk_i's rising edge leaves a long route
      // window to the controller-falling-edge I/O register.
      always_ff @(posedge sample_clk_i) begin
        if (init_i) begin
          dq_preload_q <= 16'd0;
          dq_oe_preload_q <= 1'b0;
        end else begin
          case (state)
            STARTUP: dq_oe_preload_q <= 1'b0;
            IDLE: begin
              if (refresh_count >= REFRESH_CYCLES) begin
                dq_oe_preload_q <= 1'b0;
              end else if (req_i) begin
                dq_preload_q <= wdata_i[15:0];
                dq_oe_preload_q <= we_i;
              end
            end
            ISSUE_COLUMN: if (saved_we)
              dq_preload_q <= saved_wdata[31:16];
            WRITE_BEAT_1: dq_preload_q <= saved_wdata[47:32];
            WRITE_BEAT_2: dq_preload_q <= saved_wdata[63:48];
            WRITE_BEAT_3: dq_oe_preload_q <= 1'b0;
            REFRESH_RECOVER: dq_oe_preload_q <= 1'b0;
            default: ;
          endcase
        end
      end

      // Prepare the next falling-edge SDRAM address on the rising edge.
      // ACTIVE is issued after the request is accepted, so first stage the
      // row and bank. The next controller edge stages the column and DQM.
      always_ff @(posedge clk_i) begin
        if (init_i) begin
          sdram_a_stun_pre_q <= 13'd0;
          sdram_ba_stun_pre_q <= 2'd0;
        end else begin
          case (state)
            STARTUP: begin
              sdram_a_stun_pre_q <= 13'd0;
              sdram_ba_stun_pre_q <= 2'd0;
              if (startup_count == STARTUP_PRECHARGE - 1)
                sdram_a_stun_pre_q[10] <= 1'b1;
              else if (startup_count == STARTUP_MODE - 1)
                sdram_a_stun_pre_q <= MODE;
            end
            IDLE: begin
              if (req_i) begin
                sdram_a_stun_pre_q <= addr_i[21:9];
                sdram_ba_stun_pre_q <= addr_i[23:22];
              end
            end
            ACTIVE_WAIT: begin
              sdram_a_stun_pre_q <= {
                saved_we ? saved_be_n[1:0] : 2'b00,
                2'b10,
                saved_we ? {saved_addr[8:2], 2'b00} : saved_addr[8:0]
              };
              sdram_ba_stun_pre_q <= saved_addr[23:22];
            end
            ISSUE_COLUMN: if (saved_we)
              sdram_a_stun_pre_q[12:11] <= saved_be_n[3:2];
            WRITE_BEAT_1:
              sdram_a_stun_pre_q[12:11] <= saved_be_n[5:4];
            WRITE_BEAT_2:
              sdram_a_stun_pre_q[12:11] <= saved_be_n[7:6];
            default: ;
          endcase
        end
      end

      // The command is fully decoded by the posedge state machine (stun_cmd_q),
      // so the half-cycle path to the pin register is a plain copy.
      always_ff @(negedge clk_i)
        command_stun_q <= stun_cmd_q;
      assign command_o = command_stun_q;

      always_ff @(negedge clk_i) begin
        // Only the local preload-to-I/O transfer remains on this edge.
        sdram_a_stun_q <= sdram_a_stun_pre_q;
        sdram_ba_stun_q <= sdram_ba_stun_pre_q;
      end
    end else begin : g_legacy_sdram_outputs
      always_ff @(posedge clk_i) begin
        if (init_i) begin
          dq_oe <= 16'd0;
        end else begin
          dq_oe <= 16'd0;
          case (state)
            ISSUE_COLUMN: if (saved_we) begin
              dq_out <= saved_wdata[15:0];
              dq_oe <= 16'hffff;
            end
            WRITE_BEAT_1: begin
              dq_out <= saved_wdata[31:16];
              dq_oe <= 16'hffff;
            end
            WRITE_BEAT_2: begin
              dq_out <= saved_wdata[47:32];
              dq_oe <= 16'hffff;
            end
            WRITE_BEAT_3: begin
              dq_out <= saved_wdata[63:48];
              dq_oe <= 16'hffff;
            end
            default: ;
          endcase
        end
      end
      always_comb begin
        dq_preload_q = 16'd0;
        dq_oe_preload_q = 1'b0;
        sdram_a_stun_q = 13'd0;
        sdram_ba_stun_q = 2'd0;
        sdram_a_stun_pre_q = 13'd0;
        sdram_ba_stun_pre_q = 2'd0;
      end
      assign command_o = command;
    end
  endgenerate

  always_ff @(posedge clk_i) begin
    command <= CMD_NOP;
    if (STUNRUN_TIMING) stun_cmd_q <= CMD_NOP;
    accept_o <= 1'b0;
    done_o <= 1'b0;
    refresh_count <= refresh_count + 14'd1;

    if (init_i) begin
      state <= STARTUP;
      startup_count <= 14'd0;
      refresh_count <= 14'd0;
      command <= CMD_NOP;
      sdram_a_legacy_q <= 13'd0;
      sdram_ba_legacy_q <= 2'd0;
      accept_o <= 1'b0;
      initialized_o <= 1'b0;
      done_o <= 1'b0;
    end else begin
      case (state)
        STARTUP: begin
          startup_count <= startup_count + 14'd1;
          sdram_a_legacy_q <= 13'd0;
          sdram_ba_legacy_q <= 2'd0;
          // Stun Runner issues each startup command one edge later (falling
          // edge), so it is decoded one count early.
          if (STUNRUN_TIMING) begin
            if (startup_count == STARTUP_PRECHARGE - 1)
              stun_cmd_q <= CMD_PRECHARGE;
            else if (startup_count == STARTUP_REFRESH_1 - 1 ||
                     startup_count == STARTUP_REFRESH_2 - 1)
              stun_cmd_q <= CMD_AUTO_REFRESH;
            else if (startup_count == STARTUP_MODE - 1)
              stun_cmd_q <= CMD_LOAD_MODE;
          end
          if (startup_count == STARTUP_PRECHARGE) begin
            command <= CMD_PRECHARGE;
            sdram_a_legacy_q[10] <= 1'b1;
          end else if (startup_count == STARTUP_REFRESH_1 ||
                       startup_count == STARTUP_REFRESH_2) begin
            command <= CMD_AUTO_REFRESH;
          end else if (startup_count == STARTUP_MODE) begin
            command <= CMD_LOAD_MODE;
            sdram_a_legacy_q <= MODE;
          end else if (startup_count == STARTUP_DONE) begin
            state <= IDLE;
            initialized_o <= 1'b1;
            refresh_count <= 14'd0;
          end
        end

        IDLE: begin
          if (refresh_count >= REFRESH_CYCLES) begin
            refresh_count <= 14'd0;
            if (STUNRUN_TIMING) begin
              // The command leaves on the next falling edge (REFRESH_ISSUE),
              // one controller edge later than the legacy registered command.
              recover_count <= 4'd6;
              stun_cmd_q <= CMD_AUTO_REFRESH;
              state <= REFRESH_ISSUE;
            end else begin
              command <= CMD_AUTO_REFRESH;
              recover_count <= 4'd7;
              state <= REFRESH_RECOVER;
            end
          end else if (req_i) begin
            // Acceptance is a pulse, not an idle/ready level. The requester
            // holds req_i through refresh and may release it only after this
            // edge has captured the complete transaction payload.
            accept_o <= 1'b1;
            saved_we <= we_i;
            saved_addr <= addr_i;
            saved_wdata <= wdata_i;
            saved_be <= be_i;
            saved_be_n <= ~be_i;
            command <= CMD_ACTIVE;
            if (STUNRUN_TIMING) stun_cmd_q <= CMD_ACTIVE;
            // Four banks x 8192 rows x 512 16-bit columns.
            sdram_ba_legacy_q <= addr_i[23:22];
            sdram_a_legacy_q <= addr_i[21:9];
            state <= ACTIVE_WAIT;
          end
        end

        ACTIVE_WAIT: begin
          if (STUNRUN_TIMING) state <= ACTIVE_WAIT_2;
          else state <= ISSUE_COLUMN;
        end

        ACTIVE_WAIT_2: begin
          if (saved_we) stun_cmd_q <= CMD_WRITE;
          else          stun_cmd_q <= CMD_READ;
          state <= ISSUE_COLUMN;
        end

        ISSUE_COLUMN: begin
          // A12:A11 are byte masks, A10 requests auto precharge, A9 is
          // unused for a 512-column device, and A8:A0 select the column.
          // A write bursts the four words of the aligned line: the WRITE
          // command carries word 0, the next three edges carry words 1-3
          // with their own DQM (A12:A11) masks.
          sdram_ba_legacy_q <= saved_addr[23:22];
          sdram_a_legacy_q <= {
            saved_we ? ~saved_be[1:0] : 2'b00,
            2'b10,
            saved_we ? {saved_addr[8:2], 2'b00} : saved_addr[8:0]
          };
          if (saved_we) begin
            command <= CMD_WRITE;
            state <= WRITE_BEAT_1;
          end else begin
            command <= CMD_READ;
            state <= READ_WAIT_1;
          end
        end

        // A READ registered at clk_i edge E0 reaches SDRAM at the next rising
        // SDRAM_CLK edge R0. With CAS=2 the device drives beat 0 tAC after
        // R0+1 and holds it until tOH after R0+2 (datasheet CL definition).
        // The late-phase input register samples within the tAC/tOH eye.
        // Three wait states preserve the legacy CAS=2 beat alignment.
        //
        // Stun Runner, in PLL-output time (clk_i rises at 6.563 ns mod 10,
        // its falling edge at 1.563; SDRAM_CLK 9.167; sample 2.813; stage
        // 2.5), using the relationships TimeQuest times each hop with:
        //   ACTIVE_WAIT_2 edge t  -> stun_cmd_q = READ
        //   t+5.0   falling-edge pin register -> SDRAM edge R0 = t+12.604
        //   beat 0 launched by R0+10 (tAC after it), captured by the second
        //   sample edge after it (SDC multicycle 2):      t+36.25
        //   sample -> stage   9.687 ns                     t+45.937
        //   stage  -> local2  9.063 ns                     t+55.0
        //   local2 -> rdata   5.0 ns (READ_BEAT_0 edge)    t+60.0
        // t+60 is the sixth rising edge after ACTIVE_WAIT_2: ISSUE_COLUMN,
        // four wait states, then READ_BEAT_0. Five wait states returned
        // every word one beat late (GSP TIME OUT on hardware).
        READ_WAIT_1: state <= READ_WAIT_2;
        READ_WAIT_2: state <= READ_WAIT_3;
        READ_WAIT_3: begin
          if (STUNRUN_TIMING) state <= READ_WAIT_4;
          else state <= READ_BEAT_0;
        end
        READ_WAIT_4: state <= READ_BEAT_0;
        READ_BEAT_0: begin
          rdata_o[15:0] <= dq_read_sample;
          state <= READ_BEAT_1;
        end
        READ_BEAT_1: begin
          rdata_o[31:16] <= dq_read_sample;
          state <= READ_BEAT_2;
        end
        READ_BEAT_2: begin
          rdata_o[47:32] <= dq_read_sample;
          state <= READ_BEAT_3;
        end
        READ_BEAT_3: begin
          rdata_o[63:48] <= dq_read_sample;
          done_o <= 1'b1;
          state <= IDLE;
        end

        WRITE_BEAT_1: begin
          sdram_a_legacy_q[12:11] <= ~saved_be[3:2];
          state <= WRITE_BEAT_2;
        end
        WRITE_BEAT_2: begin
          sdram_a_legacy_q[12:11] <= ~saved_be[5:4];
          state <= WRITE_BEAT_3;
        end
        WRITE_BEAT_3: begin
          sdram_a_legacy_q[12:11] <= ~saved_be[7:6];
          recover_count <= 4'd3;
          state <= WRITE_RECOVER;
        end

        WRITE_RECOVER: begin
          if (recover_count == 0) begin
            done_o <= 1'b1;
            state <= IDLE;
          end else begin
            recover_count <= recover_count - 4'd1;
          end
        end

        REFRESH_ISSUE: state <= REFRESH_RECOVER;

        REFRESH_RECOVER: begin
          if (recover_count == 0) state <= IDLE;
          else recover_count <= recover_count - 4'd1;
        end

        default: state <= STARTUP;
      endcase
    end
  end

endmodule

`default_nettype wire
