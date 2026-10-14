-- Primal Rage II Atari ZN-1 I/O
-- The address map follows MAME's pinned zn_state/primrag2 implementation.
-- AT28C16 functional polling follows MAME's 200 us busy interval; persistent
-- upload is a MiSTer host-side facility and is not original PCB behavior.

library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

library altera_mf;
use altera_mf.altera_mf_components.all;

entity zn1_io is
   port (
      clk          : in  std_logic;
      reset        : in  std_logic;

      addr         : in  unsigned(20 downto 0);
      data_write   : in  std_logic_vector(31 downto 0);
      write_mask   : in  std_logic_vector(3 downto 0);
      read_en      : in  std_logic;
      write_en     : in  std_logic;
      data_read    : out std_logic_vector(31 downto 0);

      p1_right     : in  std_logic;
      p1_left      : in  std_logic;
      p1_down      : in  std_logic;
      p1_up        : in  std_logic;
      p1_btn       : in  std_logic_vector(5 downto 0);
      p1_start     : in  std_logic;
      p1_coin      : in  std_logic;
      p2_right     : in  std_logic;
      p2_left      : in  std_logic;
      p2_down      : in  std_logic;
      p2_up        : in  std_logic;
      p2_btn       : in  std_logic_vector(5 downto 0);
      p2_start     : in  std_logic;
      p2_coin      : in  std_logic;
      service      : in  std_logic;
      test_mode    : in  std_logic;

      sec_select   : out std_logic_vector(2 downto 0);
      coin_out     : out std_logic_vector(7 downto 0);

      ee_dl_wr     : in  std_logic := '0';
      ee_dl_addr   : in  std_logic_vector(8 downto 0) := (others => '0');
      ee_dl_data   : in  std_logic_vector(31 downto 0) := (others => '0');
      ee_dl_be     : in  std_logic_vector(3 downto 0) := (others => '0');

       ee_host_addr : in  std_logic_vector(8 downto 0) := (others => '0');
       ee_host_data : out std_logic_vector(31 downto 0);
       ee_dirty     : out std_logic;
       ee_write_accepted : out std_logic;
       ee_dirty_clear : in std_logic := '0';

      dbg_ee_word0 : out std_logic_vector(31 downto 0) := (others => '0');
      dbg_ee_stat  : out std_logic_vector(127 downto 0) := (others => '0')
   );
end entity;

architecture arch of zn1_io is

   constant EEPROM_BUSY_CYCLES : natural := 6774; -- 200 us at 33.8688 MHz

   signal sec_sel_r       : std_logic_vector(2 downto 0) := (others => '0');
   signal secsel_byte_r   : std_logic_vector(7 downto 0) := (others => '0');
   signal coin_r          : std_logic_vector(7 downto 0) := x"FF";

   signal eeprom_cs       : std_logic;
   signal eeprom_addr     : std_logic_vector(8 downto 0);
   signal eeprom_dout     : std_logic_vector(31 downto 0);
   signal eeprom_host_q   : std_logic_vector(31 downto 0);
   signal eeprom_write    : std_logic;
   signal eeprom_diff     : std_logic;
   signal eeprom_accept   : std_logic;

   signal ee_ram_addr     : std_logic_vector(8 downto 0);
   signal ee_ram_wren     : std_logic;
   signal ee_ram_byteena  : std_logic_vector(3 downto 0);
   signal ee_ram_data     : std_logic_vector(31 downto 0);

   signal busy_count      : unsigned(12 downto 0) := (others => '0');
   signal last_write_data : std_logic_vector(7 downto 0) := x"FF";
   signal dirty_r         : std_logic := '0';

   function make_player(r, l, d, u : std_logic;
                        btn : std_logic_vector(5 downto 0))
      return std_logic_vector is
      variable v : std_logic_vector(31 downto 0) := (others => '1');
   begin
      v(0) := not u;
      v(1) := not d;
      v(2) := not l;
      v(3) := not r;
      v(4) := not btn(0);
      v(5) := not btn(1);
      v(6) := not btn(2);
      return v;
   end function;

   function selected_byte(data : std_logic_vector(31 downto 0);
                          mask : std_logic_vector(3 downto 0))
      return std_logic_vector is
   begin
      if mask(0) = '1' then return data(7 downto 0); end if;
      if mask(1) = '1' then return data(15 downto 8); end if;
      if mask(2) = '1' then return data(23 downto 16); end if;
      return data(31 downto 24);
   end function;

begin

   sec_select <= sec_sel_r;
   coin_out   <= coin_r;
   ee_dirty   <= dirty_r;
   ee_write_accepted <= eeprom_accept;
   ee_host_data <= eeprom_host_q;

   -- The 2 KiB device repeats through the ZN EEPROM page.
   eeprom_cs   <= '1' when addr(20 downto 16) = "01111" else '0';
   eeprom_addr <= std_logic_vector(addr(10 downto 2));
   eeprom_write <= write_en and eeprom_cs;

   eeprom_diff <=
      '1' when
         (write_mask(0) = '1' and data_write(7 downto 0) /= eeprom_dout(7 downto 0)) or
         (write_mask(1) = '1' and data_write(15 downto 8) /= eeprom_dout(15 downto 8)) or
         (write_mask(2) = '1' and data_write(23 downto 16) /= eeprom_dout(23 downto 16)) or
         (write_mask(3) = '1' and data_write(31 downto 24) /= eeprom_dout(31 downto 24))
      else '0';

   eeprom_accept <= eeprom_write and eeprom_diff when busy_count = 0 else '0';

   ee_ram_addr    <= ee_dl_addr when ee_dl_wr = '1' else eeprom_addr;
   ee_ram_wren    <= ee_dl_wr or eeprom_accept;
   ee_ram_byteena <= ee_dl_be when ee_dl_wr = '1' else write_mask;
   ee_ram_data    <= ee_dl_data when ee_dl_wr = '1' else data_write;

   ieeprom : altsyncram
   generic map (
      operation_mode                  => "BIDIR_DUAL_PORT",
      width_a                         => 32,
      widthad_a                       => 9,
      numwords_a                      => 512,
      width_byteena_a                 => 4,
      outdata_reg_a                   => "UNREGISTERED",
      width_b                         => 32,
      widthad_b                       => 9,
      numwords_b                      => 512,
      width_byteena_b                 => 4,
      address_reg_b                   => "CLOCK1",
      outdata_reg_b                   => "UNREGISTERED",
      read_during_write_mode_mixed_ports => "OLD_DATA",
      ram_block_type                  => "M10K",
      init_file                       => "eeprom_ff.mif",
      lpm_type                        => "altsyncram"
   )
   port map (
      clock0    => clk,
      address_a => ee_ram_addr,
      wren_a    => ee_ram_wren,
      byteena_a => ee_ram_byteena,
      data_a    => ee_ram_data,
      q_a       => eeprom_dout,

      clock1    => clk,
      address_b => ee_host_addr,
      wren_b    => '0',
      byteena_b => "1111",
      data_b    => (others => '0'),
      q_b       => eeprom_host_q
   );

   process(clk)
      variable p1_v, p2_v, p4_v, svc_v, sys_v : std_logic_vector(31 downto 0);
   begin
      if rising_edge(clk) then
          -- A write accepted on the same edge as an upload acknowledgement
          -- belongs to a newer EEPROM generation and must remain pending.
          if eeprom_accept = '1' then
             dirty_r <= '1';
          elsif ee_dirty_clear = '1' then
             dirty_r <= '0';
          end if;

         if eeprom_accept = '1' then
            busy_count <= to_unsigned(EEPROM_BUSY_CYCLES - 1, busy_count'length);
            last_write_data <= selected_byte(data_write, write_mask);
         elsif busy_count /= 0 then
            busy_count <= busy_count - 1;
         end if;

         if reset = '1' then
            sec_sel_r     <= (others => '0');
            secsel_byte_r <= (others => '0');
            coin_r        <= x"FF";
            data_read     <= (others => '0');
         else
            p1_v := make_player(p1_right, p1_left, p1_down, p1_up, p1_btn);
            p2_v := make_player(p2_right, p2_left, p2_down, p2_up, p2_btn);

            -- PR2 routes buttons 4-6 through the P4 connector.
            p4_v := (others => '1');
            p4_v(0) := not p1_btn(3);
            p4_v(1) := not p1_btn(4);
            p4_v(2) := not p1_btn(5);
            p4_v(4) := not p2_btn(3);
            p4_v(5) := not p2_btn(4);
            p4_v(6) := not p2_btn(5);

            svc_v := (others => '1');
            svc_v(0) := not test_mode;
            svc_v(1) := not service;

            sys_v := (others => '1');
            sys_v(0) := not p1_start;
            sys_v(1) := not p2_start;
            sys_v(4) := not p1_coin;
            sys_v(5) := not p2_coin;

            -- memorymux OR-reduces every peripheral read bus.
            data_read <= (others => '0');

            if eeprom_cs = '1' then
               if read_en = '1' then
                  if busy_count /= 0 then
                     data_read <= (last_write_data xor x"80") &
                                  (last_write_data xor x"80") &
                                  (last_write_data xor x"80") &
                                  (last_write_data xor x"80");
                  else
                     data_read <= eeprom_dout;
                  end if;
               end if;
            else
               if read_en = '1' then
                  case addr(20 downto 2) is
                     when "0000000000000000000" => data_read <= p1_v;                 -- 1fa00000
                     when "0000000000001000000" => data_read <= p2_v;                 -- 1fa00100
                     when "0000000000010000000" => data_read <= svc_v;                -- 1fa00200
                     when "0000000000011000000" => data_read <= sys_v;                -- 1fa00300
                     when "0000100000000000000" => data_read <= (others => '1');       -- 1fa10000 P3
                     when "0000100000001000000" => data_read <= p4_v;                  -- 1fa10100 P4
                     when "0000100000010000000" => data_read <= x"0000006A";           -- 8 MiB RAM, 2 MiB VRAM
                     when "0000100000011000000" => data_read <= x"000000" & secsel_byte_r;
                     when "0001000000000000000" => data_read <= x"000000" & coin_r;
                     when others => null;
                  end case;
               end if;

               -- Security select and coin output occupy only byte lane zero.
               -- Upper-lane stores must not modify these byte registers.
               if write_en = '1' and write_mask(0) = '1' then
                  case addr(20 downto 2) is
                     when "0000100000011000000" =>
                        sec_sel_r     <= data_write(7) & data_write(3 downto 2);
                        secsel_byte_r <= data_write(7 downto 0);
                     when "0001000000000000000" =>
                        coin_r <= data_write(7 downto 0);
                     when others => null;
                  end case;
               end if;
            end if;
         end if;
      end if;
   end process;

   dbg_ee_word0 <= (others => '0');
   dbg_ee_stat  <= (others => '0');

end architecture;
