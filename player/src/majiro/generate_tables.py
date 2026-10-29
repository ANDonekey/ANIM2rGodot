#!/usr/bin/env python3
"""Generate the Majiro legacy-encoding tables (cp932.b64 / gbk.b64).

The .b64 files next to this script are base64(gzip(table)); the table is
256 u16 single-byte entries (0xFFFF marks a double-byte lead) followed by
65536 u16 pair codepoints indexed by (lead << 8) | trail, 0xFFFD for
unmapped pairs. Requires Python's cp932/gbk codecs. Deterministic output
(raw table md5: cp932 ef66550d143626704feddee2ee4c92c3,
gbk d5dc195eeecd7d352642df22783efba8).
"""
import base64, gzip, io, struct

def build(codec, singles_fn):
    singles = [singles_fn(b) for b in range(256)]
    pairs = [0xFFFD] * 65536
    for lead in range(256):
        if singles[lead] != 0xFFFF:
            continue
        for trail in range(256):
            try:
                s = bytes([lead, trail]).decode(codec)
            except Exception:
                continue
            if s and ord(s[0]) <= 0xFFFF:
                pairs[(lead << 8) | trail] = ord(s[0])
    return struct.pack('<256H', *singles) + struct.pack('<65536H', *pairs)

def cp932_single(b):
    if b < 0x80: return b
    if 0xA1 <= b <= 0xDF: return 0xFF61 + (b - 0xA1)
    if (0x81 <= b <= 0x9F) or (0xE0 <= b <= 0xFC): return 0xFFFF
    return 0xFFFD

def gbk_single(b):
    if b < 0x80: return b
    if b == 0x80: return 0x20AC
    if 0x81 <= b <= 0xFE: return 0xFFFF
    return 0xFFFD

for name, codec, fn in (('cp932', 'cp932', cp932_single), ('gbk', 'gbk', gbk_single)):
    raw = build(codec, fn)
    buf = io.BytesIO()
    with gzip.GzipFile(filename='', mode='wb', compresslevel=9, mtime=0, fileobj=buf) as g:
        g.write(raw)
    with open(f'{name}.b64', 'w') as fh:
        fh.write(base64.b64encode(buf.getvalue()).decode())
    print(name, len(raw))
