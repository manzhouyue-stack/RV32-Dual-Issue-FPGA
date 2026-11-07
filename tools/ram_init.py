"""Convert a complete 8192x32 image to the accepted Pango RAM INIT layout."""


def encode_init(words):
    if len(words) != 8192 or any(not isinstance(w, int) or not 0 <= w <= 0xFFFFFFFF for w in words):
        raise ValueError('Expected exactly 8192 unsigned 32-bit words')
    lines = ['// Generated from a complete 8192x32 image; 4 address banks, 2 data lanes.',
             '// Each physical 18-bit entry has data bytes at [7:0] and [16:9].']
    for bank in range(4):
        for lane in range(2):
            for chunk in range(128):
                value = 0
                for offset in range(16):
                    word = words[bank * 2048 + chunk * 16 + offset]
                    half = (word >> (16 * lane)) & 0xFFFF
                    physical = (half & 0xFF) | ((half >> 8) << 9)
                    value |= physical << (18 * offset)
                lines.append(f"localparam INIT_{chunk:02X}_{bank}_{lane} = 288'h{value:072x};")
    for chunk in range(128):
        parts = [f'INIT_{chunk:02X}_{bank}_{lane}' for bank in range(3, -1, -1) for lane in (1, 0)]
        lines.append(f'localparam INIT_{chunk:02X} = {{ ' + ', '.join(parts) + ' };')
    return '\n'.join(lines) + '\n'


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image', type=Path, help='Exactly 8192 hexadecimal 32-bit words')
    parser.add_argument('header', type=Path, help='Generated vendor INIT parameter header')
    args = parser.parse_args()
    words = [int(word, 16) for word in args.image.read_text(encoding='ascii').split()]
    args.header.write_text(encode_init(words), encoding='ascii')
