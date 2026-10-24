// license:BSD-3-Clause
//
// Minimal adapter that loads preserved TI COFF-derived word vectors into the
// unmodified pinned MAME TMS34010 core.  No MAME CPU architecture is copied
// into this repository.

#include "emu.h"
#include "cpu/tms34010/tms34010.h"
#include "emupal.h"
#include "screen.h"

#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {

struct watch_region
{
	std::string name;
	u32 address;
	u32 words;
};

struct workload_case
{
	u32 id;
	u32 entry;
	u32 checkpoint;
	u32 timeout_polls;
	std::vector<std::pair<u32, u16>> load;
	std::vector<watch_region> watches;
};

class tms34010ti_state : public driver_device
{
public:
	tms34010ti_state(
			const machine_config &mconfig, device_type type, const char *tag) :
		driver_device(mconfig, type, tag),
		m_cpu(*this, "maincpu"),
		m_space(nullptr),
		m_case_index(0),
		m_poll_count(0),
		m_running(false),
		m_timer(nullptr)
	{
	}

	void tms34010ti(machine_config &config);
	u32 screen_update(
			screen_device &, bitmap_ind16 &, const rectangle &)
	{
		return 0;
	}

private:
	static u32 parse_hex(std::istream &input, const char *what)
	{
		std::string token;
		if (!(input >> token))
			throw std::runtime_error(std::string("missing ") + what);
		std::size_t consumed = 0;
		u32 value = u32(std::stoul(token, &consumed, 16));
		if (consumed != token.size())
			throw std::runtime_error(std::string("invalid ") + what + ": " + token);
		return value;
	}

	static void require_token(std::istream &input, const char *expected)
	{
		std::string token;
		if (!(input >> token) || token != expected)
			throw std::runtime_error(
					std::string("expected '") + expected + "', got '" + token + "'");
	}

	static std::vector<workload_case> read_cases(const char *path)
	{
		std::ifstream input(path);
		if (!input)
			throw std::runtime_error(std::string("cannot open input: ") + path);
		require_token(input, "TMS34010_TI_WORKLOADS_V1");
		u32 count = parse_hex(input, "case count");
		std::vector<workload_case> result;
		result.reserve(count);
		for (u32 index = 0; index < count; ++index)
		{
			require_token(input, "CASE");
			workload_case item;
			item.id = parse_hex(input, "case id");
			item.entry = parse_hex(input, "entry");
			item.checkpoint = parse_hex(input, "checkpoint");
			item.timeout_polls = parse_hex(input, "timeout");
			u32 load_words = parse_hex(input, "load count");
			u32 watch_count = parse_hex(input, "watch count");
			require_token(input, "LOAD");
			item.load.reserve(load_words);
			for (u32 word = 0; word < load_words; ++word)
			{
				u32 address = parse_hex(input, "load address");
				u16 value = u16(parse_hex(input, "load word"));
				item.load.emplace_back(address, value);
			}
			item.watches.reserve(watch_count);
			for (u32 watch = 0; watch < watch_count; ++watch)
			{
				require_token(input, "WATCH");
				std::string name;
				if (!(input >> name))
					throw std::runtime_error("missing watch name");
				item.watches.push_back(
						{name, parse_hex(input, "watch address"),
						 parse_hex(input, "watch words")});
			}
			require_token(input, "END");
			result.emplace_back(std::move(item));
		}
		return result;
	}

	static u64 fnv_word(u64 hash, u16 value)
	{
		hash ^= value & 0xff;
		hash *= 0x100000001b3ULL;
		hash ^= value >> 8;
		hash *= 0x100000001b3ULL;
		return hash;
	}

	void clear_case_memory()
	{
		for (u32 address = 0; address < 0x00400000; address += 16)
			m_space->write_word(address, 0);
		for (u32 address = 0xffc00000; address != 0; address += 16)
			m_space->write_word(address, 0);
	}

	void start_case(const workload_case &item)
	{
		m_cpu->set_input_line(INPUT_LINE_HALT, ASSERT_LINE);
		m_cpu->reset();
		clear_case_memory();
		for (const auto &[address, value] : item.load)
			m_space->write_word(address, value);
		m_cpu->set_state_int(TMS34010_PC, item.entry);
		m_poll_count = 0;
		m_pc_history.clear();
		m_pc_first.clear();
		m_cpu->set_input_line(INPUT_LINE_HALT, CLEAR_LINE);
	}

	void capture_case(const workload_case &item)
	{
		m_cpu->set_input_line(INPUT_LINE_HALT, ASSERT_LINE);
		m_output << std::hex << std::setfill('0');
		m_output << "CASE " << std::setw(8) << item.id
				<< ' ' << std::setw(8) << u32(m_cpu->state_int(TMS34010_PC))
				<< ' ' << std::setw(8) << u32(m_cpu->state_int(TMS34010_SP))
				<< ' ' << std::setw(8) << u32(m_cpu->state_int(TMS34010_ST))
				<< '\n';
		m_output << "A";
		for (int reg = 0; reg < 15; ++reg)
			m_output << ' ' << std::setw(8)
					<< u32(m_cpu->state_int(TMS34010_A0 + reg));
		m_output << "\nB";
		for (int reg = 0; reg < 15; ++reg)
			m_output << ' ' << std::setw(8)
					<< u32(m_cpu->state_int(TMS34010_B0 + reg));
		m_output << "\nIO"
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_DPYCTL)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_CONTROL)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_CONVSP)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_CONVDP)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_PSIZE)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_PMASK)
				<< '\n';
		for (const watch_region &watch : item.watches)
		{
			u64 hash = 0xcbf29ce484222325ULL;
			for (u32 word = 0; word < watch.words; ++word)
				hash = fnv_word(
						hash, m_space->read_word(watch.address + word * 16));
			m_output << "HASH " << watch.name << ' '
					<< std::setw(16) << hash << '\n';
		}
		m_output << "END\n";
	}

	TIMER_CALLBACK_MEMBER(run_vectors)
	{
		try
		{
			if (m_running)
			{
				const workload_case &item = m_cases[m_case_index];
				u32 pc = u32(m_cpu->state_int(TMS34010_PC));
				if (m_pc_history.size() == 32)
					m_pc_history.erase(m_pc_history.begin());
				m_pc_history.push_back(pc);
				if (m_pc_first.size() < 64)
					m_pc_first.push_back(pc);
				if (pc == item.checkpoint)
				{
					capture_case(item);
					++m_case_index;
					m_running = false;
				}
				else if (++m_poll_count >= item.timeout_polls)
				{
					std::string history;
					for (u32 value : m_pc_history)
						history += util::string_format(" %08x", value);
					std::string first;
					for (u32 value : m_pc_first)
						first += util::string_format(" %08x", value);
					throw std::runtime_error(
							"case " + std::to_string(item.id)
							+ " timed out at PC "
							+ util::string_format("%08x", pc)
							+ "; first PCs:" + first
							+ "; recent PCs:" + history);
				}
			}
			if (!m_running && m_case_index < m_cases.size())
			{
				start_case(m_cases[m_case_index]);
				m_running = true;
			}
			if (m_case_index == m_cases.size())
			{
				m_output.close();
				machine().schedule_exit();
			}
			else
			{
				m_timer->adjust(attotime::from_usec(1));
			}
		}
		catch (const std::exception &error)
		{
			throw emu_fatalerror(1, "TMS34010 TI workload error: %s", error.what());
		}
	}

	virtual void machine_start() override
	{
		const char *input_path = std::getenv("TMS34010_TI_INPUT");
		const char *output_path = std::getenv("TMS34010_TI_OUTPUT");
		if (!input_path || !output_path)
			throw emu_fatalerror(
					1, "TMS34010_TI_INPUT and TMS34010_TI_OUTPUT are required");
		m_space = &m_cpu->space(AS_PROGRAM);
		try
		{
			m_cases = read_cases(input_path);
			m_output.open(output_path);
			if (!m_output)
				throw std::runtime_error(
						std::string("cannot open output: ") + output_path);
			m_output << "TMS34010_TI_RESULTS_V1 "
					<< std::hex << m_cases.size() << '\n';
		}
		catch (const std::exception &error)
		{
			throw emu_fatalerror(1, "TMS34010 TI workload error: %s", error.what());
		}
		m_timer = timer_alloc(FUNC(tms34010ti_state::run_vectors), this);
		m_timer->adjust(attotime::zero);
	}

	void program_map(address_map &map) ATTR_COLD
	{
		map(0x00000000, 0x003fffff).ram();
		map(0xffc00000, 0xffffffff).ram();
	}

	TMS340X0_TO_SHIFTREG_CB_MEMBER(to_shiftreg)
	{
		for (u32 word = 0; word < 256; ++word)
			shiftreg[word] = m_space->read_word(address + word * 16);
	}

	TMS340X0_FROM_SHIFTREG_CB_MEMBER(from_shiftreg)
	{
		for (u32 word = 0; word < 256; ++word)
			m_space->write_word(address + word * 16, shiftreg[word]);
	}

	required_device<tms34010_device> m_cpu;
	address_space *m_space;
	std::vector<workload_case> m_cases;
	std::ofstream m_output;
	std::size_t m_case_index;
	u32 m_poll_count;
	std::vector<u32> m_pc_history;
	std::vector<u32> m_pc_first;
	bool m_running;
	emu_timer *m_timer;
};

void tms34010ti_state::tms34010ti(machine_config &config)
{
	TMS34010(config, m_cpu, 40'000'000);
	m_cpu->set_addrmap(AS_PROGRAM, &tms34010ti_state::program_map);
	m_cpu->set_halt_on_reset(false);
	m_cpu->set_pixel_clock(5'000'000);
	m_cpu->set_pixels_per_clock(1);
	m_cpu->set_shiftreg_in_callback(FUNC(tms34010ti_state::to_shiftreg));
	m_cpu->set_shiftreg_out_callback(FUNC(tms34010ti_state::from_shiftreg));

	screen_device &screen(SCREEN(config, "screen", SCREEN_TYPE_RASTER));
	screen.set_raw(5'000'000, 800, 0, 640, 525, 0, 480);
	screen.set_screen_update(FUNC(tms34010ti_state::screen_update));
	PALETTE(config, "palette").set_entries(256);
	screen.set_palette("palette");
}

ROM_START(tms34010ti)
	ROM_REGION(0x10, "user1", ROMREGION_ERASE00)
ROM_END

} // anonymous namespace

GAME(2026, tms34010ti, 0, tms34010ti, 0, tms34010ti_state, empty_init, ROT0, "TMS34010_sv", "Pinned TMS34010 TI workload adapter", MACHINE_NO_SOUND_HW | MACHINE_SUPPORTS_SAVE)
