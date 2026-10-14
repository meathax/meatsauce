library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Cross-clock collector for a ROM cache-line transfer.  memorymux emits the
-- ROM read on clk1x; the SDRAM controller returns four one-hot cache beats on
-- clk3x.  This entity owns the handshake and gates only those cache beats away
-- from the CPU cache RAM, whose tags do not describe the temporary ROM line.
entity rom_burst_collector is
   port (
      clk1x            : in  std_logic;
      clk3x            : in  std_logic;
      reset            : in  std_logic;
      ram_cpu_ena      : in  std_logic;
      ram_cpu_cache    : in  std_logic;
      rom_prefetch_request : in std_logic := '1';
      ram_cpu_rnw      : in  std_logic;
      ram_cpu_Adr      : in  std_logic_vector(26 downto 0);
      cache_wr         : in  std_logic_vector(3 downto 0);
      cache_data       : in  std_logic_vector(31 downto 0);
      cache_wr_cpu     : out std_logic_vector(3 downto 0);
      rom_burst_done   : out std_logic;
      rom_burst_data   : out std_logic_vector(127 downto 0)
   );
end entity;

architecture arch of rom_burst_collector is
   signal req_toggle_1x        : std_logic := '0';
   signal outstanding_1x       : std_logic := '0';
   signal done_toggle_3x       : std_logic := '0';
   signal req_sync3x_1         : std_logic := '0';
   signal req_sync3x_2         : std_logic := '0';
   signal req_seen_3x          : std_logic := '0';
   signal collect_active_3x    : std_logic := '0';
   signal mask_3x              : std_logic_vector(3 downto 0) := (others => '0');
   signal data_3x              : std_logic_vector(127 downto 0) := (others => '0');
   signal done_sync1x_1        : std_logic := '0';
   signal done_sync1x_2        : std_logic := '0';
   signal done_seen_1x         : std_logic := '0';
   signal done_pulse_1x        : std_logic := '0';
   signal data_1x              : std_logic_vector(127 downto 0) := (others => '0');
begin
   process (clk1x)
   begin
      if rising_edge(clk1x) then
         if (reset = '1') then
            req_toggle_1x   <= '0';
            outstanding_1x  <= '0';
            done_sync1x_1   <= '0';
            done_sync1x_2   <= '0';
            done_seen_1x    <= '0';
            done_pulse_1x   <= '0';
            data_1x         <= (others => '0');
         else
            done_sync1x_1 <= done_toggle_3x;
            done_sync1x_2 <= done_sync1x_1;
            done_pulse_1x <= '0';

            if (done_sync1x_2 /= done_seen_1x) then
               -- data_3x has been stable since the final cache beat and
               -- remains stable through the two-flop completion crossing.
               done_seen_1x   <= done_sync1x_2;
               data_1x        <= data_3x;
               done_pulse_1x  <= '1';
               outstanding_1x <= '0';
            elsif (outstanding_1x = '0' and
                   ram_cpu_ena = '1' and ram_cpu_cache = '1' and
                   rom_prefetch_request = '1' and
                   ram_cpu_rnw = '1' and
                   unsigned(ram_cpu_Adr) >= to_unsigned(16#0880000#, 27) and
                   unsigned(ram_cpu_Adr) <  to_unsigned(16#0A80000#, 27)) then
               req_toggle_1x  <= not req_toggle_1x;
               outstanding_1x <= '1';
            end if;
         end if;
      end if;
   end process;

   process (clk3x)
      variable next_mask : std_logic_vector(3 downto 0);
      variable next_data : std_logic_vector(127 downto 0);
   begin
      if rising_edge(clk3x) then
         if (reset = '1') then
            req_sync3x_1      <= '0';
            req_sync3x_2      <= '0';
            req_seen_3x       <= '0';
            collect_active_3x <= '0';
            mask_3x           <= (others => '0');
            data_3x           <= (others => '0');
            done_toggle_3x    <= '0';
         else
            req_sync3x_1 <= req_toggle_1x;
            req_sync3x_2 <= req_sync3x_1;
            if (req_sync3x_2 /= req_seen_3x) then
               req_seen_3x       <= req_sync3x_2;
               collect_active_3x <= '1';
               mask_3x           <= (others => '0');
               data_3x           <= (others => '0');
            elsif (collect_active_3x = '1' and cache_wr /= "0000") then
               next_mask := mask_3x;
               next_data := data_3x;
               case cache_wr is
                  when "0001" => next_data(31 downto 0)    := cache_data; next_mask(0) := '1';
                  when "0010" => next_data(63 downto 32)   := cache_data; next_mask(1) := '1';
                  when "0100" => next_data(95 downto 64)   := cache_data; next_mask(2) := '1';
                  when "1000" => next_data(127 downto 96)  := cache_data; next_mask(3) := '1';
                  when others => null;
               end case;
               mask_3x <= next_mask;
               data_3x <= next_data;
               if (next_mask = "1111") then
                  collect_active_3x <= '0';
                  done_toggle_3x    <= not done_toggle_3x;
               end if;
            end if;
         end if;
      end if;
   end process;

   cache_wr_cpu   <= (others => '0') when
      (collect_active_3x = '1' or req_sync3x_2 /= req_seen_3x) else cache_wr;
   rom_burst_done <= done_pulse_1x;
   rom_burst_data <= data_1x;
end architecture;
