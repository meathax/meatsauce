#!/usr/bin/env python3
"""Compile a human-readable credits list into synthesizable internal FPGA ROMs."""
import argparse
import hashlib
import json
from pathlib import Path
import unicodedata

# Original 5x7 glyphs. Compact 6x8 cells keep the two-column roll short.
PATTERNS = {
    ' ': '00000/00000/00000/00000/00000/00000/00000',
    'A': '01110/10001/10001/11111/10001/10001/10001',
    'B': '11110/10001/10001/11110/10001/10001/11110',
    'C': '01111/10000/10000/10000/10000/10000/01111',
    'D': '11110/10001/10001/10001/10001/10001/11110',
    'E': '11111/10000/10000/11110/10000/10000/11111',
    'F': '11111/10000/10000/11110/10000/10000/10000',
    'G': '01111/10000/10000/10111/10001/10001/01111',
    'H': '10001/10001/10001/11111/10001/10001/10001',
    'I': '01110/00100/00100/00100/00100/00100/01110',
    'J': '00111/00010/00010/00010/10010/10010/01100',
    'K': '10001/10010/10100/11000/10100/10010/10001',
    'L': '10000/10000/10000/10000/10000/10000/11111',
    'M': '10001/11011/10101/10101/10001/10001/10001',
    'N': '10001/11001/10101/10011/10001/10001/10001',
    'O': '01110/10001/10001/10001/10001/10001/01110',
    'P': '11110/10001/10001/11110/10000/10000/10000',
    'Q': '01110/10001/10001/10001/10101/10010/01101',
    'R': '11110/10001/10001/11110/10100/10010/10001',
    'S': '01111/10000/10000/01110/00001/00001/11110',
    'T': '11111/00100/00100/00100/00100/00100/00100',
    'U': '10001/10001/10001/10001/10001/10001/01110',
    'V': '10001/10001/10001/10001/10001/01010/00100',
    'W': '10001/10001/10001/10101/10101/10101/01010',
    'X': '10001/10001/01010/00100/01010/10001/10001',
    'Y': '10001/10001/01010/00100/00100/00100/00100',
    'Z': '11111/00001/00010/00100/01000/10000/11111',
    '0': '01110/10001/10011/10101/11001/10001/01110',
    '1': '00100/01100/00100/00100/00100/00100/01110',
    '2': '01110/10001/00001/00010/00100/01000/11111',
    '3': '11110/00001/00001/01110/00001/00001/11110',
    '4': '00010/00110/01010/10010/11111/00010/00010',
    '5': '11111/10000/10000/11110/00001/00001/11110',
    '6': '01110/10000/10000/11110/10001/10001/01110',
    '7': '11111/00001/00010/00100/01000/01000/01000',
    '8': '01110/10001/10001/01110/10001/10001/01110',
    '9': '01110/10001/10001/01111/00001/00001/01110',
    '.': '00000/00000/00000/00000/00000/00110/00110',
    ',': '00000/00000/00000/00000/00110/00100/01000',
    '-': '00000/00000/00000/11111/00000/00000/00000',
    '_': '00000/00000/00000/00000/00000/00000/11111',
    '+': '00000/00100/00100/11111/00100/00100/00000',
    '&': '01100/10010/10100/01000/10101/10010/01101',
    "'": '00100/00100/01000/00000/00000/00000/00000',
    '"': '01010/01010/01010/00000/00000/00000/00000',
    '!': '00100/00100/00100/00100/00100/00000/00100',
    '?': '01110/10001/00001/00010/00100/00000/00100',
    '/': '00001/00010/00010/00100/01000/01000/10000',
    '\\': '10000/01000/01000/00100/00010/00010/00001',
    ':': '00000/00110/00110/00000/00110/00110/00000',
    ';': '00000/00110/00110/00000/00110/00100/01000',
    '(': '00010/00100/01000/01000/01000/00100/00010',
    ')': '01000/00100/00010/00010/00010/00100/01000',
    '[': '01110/01000/01000/01000/01000/01000/01110',
    ']': '01110/00010/00010/00010/00010/00010/01110',
    '{': '00010/00100/00100/01000/00100/00100/00010',
    '}': '01000/00100/00100/00010/00100/00100/01000',
    '<': '00010/00100/01000/10000/01000/00100/00010',
    '>': '01000/00100/00010/00001/00010/00100/01000',
    '=': '00000/00000/11111/00000/11111/00000/00000',
    '*': '00000/10101/01110/11111/01110/10101/00000',
    '#': '01010/11111/01010/01010/11111/01010/00000',
    '@': '01110/10001/10111/10101/10111/10000/01110',
    '$': '00100/01111/10100/01110/00101/11110/00100',
    '%': '11001/11010/00100/00100/01000/10110/00110',
    '^': '00100/01010/10001/00000/00000/00000/00000',
    '`': '01000/00100/00010/00000/00000/00000/00000',
    '~': '00000/00000/01001/10110/00000/00000/00000',
    '|': '00100/00100/00100/00100/00100/00100/00100',
}
PATTERNS.update({
    'a': '00000/00000/01110/00001/01111/10001/01111',
    'b': '10000/10000/10110/11001/10001/10001/11110',
    'c': '00000/00000/01111/10000/10000/10000/01111',
    'd': '00001/00001/01101/10011/10001/10001/01111',
    'e': '00000/00000/01110/10001/11111/10000/01111',
    'f': '00110/01001/01000/11100/01000/01000/01000',
    'g': '00000/01111/10001/10001/01111/00001/01110',
    'h': '10000/10000/10110/11001/10001/10001/10001',
    'i': '00100/00000/01100/00100/00100/00100/01110',
    'j': '00010/00000/00110/00010/00010/10010/01100',
    'k': '10000/10000/10010/10100/11000/10100/10010',
    'l': '01100/00100/00100/00100/00100/00100/01110',
    'm': '00000/00000/11010/10101/10101/10101/10101',
    'n': '00000/00000/10110/11001/10001/10001/10001',
    'o': '00000/00000/01110/10001/10001/10001/01110',
    'p': '00000/11110/10001/10001/11110/10000/10000',
    'q': '00000/01111/10001/10001/01111/00001/00001',
    'r': '00000/00000/10110/11001/10000/10000/10000',
    's': '00000/00000/01111/10000/01110/00001/11110',
    't': '01000/01000/11100/01000/01000/01001/00110',
    'u': '00000/00000/10001/10001/10001/10011/01101',
    'v': '00000/00000/10001/10001/10001/01010/00100',
    'w': '00000/00000/10001/10001/10101/10101/01010',
    'x': '00000/00000/10001/01010/00100/01010/10001',
    'y': '00000/10001/10001/10001/01111/00001/01110',
    'z': '00000/00000/11111/00010/00100/01000/11111',
})


def normalize(name, where):
    name = unicodedata.normalize('NFKD', name.upper())
    name = ''.join(c for c in name if not unicodedata.combining(c))
    unknown = sorted(set(name) - PATTERNS.keys())
    if unknown:
        raise ValueError(f'{where}: unsupported characters {unknown!r}; use a Latin transliteration')
    return name


def parse(path):
    tiers = {'gold': [], 'meat': []}
    tier = None
    for line_number, raw in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        aliases = {'[gold]':'gold', '[meat kings]':'gold', '[meatkings]':'gold',
                   '[meat]':'meat', '[meatlovers]':'meat'}
        if line.lower() in aliases:
            tier = aliases[line.lower()]
        elif line.startswith('[') and line.endswith(']'):
            raise ValueError(f'{path}:{line_number}: expected [Meat Kings] or [Meatlovers]')
        elif tier is None:
            raise ValueError(f'{path}:{line_number}: a name needs a [Meat Kings] or [Meatlovers] section')
        else:
            tiers[tier].append(normalize(line, f'{path}:{line_number}'))
    if not any(tiers.values()):
        raise ValueError('credits list must contain at least one name')
    return tiers


def wrap(name, width):
    # Preserve every character; long unbroken handles are split, never truncated.
    result = []
    while len(name) > width:
        split = name.rfind(' ', 0, width + 1)
        split = split if split > 0 else width
        result.append(name[:split])
        name = name[split:].lstrip()
    return result + [name]


def compile_list(source, output, columns=48):
    if not 24 <= columns <= 64:
        raise ValueError('visible columns must be between 24 and 64')
    tiers = parse(source)
    scroll_rows = [('MeatCore Credits', 0), ('', 0)]
    subtitle_row = len(scroll_rows)
    subtitle = wrap('Thank you to these Patreon contributors!', columns)
    scroll_rows += [(part, 0) for part in subtitle]
    scroll_rows.append(('', 0))
    underline_rows, name_line_rows = [], []
    for tier, title, color in [('gold', 'Meat Kings', 0), ('meat', 'Meatlovers', 1)]:
        if tiers[tier]:
            scroll_rows.append((title, color))
            underline_rows.append(len(scroll_rows))
            # The renderer draws a continuous rule here. A spaces-only ROM row
            # carries the tier without introducing another glyph/font page.
            scroll_rows += [(' ' * len(title), color), ('', 0)]
            name_width = (columns - 2)//2
            for pair_start in range(0,len(tiers[tier]),2):
                pair = tiers[tier][pair_start:pair_start+2]
                parts = [wrap(name,name_width) for name in pair]
                for line in range(max(map(len,parts))):
                    halves = []
                    for parts_for_name in parts:
                        text = parts_for_name[line] if line < len(parts_for_name) else ''
                        halves.append((' '*((name_width-len(text))//2)+text).ljust(name_width))
                    name_line_rows.append(len(scroll_rows))
                    scroll_rows += [('  '.join(halves).ljust(columns),color), ('', 0)]
    content_end_row = name_line_rows[-1]
    scroll_rows += [('', 0)] * 8
    footer_row = len(scroll_rows)
    scroll_rows += [('THANK YOU', 0)] + [('', 0)] * 8
    scroll_row_bits = max(4, (len(scroll_rows) - 1).bit_length())
    if scroll_row_bits > 12:
        raise ValueError('too many names: maximum scroll sheet is 4096 rows')
    scroll_row_count = 1 << scroll_row_bits
    scroll_rows += [('', 0)] * (scroll_row_count - len(scroll_rows))
    # Layout spacing is a small constant row map, not duplicated character ROM.
    # Every empty spacer and long repeat gap shares one physical blank row.
    rows, row_ids, scroll_row_map = [], {}, []
    for item in scroll_rows:
        if item not in row_ids:
            row_ids[item] = len(rows)
            rows.append(item)
        scroll_row_map.append(row_ids[item])
    row_bits = max(4, (len(rows) - 1).bit_length())
    if row_bits > 12:
        raise ValueError('too many names: maximum scroll sheet is 4096 rows')
    row_count = 1 << row_bits
    rows += [('', 0)] * (row_count - len(rows))
    col_bits = max(5, (columns - 1).bit_length())
    stride = 1 << col_bits
    glyphs = [' '] + sorted(set(''.join(t for t, _ in rows)) - {' '})
    glyph_bits = max(1, (len(glyphs) - 1).bit_length())
    # A row needs only one font bank and one tier bit. Small row alphabets
    # fit 32-glyph pages and the M10K's efficient 2048x5 geometry. Unusually
    # varied rows automatically use the full alphabet instead.
    alphabets = [set(text) | {' '} for text, _ in rows]
    banks, row_banks = [], [0] * row_count
    uppercase = set().union(*(alphabet for alphabet, (text, _) in zip(alphabets, rows)
                              if text == text.upper()))
    mixed_case = set().union(*(alphabet for alphabet, (text, _) in zip(alphabets, rows)
                               if text != text.upper()))
    if glyph_bits > 5 and max(len(uppercase), len(mixed_case)) <= 32:
        banks = [uppercase, mixed_case]
        row_banks = [int(text != text.upper()) for text, _ in rows]
        glyph_bits = 5
    elif glyph_bits > 5 and max(map(len, alphabets)) <= 32:
        for row in sorted(range(row_count), key=lambda i: (-len(alphabets[i]), i)):
            candidates = [(len(alphabets[row] - bank), i) for i, bank in enumerate(banks)
                          if len(bank | alphabets[row]) <= 32]
            if candidates:
                bank_id = min(candidates)[1]
                banks[bank_id].update(alphabets[row])
            else:
                bank_id = len(banks)
                banks.append(set(alphabets[row]))
            row_banks[row] = bank_id
        glyph_bits = 5
    else:
        banks = [set(glyphs)]
    bank_bits = max(1, (len(banks) - 1).bit_length())
    bank_glyphs = [[' '] + sorted(bank - {' '}) for bank in banks]
    bank_ids = [{c: i for i, c in enumerate(bank)} for bank in bank_glyphs]
    cells = []
    for row, (text, color) in enumerate(rows):
        centered = ' ' * ((columns - len(text)) // 2) + text
        centered = centered.ljust(stride)
        cells.extend(bank_ids[row_banks[row]][c] for c in centered)
    font = []
    for bank in bank_glyphs:
        for i in range(1 << glyph_bits):
            font += [int(r, 2) for r in PATTERNS[bank[i] if i < len(bank) else ' '].split('/')] + [0]
    # Put font rows in unused columns when they fit. For 48 columns in a
    # 64-column stride, {row,column} addresses both data sets without adders.
    gap = stride - columns
    gap_bits = gap.bit_length() - 1
    use_gaps = gap > 0 and row_count * (1 << gap_bits) >= len(font)
    if use_gaps:
        gap_base = stride - (1 << gap_bits)
        memory = [0] * (stride * row_count)
        for row in range(row_count):
            memory[row*stride:row*stride+columns] = cells[row*stride:row*stride+columns]
        # The cells above include padding; insert font data only in that padding.
        for i, value in enumerate(font):
            memory[(i >> gap_bits)*stride + gap_base + (i & ((1 << gap_bits)-1))] = value
        address_bits = col_bits + row_bits
        font_base = None
        font_index = (f'(({{bank_q, font_addr}} >> {gap_bits}) << {col_bits}) | '
                      f'{address_bits}\'d{gap_base} | '
                      f'({{bank_q, font_addr}} & {address_bits}\'d{(1 << gap_bits)-1})')
    else:
        # Remove padding for geometries that cannot share unused columns.
        cells = [value for row in range(row_count)
                 for value in cells[row*stride:row*stride+columns]]
        stride = columns
        font_base = len(cells)
        address_bits = (font_base + len(font) - 1).bit_length()
        memory = cells + font
        memory += [0] * ((1 << address_bits) - len(memory))
        font_index = f"{address_bits}'d{font_base} + {{bank_q, font_addr}}"
    tier_mask = sum(color << i for i, (_, color) in enumerate(rows))
    bank_mask = sum(bank << (i * bank_bits) for i, bank in enumerate(row_banks))
    scroll_map_mask = sum(row << (i * row_bits) for i, row in enumerate(scroll_row_map))
    underline_mask = sum(1 << row for row in underline_rows)
    (output / 'meatcore_credits.mif').parent.mkdir(parents=True, exist_ok=True)
    (output / 'meatcore_credits.mif').write_text(
        f'WIDTH={glyph_bits};\nDEPTH={len(memory)};\nADDRESS_RADIX=UNS;\nDATA_RADIX=UNS;\nCONTENT BEGIN\n' +
        ''.join(f'{i} : {v};\n' for i, v in enumerate(memory)) + 'END;\n', encoding='ascii')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'credits_layout.vh').write_text(
        '// Generated by tools/generate.py. Do not edit.\n'
        f'localparam integer CREDIT_COLUMNS = {columns};\n'
        f'localparam integer CREDIT_MAP_STRIDE = {stride};\n'
        f'localparam integer CREDIT_COL_BITS = {col_bits};\n'
        f'localparam integer CREDIT_ROW_BITS = {row_bits};\n'
        f'localparam integer CREDIT_SCROLL_ROW_BITS = {scroll_row_bits};\n'
        f'localparam integer CREDIT_SUBTITLE_ROW = {subtitle_row};\n'
        f'localparam integer CREDIT_SUBTITLE_LINES = {len(subtitle)};\n'
        f'localparam integer CREDIT_FOOTER_SCROLL_ROW = {footer_row};\n'
        f"localparam [{scroll_row_count*row_bits-1}:0] CREDIT_ROW_MAP = {scroll_row_count*row_bits}'h{scroll_map_mask:x};\n"
        f"localparam [{scroll_row_count-1}:0] CREDIT_UNDERLINE_ROWS = {scroll_row_count}'h{underline_mask:x};\n"
        f'localparam integer CREDIT_GLYPH_BITS = {glyph_bits};\n'
        f'localparam integer CREDIT_ADDRESS_BITS = {address_bits};\n', encoding='ascii')
    assignments = '\n'.join(f"    mem[{i}] = {glyph_bits}'d{v};" for i, v in enumerate(memory))
    (output / 'credits_rom.sv').write_text(f'''// Generated ROM; initialization is compiled into the RBF.
// Both read ports share one memory. Tier and font page are per-row constants.
module credits_rom(input wire clk, input wire ce,
    input wire [{address_bits-1}:0] map_addr,
    input wire [{row_bits-1}:0] row,
    input wire [{glyph_bits+2}:0] font_addr,
    output wire [{glyph_bits}:0] cell_q, output wire [4:0] font_q);
    localparam [{row_count-1}:0] TIERS = {row_count}'h{tier_mask:x};
    localparam [{row_count*bank_bits-1}:0] BANKS = {row_count*bank_bits}'h{bank_mask:x};
    reg [{bank_bits-1}:0] bank_q;
    reg tier_q;
    wire [{glyph_bits-1}:0] glyph_q, font_word;
    assign cell_q = {{tier_q, glyph_q}};
    assign font_q = font_word[4:0];
    wire [{address_bits-1}:0] font_index = {font_index};
    always @(posedge clk) if (ce) begin
        tier_q <= TIERS[row];
        bank_q <= BANKS[row*{bank_bits} +: {bank_bits}];
    end
`ifdef ALTERA_RESERVED_QIS
    // Explicit TDP prevents Quartus 17 from duplicating a read-only HDL array.
    // The MIF is a build input; its contents live inside the programmed RBF.
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"), .intended_device_family("Cyclone V"),
        .lpm_type("altsyncram"),
        .ram_block_type("M10K"), .width_a({glyph_bits}), .width_b({glyph_bits}),
        .widthad_a({address_bits}), .widthad_b({address_bits}),
        .numwords_a({len(memory)}), .numwords_b({len(memory)}),
        .address_reg_b("CLOCK0"), .indata_reg_b("CLOCK0"),
        .wrcontrol_wraddress_reg_b("CLOCK0"),
        .outdata_reg_a("UNREGISTERED"), .outdata_reg_b("UNREGISTERED"),
        .clock_enable_input_a("NORMAL"), .clock_enable_input_b("NORMAL"),
        .clock_enable_output_a("BYPASS"), .clock_enable_output_b("BYPASS"),
        .init_file("meatcore_credits.mif"), .power_up_uninitialized("FALSE")
    ) storage (
        .clock0(clk), .clocken0(ce),
        .aclr0(1'b0), .aclr1(1'b0), .address_a(map_addr), .address_b(font_index),
        .data_a({glyph_bits}'d0), .data_b({glyph_bits}'d0),
        .wren_a(1'b0), .wren_b(1'b0), .rden_a(1'b1), .rden_b(1'b1),
        .byteena_a(1'b1), .byteena_b(1'b1),
        .addressstall_a(1'b0), .addressstall_b(1'b0),
        .q_a(glyph_q), .q_b(font_word));
`else
    // Portable simulation model with exactly the same two enabled read ports.
    reg [{glyph_bits-1}:0] mem [0:{len(memory)-1}];
    reg [{glyph_bits-1}:0] sim_glyph, sim_font;
    assign glyph_q = sim_glyph;
    assign font_word = sim_font;
    initial begin
{assignments}
    end
    always @(posedge clk) if (ce) begin
        sim_glyph <= mem[map_addr];
        sim_font <= mem[font_index];
    end
`endif
endmodule
''', encoding='ascii')
    metadata = {'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                'visible_columns': columns, 'stride': stride, 'rows': row_count,
                'cell_width':6, 'cell_height':8, 'name_columns':2,
                'glyph_count': len(glyphs), 'map_bits_per_cell': glyph_bits,
                'font_banks': bank_glyphs, 'row_banks': row_banks,
                'font_base': font_base, 'address_bits': address_bits,
                'font_in_column_gaps': use_gaps,
                'rom_bits': len(memory) * glyph_bits,
                'row_metadata_bits': row_count * (bank_bits + 1),
                'names': tiers, 'display_rows': rows,
                'scroll_rows': scroll_rows, 'scroll_row_count': scroll_row_count,
                'scroll_row_map': scroll_row_map, 'underline_rows': underline_rows,
                'name_line_rows': name_line_rows, 'subtitle_row': subtitle_row,
                'subtitle_lines': len(subtitle), 'footer_row': footer_row,
                'content_end_row': content_end_row, 'scroll_direction': 'up',
                'scroll_metadata_bits': scroll_row_count * (row_bits + 1),
                'glyphs': glyphs, 'font_rows': font}
    (output / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n', encoding='utf-8')
    print(f'Compiled {sum(map(len, tiers.values()))} names: {stride}x{row_count} packed cells, '
          f'{len(glyphs)} glyphs, {metadata["rom_bits"]} ROM bits. Runtime files: none.')
    return metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument('--input', type=Path, default=root / 'credits.txt')
    parser.add_argument('--output', type=Path, default=root / 'credits' / 'generated')
    parser.add_argument('--columns', type=int, default=48)
    args = parser.parse_args()
    try:
        compile_list(args.input, args.output, args.columns)
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Credits generator: {exc}\n')


if __name__ == '__main__':
    main()
