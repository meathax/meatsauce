// AY-3-8913 PSG, written to follow MAME 0.289 ay8910_device (PSG_TYPE_AY, 3 separate
// channel outputs, resistor-divider output table, RL = 1000 ohm) tick for tick.
//
// One `ce` pulse = one MAME stream sample = one chip "clock/8" tick (250 kHz for a 2 MHz
// clock).  Tone, noise and envelope run exactly like sound_stream_update():
//   tone    : count++ ; if (count >= max(1,period)) { count -= period; toggle }
//   noise   : ++cnt >= period(reg6[4:0]) -> cnt=0, prescale^=1, LFSR tick when prescale==0
//   envelope: period*2 ticks per step (m_step = 2 for the AY), 16 steps
// `level` is the signed sum of the three channel levels, already multiplied by MAME's 0.5 route
// gain and scaled so that 1.0 = 32768.  MAME's default AY8910_LEGACY_OUTPUT tables are
// normalised and carry a DC offset (idle = -0.125 per channel); kept on purpose, like MAME.
//
// Register access mirrors ay8910_write_ym(): `wr_addr`=1 latches a register number (ignored
// unless the high nibble is 0), `wr_addr`=0 writes the latched register.
module exterm_ay8913 (
  input  logic        clk,
  input  logic        rst,
  input  logic        ce,        // 250 kHz tick (chip clock / 8)
  input  logic        wr_en,     // one-clk write strobe
  input  logic        wr_addr,   // 1 = register-address port, 0 = data port
  input  logic [7:0]  din,
  output logic signed [15:0] level   // signed sum of the 3 channels (idle = -6144)
);
  // MAME ay8910_device default flags = AY8910_LEGACY_OUTPUT: each channel table is normalised,
  //   tab[j] = ((t[j]-min)/(max-min) - 0.25) * 0.5, t[j] = ladder divider (RL = 1000, ay8910_param),
  // so idle (volume 0) is -0.125 and full volume +0.375 per channel.  Values below are
  // round(tab * 0.5 route gain * 32768).  The envelope table is normalised separately
  // (m_par_env built with zero_is_off = 0), hence the slightly different entries.
  function automatic logic signed [15:0] vol_lut(input logic [3:0] i);
    case (i)
      4'd0:  vol_lut = -16'sd2048; 4'd1:  vol_lut = -16'sd1937;
      4'd2:  vol_lut = -16'sd1903; 4'd3:  vol_lut = -16'sd1859;
      4'd4:  vol_lut = -16'sd1791; 4'd5:  vol_lut = -16'sd1691;
      4'd6:  vol_lut = -16'sd1569; 4'd7:  vol_lut = -16'sd1268;
      4'd8:  vol_lut = -16'sd1086; 4'd9:  vol_lut = -16'sd472;
      4'd10: vol_lut =  16'sd134;  4'd11: vol_lut =  16'sd849;
      4'd12: vol_lut =  16'sd1823; 4'd13: vol_lut =  16'sd2856;
      4'd14: vol_lut =  16'sd4444; default: vol_lut = 16'sd6144;
    endcase
  endfunction
  function automatic logic signed [15:0] env_lut(input logic [3:0] i);
    case (i)
      4'd0:  env_lut = -16'sd2048; 4'd1:  env_lut = -16'sd1974;
      4'd2:  env_lut = -16'sd1940; 4'd3:  env_lut = -16'sd1896;
      4'd4:  env_lut = -16'sd1827; 4'd5:  env_lut = -16'sd1727;
      4'd6:  env_lut = -16'sd1604; 4'd7:  env_lut = -16'sd1302;
      4'd8:  env_lut = -16'sd1119; 4'd9:  env_lut = -16'sd503;
      4'd10: env_lut =  16'sd106;  4'd11: env_lut =  16'sd825;
      4'd12: env_lut =  16'sd1803; 4'd13: env_lut =  16'sd2841;
      4'd14: env_lut =  16'sd4436; default: env_lut = 16'sd6144;
    endcase
  endfunction
  logic [7:0]  regs [0:15];
  logic        active;
  logic [3:0]  reg_latch;

  logic [12:0] tcnt [0:2];
  logic        tout [0:2];
  logic [5:0]  ncnt;
  logic        nprescale;
  logic [16:0] rng;
  logic [16:0] ecnt;
  logic signed [6:0] estep;
  logic [3:0]  eattack;
  logic        ehold, ealt, eholding;

  always_ff @(posedge clk) begin : core
    logic [12:0] c_n;
    logic [12:0] per;
    logic [11:0] praw;
    logic [2:0]  tout_n;
    logic [5:0]  ncnt_n;
    logic        nprescale_n;
    logic [16:0] rng_n;
    logic [16:0] ecnt_n;
    logic signed [6:0] estep_n;
    logic [3:0]  eattack_n;
    logic        eholding_n;
    logic [3:0]  evol;
    logic        ven;
    logic signed [15:0] sum;
    logic [3:0]  idx;
    logic        use_env;

    if (rst) begin
      for (int i = 0; i < 16; i++) regs[i] <= 8'h00;
      active <= 1'b0; reg_latch <= 4'd0;
      for (int c = 0; c < 3; c++) begin tcnt[c] <= '0; tout[c] <= 1'b0; end
      ncnt <= '0; nprescale <= 1'b0; rng <= 17'd1;
      ecnt <= '0; estep <= 7'sd15; eattack <= 4'd0; ehold <= 1'b1; ealt <= 1'b0; eholding <= 1'b0;
      level <= -16'sd6144;
    end else begin
      // ---------------- one chip tick (sound_stream_update) ----------------
      if (ce) begin
        for (int c = 0; c < 3; c++) begin
          praw = {regs[2*c+1][3:0], regs[2*c]};
          per  = (praw == 12'd0) ? 13'd1 : {1'b0, praw};
          c_n  = tcnt[c] + 13'd1;
          tout_n[c] = tout[c];
          if (c_n >= per) begin
            tcnt[c] <= c_n - per;
            tout_n[c] = ~tout[c];
          end else tcnt[c] <= c_n;
          tout[c] <= tout_n[c];
        end

        ncnt_n = ncnt + 6'd1;
        nprescale_n = nprescale;
        rng_n = rng;
        if (ncnt_n >= {1'b0, regs[6][4:0]}) begin
          ncnt_n = 6'd0;
          nprescale_n = ~nprescale;
          if (!nprescale_n) rng_n = {rng[0] ^ rng[3], rng[16:1]};
        end
        ncnt <= ncnt_n; nprescale <= nprescale_n; rng <= rng_n;

        ecnt_n = ecnt; estep_n = estep; eattack_n = eattack; eholding_n = eholding;
        if (!eholding) begin
          ecnt_n = ecnt + 17'd1;
          if (ecnt_n >= {regs[12], regs[11], 1'b0}) begin     // envelope period * m_step(2)
            ecnt_n = 17'd0;
            estep_n = estep - 7'sd1;
            if (estep_n < 0) begin
              if (ehold) begin
                if (ealt) eattack_n = eattack ^ 4'hf;
                eholding_n = 1'b1;
                estep_n = 7'sd0;
              end else begin
                if (ealt) eattack_n = eattack ^ 4'hf;
                estep_n = 7'sd15;                              // step &= mask
              end
            end
          end
        end
        ecnt <= ecnt_n; estep <= estep_n; eattack <= eattack_n; eholding <= eholding_n;
        evol = estep_n[3:0] ^ eattack_n;

        // outputs from the post-tick state (same order as MAME)
        sum = 16'sd0;
        for (int c = 0; c < 3; c++) begin
          ven = (tout_n[c] | regs[7][c]) & (rng_n[0] | regs[7][3+c]);
          use_env = regs[8+c][4];
          idx = use_env ? evol : regs[8+c][3:0];
          if (use_env) sum = sum + env_lut(ven ? idx : 4'd0);
          else         sum = sum + vol_lut(ven ? idx : 4'd0);
        end
        level <= sum;
      end

      // ---------------- register interface (ay8910_write_ym / write_reg); wins over tick ----------------
      if (wr_en) begin
        if (wr_addr) begin
          active <= (din[7:4] == 4'd0);
          if (din[7:4] == 4'd0) reg_latch <= din[3:0];
        end else if (active) begin
          regs[reg_latch] <= din;
          if (reg_latch == 4'd13) begin                        // envelope set_shape(mask = 0x0f)
            eattack <= din[2] ? 4'hf : 4'h0;
            if (!din[3]) begin ehold <= 1'b1; ealt <= din[2]; end
            else         begin ehold <= din[0]; ealt <= din[1]; end
            estep <= 7'sd15; eholding <= 1'b0;
          end
        end
      end
    end
  end
endmodule
