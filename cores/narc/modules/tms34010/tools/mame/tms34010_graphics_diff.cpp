// license:BSD-3-Clause
//
// Minimal TMS34010 graphics differential adapter for MAME.
//
// This file contains only MAME driver glue.  The processor model remains the
// unmodified upstream MAME core selected by the pinned checkout documented in
// docs/mame_graphics_reference.md.

#include "emu.h"
#include "cpu/tms34010/tms34010.h"
#include "emupal.h"
#include "screen.h"

#include <array>
#include <cstdlib>
#include <fstream>
#include <iomanip>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

constexpr u32 kMemoryWords = 16'384;
constexpr u32 kDonePrefix = 0xd1720000;

struct diff_case
{
	u32 id;
	std::vector<u16> program;
	std::vector<std::pair<u32, u16>> memory;
	u32 watch_base;
	u32 watch_words;
};

class tms34010diff_state : public driver_device
{
public:
	tms34010diff_state(
			const machine_config &mconfig, device_type type, const char *tag) :
		driver_device(mconfig, type, tag),
		m_cpu(*this, "maincpu"),
		m_space(nullptr),
		m_case_index(0),
		m_case_running(false),
		m_timer(nullptr)
	{
	}

	void tms34010diff(machine_config &config);

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

	static std::vector<diff_case> read_cases(const char *path)
	{
		std::ifstream input(path);
		if (!input)
			throw std::runtime_error(std::string("cannot open input: ") + path);

		require_token(input, "TMS34010_GRAPHICS_V1");
		u32 count = parse_hex(input, "case count");
		std::vector<diff_case> result;
		result.reserve(count);

		for (u32 index = 0; index < count; ++index)
		{
			require_token(input, "CASE");
			diff_case item;
			item.id = parse_hex(input, "case id");
			u32 program_words = parse_hex(input, "program size");
			u32 memory_words = parse_hex(input, "memory size");
			item.watch_base = parse_hex(input, "watch base");
			item.watch_words = parse_hex(input, "watch size");
			if ((program_words > kMemoryWords)
					|| (item.watch_base + item.watch_words > kMemoryWords))
				throw std::runtime_error("vector exceeds adapter memory window");

			require_token(input, "PROGRAM");
			item.program.reserve(program_words);
			for (u32 word = 0; word < program_words; ++word)
				item.program.push_back(u16(parse_hex(input, "program word")));

			require_token(input, "MEMORY");
			item.memory.reserve(memory_words);
			for (u32 word = 0; word < memory_words; ++word)
			{
				u32 address = parse_hex(input, "memory word address");
				u16 value = u16(parse_hex(input, "memory word value"));
				if (address >= kMemoryWords)
					throw std::runtime_error("memory word lies outside adapter window");
				item.memory.emplace_back(address, value);
			}
			require_token(input, "END");
			result.emplace_back(std::move(item));
		}
		return result;
	}

	void clear_case_memory()
	{
		for (u32 word = 0; word < kMemoryWords; ++word)
			m_space->write_word(word * 16, 0);
	}

	void start_case(const diff_case &item)
	{
		m_cpu->reset();
		clear_case_memory();
		for (u32 word = 0; word < item.program.size(); ++word)
			m_space->write_word(word * 16, item.program[word]);
		for (const auto &[word, value] : item.memory)
			m_space->write_word(word * 16, value);
		m_cpu->set_state_int(TMS34010_PC, 0);
	}

	void capture_case(const diff_case &item)
	{
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
		m_output << '\n';
		m_output << "B";
		for (int reg = 0; reg < 15; ++reg)
			m_output << ' ' << std::setw(8)
					<< u32(m_cpu->state_int(TMS34010_B0 + reg));
		m_output << '\n';
		m_output << "IO"
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_DPYCTL)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_CONTROL)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_CONVSP)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_CONVDP)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_PSIZE)
				<< ' ' << std::setw(4) << m_cpu->io_register_r(REG_PMASK)
				<< '\n';
		m_output << "MEM";
		for (u32 word = 0; word < item.watch_words; ++word)
			m_output << ' ' << std::setw(4)
					<< m_space->read_word((item.watch_base + word) * 16);
		m_output << "\nEND\n";
	}

	TIMER_CALLBACK_MEMBER(run_vectors)
	{
		try
		{
			if (m_case_running)
			{
				const diff_case &item = m_cases[m_case_index];
				if ((u32(m_cpu->state_int(TMS34010_A14)) & 0xffff0000)
						!= kDonePrefix)
					throw std::runtime_error(
							"case " + std::to_string(item.id) + " timed out");
				capture_case(item);
				++m_case_index;
				m_case_running = false;
			}

			if (m_case_index < m_cases.size())
			{
				start_case(m_cases[m_case_index]);
				m_case_running = true;
				m_timer->adjust(attotime::from_msec(1));
			}
			else
			{
				m_output.close();
				machine().schedule_exit();
			}
		}
		catch (const std::exception &error)
		{
			throw emu_fatalerror(1, "TMS34010 differential error: %s", error.what());
		}
	}

	virtual void machine_start() override
	{
		const char *input_path = std::getenv("TMS34010_DIFF_INPUT");
		const char *output_path = std::getenv("TMS34010_DIFF_OUTPUT");
		if (!input_path || !output_path)
			throw emu_fatalerror(
					1, "TMS34010_DIFF_INPUT and TMS34010_DIFF_OUTPUT are required");
		m_space = &m_cpu->space(AS_PROGRAM);
		try
		{
			m_cases = read_cases(input_path);
			m_output.open(output_path);
			if (!m_output)
				throw std::runtime_error(
						std::string("cannot open output: ") + output_path);
			m_output << "TMS34010_GRAPHICS_RESULTS_V1 "
					<< std::hex << m_cases.size() << '\n';
		}
		catch (const std::exception &error)
		{
			throw emu_fatalerror(1, "TMS34010 differential error: %s", error.what());
		}
		m_timer = timer_alloc(FUNC(tms34010diff_state::run_vectors), this);
		m_timer->adjust(attotime::zero);
	}

	void program_map(address_map &map) ATTR_COLD
	{
		map(0x00000000, 0x003fffff).ram();
		map(0xfffffc00, 0xffffffff).ram();
	}

	required_device<tms34010_device> m_cpu;
	address_space *m_space;
	std::vector<diff_case> m_cases;
	std::ofstream m_output;
	std::size_t m_case_index;
	bool m_case_running;
	emu_timer *m_timer;
};

void tms34010diff_state::tms34010diff(machine_config &config)
{
	TMS34010(config, m_cpu, 40'000'000);
	m_cpu->set_addrmap(AS_PROGRAM, &tms34010diff_state::program_map);
	m_cpu->set_halt_on_reset(false);
	m_cpu->set_pixel_clock(5'000'000);
	m_cpu->set_pixels_per_clock(1);

	screen_device &screen(SCREEN(config, "screen", SCREEN_TYPE_RASTER));
	screen.set_raw(5'000'000, 320, 0, 256, 262, 0, 240);
	screen.set_screen_update("maincpu", FUNC(tms34010_device::tms340x0_ind16));
	PALETTE(config, "palette").set_entries(256);
	screen.set_palette("palette");
}

ROM_START(tms34010diff)
	ROM_REGION(0x10, "user1", ROMREGION_ERASE00)
ROM_END

} // anonymous namespace

GAME(2026, tms34010diff, 0, tms34010diff, 0, tms34010diff_state, empty_init, ROT0, "TMS34010_sv", "Pinned TMS34010 graphics differential adapter", MACHINE_NO_SOUND_HW | MACHINE_SUPPORTS_SAVE)
