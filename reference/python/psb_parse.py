#!/usr/bin/env python3
"""PSB (M2 / E-mote) parser - Python port of FreeMote's format logic.

Header (v3, as used by ANIM teamMM games): plain 8-byte prefix
"PSB\\0" + u16 version + u16 encrypt-flag, then 9 u32 fields XORed with
an XorShift128 stream (Key1/2/3 = FreeMote Consts, Key4 = 0x473ab96d,
recovered 2026-10-28 by known-plaintext bit-solving on HeaderLength=44
and verified on all 69 kabe2 PSBs). Body sections are plaintext.

Sections: names (trie), strings, chunks (resources), entries (object
tree). Value tags per FreeMote PsbObjType.
"""
import json
import struct
import sys

M32 = 0xFFFFFFFF
KEY1, KEY2, KEY3, KEY4 = 123456789, 362436069, 521288629, 0x473AB96D


def _keystream(n, key4=KEY4):
    k1, k2, k3, k4 = KEY1, KEY2, KEY3, key4
    cur = 0
    out = bytearray()
    while len(out) < n:
        if cur == 0:
            a = (k1 ^ ((k1 << 11) & M32)) & M32
            c = (a ^ k4 ^ (((a ^ (k4 >> 11)) & M32) >> 8)) & M32
            k1, k2, k3, k4 = k2, k3, k4, c
            cur = c
        out.append(cur & 0xFF)
        cur >>= 8
    return bytes(out)


class PsbArray:
    """[count: n bytes LE][entryLenByte = entryLen + 0x0C][entries]."""

    @staticmethod
    def read(data, pos, width):
        count = int.from_bytes(data[pos:pos + width], 'little')
        pos += width
        entry_len = data[pos] - 0x0C
        pos += 1
        vals = []
        for i in range(count):
            vals.append(int.from_bytes(
                data[pos + i * entry_len: pos + (i + 1) * entry_len], 'little'))
        return vals, pos + count * entry_len


class Psb:
    def __init__(self, data: bytes):
        self.data = data
        assert data[:4] == b'PSB\x00', 'not a PSB'
        self.version, self.encrypt = struct.unpack_from('<HH', data, 4)
        ks = _keystream(36)
        dec = bytes(x ^ y for x, y in zip(data[8:44], ks))
        (self.header_length, self.off_names, self.off_strings,
         self.off_strings_data, self.off_chunk_offsets, self.off_chunk_lengths,
         self.off_chunk_data, self.off_entries,
         self.checksum) = struct.unpack('<9I', dec)
        self._load_names()
        self._load_strings()
        self._load_chunks()

    # ---- sections ----
    def _array_at(self, off):
        tag = self.data[off]
        assert 0x0D <= tag <= 0x14, f'expected array tag at {off}, got {tag:#x}'
        return PsbArray.read(self.data, off + 1, tag - 0x0D + 1)[0]

    def _load_names(self):
        pos = self.off_names
        tag = self.data[pos]
        charset, pos = PsbArray.read(self.data, pos + 1, tag - 0x0D + 1)
        tag = self.data[pos]
        names_data, pos = PsbArray.read(self.data, pos + 1, tag - 0x0D + 1)
        tag = self.data[pos]
        name_indexes, _ = PsbArray.read(self.data, pos + 1, tag - 0x0D + 1)
        self.names = []
        for index in name_indexes:
            out = bytearray()
            chr_ = names_data[index]
            while chr_ != 0:
                code = names_data[chr_]
                out.append(chr_ - charset[code])
                chr_ = code
            out.reverse()
            self.names.append(out.decode('utf-8'))

    def _load_strings(self):
        self.string_offsets = self._array_at(self.off_strings)
        self.strings = []
        for off in self.string_offsets:
            start = self.off_strings_data + off
            end = self.data.index(b'\x00', start)
            self.strings.append(self.data[start:end].decode('utf-8'))

    def _load_chunks(self):
        offs = self._array_at(self.off_chunk_offsets)
        lens = self._array_at(self.off_chunk_lengths)
        self.chunks = [(self.off_chunk_data + o, l) for o, l in zip(offs, lens)]

    def chunk_bytes(self, idx):
        off, ln = self.chunks[idx]
        return self.data[off:off + ln]

    # ---- object tree ----
    def unpack(self, pos):
        data = self.data
        tag = data[pos]
        pos += 1
        if tag == 0x00 or tag == 0x01:
            return None, pos
        if tag == 0x02:
            return False, pos
        if tag == 0x03:
            return True, pos
        if tag == 0x04:
            return 0, pos
        if 0x05 <= tag <= 0x0C:  # NumberN1..8 (zero-padded; signed at full width)
            n = tag - 0x04
            raw = data[pos:pos + n]
            if n == 4:
                return int.from_bytes(raw, 'little', signed=True), pos + n
            if n == 8:
                return int.from_bytes(raw, 'little', signed=True), pos + n
            return int.from_bytes(raw, 'little'), pos + n
        if 0x0D <= tag <= 0x14:  # ArrayN1..8 -> plain list of uints
            return PsbArray.read(data, pos, tag - 0x0D + 1)
        if 0x15 <= tag <= 0x18:  # StringN1..4
            n = tag - 0x14
            idx = int.from_bytes(data[pos:pos + n], 'little')
            return self.strings[idx], pos + n
        if 0x19 <= tag <= 0x1C:  # ResourceN1..4
            n = tag - 0x18
            idx = int.from_bytes(data[pos:pos + n], 'little')
            return {'$res': idx}, pos + n
        if tag == 0x1D:
            return 0.0, pos
        if tag == 0x1E:
            return struct.unpack_from('<f', data, pos)[0], pos + 4
        if tag == 0x1F:
            return struct.unpack_from('<d', data, pos)[0], pos + 8
        if tag == 0x20:  # List: offsets array (with tag), values at base+off
            t2 = data[pos]
            offsets, base = PsbArray.read(data, pos + 1, t2 - 0x0D + 1)
            out = []
            for off in offsets:
                v, _ = self.unpack(base + off)
                out.append(v)
            return out, base
        if tag == 0x21:  # Objects (dictionary)
            t2 = data[pos]
            name_idxs, p2 = PsbArray.read(data, pos + 1, t2 - 0x0D + 1)
            t3 = data[p2]
            offsets, base = PsbArray.read(data, p2 + 1, t3 - 0x0D + 1)
            out = {}
            for ni, off in zip(name_idxs, offsets):
                v, _ = self.unpack(base + off)
                out[self.names[ni]] = v
            return out, base
        if 0x22 <= tag <= 0x25:  # ExtraChunk (v4) - not expected in v3 files
            n = tag - 0x21
            idx = int.from_bytes(data[pos:pos + n], 'little')
            return {'$xres': idx}, pos + n
        raise ValueError(f'unknown tag {tag:#x} at {pos - 1}')

    def root(self):
        v, _ = self.unpack(self.off_entries)
        return v


if __name__ == '__main__':
    src = sys.argv[1]
    psb = Psb(open(src, 'rb').read())
    print(f'version={psb.version} names={len(psb.names)} strings={len(psb.strings)} '
          f'chunks={len(psb.chunks)}')
    root = psb.root()
    print('root type:', type(root).__name__)
    if isinstance(root, dict):
        for k, v in root.items():
            print(' ', k, '->', type(v).__name__,
                  (f'({len(v)} items)' if isinstance(v, (dict, list)) else repr(v)[:60]))
    if len(sys.argv) > 2:
        with open(sys.argv[2], 'w', encoding='utf-8') as f:
            json.dump(root, f, ensure_ascii=False, indent=1, default=str)
        print('wrote', sys.argv[2])
