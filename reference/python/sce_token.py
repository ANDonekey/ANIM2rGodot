"""ANIM (teamMM) sce tokenizer - signature table v2.
Derived from: REA/Ghidra decompile of the interpreter FUN_004374e0 in kabetuma2_GPT.exe,
asm path analysis of its handlers, and byte-exact tiling validation against kabe2_sce.dat.

Tokens: '1'=U8 '2'=U16 '4'=U32 '8'=F64 'E'=expr 'S'=asciiz label name
        'T'=value-dependent tail (op 0x67/0x68) 'K'=stack-command composite (op 0xb2/0xb3)
        'C'=select composite (op 0xc0/0xc8)   'D'=text-block composite (op 0xd6)
EXPR (FUN_0043e300 ReadValue): U8 tag; tag 0x40/0x41 -> +U16 flag index (read in resolver
FUN_0043e350); any other tag -> +U32 immediate.
"""
import struct

IDX_TAGS = {0x40, 0x41}
TSIZE = {'1': 1, '2': 2, '4': 4, '8': 8}

FIXED = {
    0x02: ('1',), 0x03: (), 0x04: (), 0x05: (),
    0x0b: ('4',), 0x0c: ('4',), 0x0d: (), 0x0e: (), 0x0f: (),
    0x14: ('4',), 0x15: (), 0x16: ('4',),
    0x19: ('1', '2', 'E'), 0x1a: ('1', '2', 'E'), 0x1b: ('1', '2', 'E'),
    0x1c: ('1', '2', 'E'), 0x1d: ('1', '2', 'E'), 0x1e: ('1', '2', 'E'),
    0x1f: ('4',), 0x20: ('4',), 0x21: ('4',), 0x22: ('1', '2'),
    0x26: ('1', '2', '4', '4'),
    0x27: ('1', '2', 'E', '4'), 0x28: ('1', '2', 'E', '4'), 0x29: ('1', '2', 'E', '4'),
    0x2a: ('1', '2', 'E', '4'), 0x2b: ('1', '2', 'E', '4'), 0x2c: ('1', '2', 'E', '4'),
    0x2d: ('1', '2', 'E', '4'), 0x2e: ('1', '2', 'E', '4'), 0x2f: ('1', '2', 'E', '4'),
    0x30: ('1', '2', 'E', '4'), 0x31: ('1', '2', 'E', '4'), 0x32: ('1', '2', 'E', '4'),
    0x3a: ('1', '2', 'E', '4'), 0x3b: ('1', '2', 'E', '4'), 0x3c: ('1', '2', 'E', '4'),
    0x3d: ('1', '2', 'E', '4'), 0x3e: ('1', '2', 'E', '4'), 0x3f: ('1', '2', 'E', '4'),
    0x4b: ('4',), 0x4c: ('4',), 0x4d: ('E', 'E', 'E'),
    0x4e: ('E', 'E', '8', '8', '8', '8', '8', '8'),
    0x4f: ('4', 'E', 'E', 'E', 'E', 'E', 'E', 'E', 'E'),
    0x50: ('E', 'E', 'E', 'E', 'E'), 0x51: (),
    0x52: ('E', '4'), 0x53: ('1', 'E', 'E'), 0x54: ('1', 'E', 'E'),
    0x55: ('1', '1', '1', '1', '1'), 0x56: ('1', '4'), 0x57: ('E',), 0x58: (),
    0x59: ('E', 'E', 'E', '1', 'E'), 0x5a: ('E', 'E', 'E', '8', '8', '8', '8', '8', '8'),
    0x5b: ('E', 'E', 'E', '1', 'E', '8'), 0x5c: ('1', 'E', 'E', '1', '4'),
    0x5d: ('4',), 0x5e: ('8', '8', '8'), 0x5f: ('E', '4'), 0x60: ('E', 'E', 'E', '1', 'E'),
    0x61: ('E', '4', '4'), 0x62: ('1', '4', 'E', 'E', 'E', 'E', 'E', 'E', 'E', 'E'),
    0x63: ('1', '2', '2', 'E', 'E', 'E', 'E', 'E', '1', '4'), 0x64: ('1', 'E', 'E', 'E', '1'),
    0x65: (), 0x66: (), 0x67: ('1', '4', 'T'), 0x68: ('1', '4', 'T'),
    0x69: ('4', '4', '4'), 0x6a: ('2',), 0x6c: (), 0x6d: ('4',), 0x6e: (), 0x6f: (),
    0x70: ('4',), 0x71: ('1', '1', '1'), 0x72: ('1', '1', '1'), 0x73: ('1', '1', '1'),
    0x74: ('4', '4'), 0x75: ('E', 'E', 'E', 'E', 'E'), 0x77: ('E', 'E', 'E'),
    0x78: ('4', '4', '4', '4'), 0x79: ('E', 'E', 'E', 'E'), 0x7a: ('4', '4', '4', '4'),
    0x7b: ('E', 'E', 'E', 'E'), 0x7c: ('E', '4', '4'), 0x7d: ('E', '4'), 0x7e: ('E', '4'),
    0x7f: ('E',), 0x80: ('E', '4'),
    0x82: ('1',), 0x83: (), 0x84: ('2',), 0x85: ('1',), 0x86: ('4',), 0x87: (),
    0x88: ('2', '4'), 0x89: ('2',), 0x8a: (), 0x8b: ('2', '4'), 0x8c: ('2',), 0x8d: (),
    0x8e: ('4', '4'), 0x8f: ('4', '4'), 0x90: ('4', '4', 'E'), 0x91: (),
    0x92: ('E',),  # interpreter case 0x92 evaluates one EXPR unconditionally
    0x96: ('4',), 0x97: ('4',), 0x98: (), 0x99: (), 0x9a: (),
    0x9b: ('E',), 0x9c: ('E',), 0x9d: ('4',), 0x9f: ('1',),
    0xa0: (), 0xa1: (), 0xa2: ('1', '2'), 0xa3: ('2', '1', '2'), 0xa4: ('1', '2'),
    0xa5: ('1', '2'), 0xa6: ('1', '2'), 0xa7: ('1', '2'), 0xa8: ('4', '1', '2'),
    0xa9: ('1', '2'), 0xaa: ('1', '1'), 0xab: ('4',), 0xac: ('E', 'E'),
    0xad: ('1', '2', '1', '2'), 0xae: (), 0xaf: (), 0xb0: (), 0xb1: (),
    0xb2: ('K',), 0xb3: ('K',), 0xbd: ('E',), 0xbe: ('E',), 0xbf: ('E',),
    0xc0: ('C',), 0xc8: ('C',), 0xc9: ('1',), 0xcb: (), 0xcc: (), 0xcd: (), 0xce: (),
    0xd2: ('4', '4', '4', '2', '2'), 0xd3: ('4', '4', '2', '2'),
    0xd4: ('4', '4', '2', '2'), 0xd5: ('4', '2', '2'), 0xd6: ('D',),
    0xdc: ('4', '4'),
}
CANDS = {}

def sig_options(op):
    if op == 0x0a:
        return [('S',)]
    if op < 2 or op > 0xdc:
        return []
    if op in FIXED:
        return [FIXED[op]]
    if op in CANDS:
        return CANDS[op]
    return [()]

def expr_end(d, q, limit):
    if q >= limit:
        return None
    tag = d[q]
    q += 1
    q += 2 if tag in IDX_TAGS else 4
    return q if q <= limit else None

SUBPARAMS = {
    0xb4: ('E', 'E', 'E', '1', 'E'),
    0xb5: (),
    0xb6: ('E', '4', '4'),
    0xb7: ('4', '4', '4', '4'),
    0xb8: ('E', 'E', 'E'),
    0xbb: ('2', '4'),
}

def stack_end(d, p, limit):
    q = expr_end(d, p + 1, limit)
    if q is None:
        return None
    while True:
        if q + 4 > limit:
            return None
        tag = struct.unpack('<I', d[q:q + 4])[0]
        q += 4
        if tag == 0xbc:
            return q
        if q >= limit:
            return None
        sub = d[q]
        q += 1
        if sub == 0xba:
            if q + 4 > limit:
                return None
            t = d[q + 3]
            q += 4 + (4 if t == 0x43 else 2)
            if q > limit:
                return None
            continue
        for tt in SUBPARAMS.get(sub, ()):
            if tt == 'E':
                q = expr_end(d, q, limit)
                if q is None:
                    return None
            else:
                q += TSIZE[tt]
            if q > limit:
                return None

def select_end(d, p, limit):
    q = p + 1
    if q >= limit:
        return None
    n = d[q]
    q += 1 + n * 8
    return q if q <= limit else None

def textblock_end(d, p, limit, entry3_len=10):
    q = p + 1
    for _ in range(100000):
        if q >= limit:
            return None
        c = d[q]
        q += 1
        if c == 0xd7:
            return q
        if c == 0xd3:
            q += entry3_len
        elif c == 0xd8:
            q += 4
        else:
            return None
        if q > limit:
            return None
    return None

def rec_end(d, p, sig, limit):
    q = p + 1
    for t in sig:
        if t == 'S':
            e = d.find(b'\x00', q, limit)
            if e == -1:
                return None
            q = e + 1
        elif t == 'E':
            q = expr_end(d, q, limit)
            if q is None:
                return None
        elif t == 'K':
            q = stack_end(d, p, limit)
            if q is None:
                return None
        elif t == 'C':
            q = select_end(d, p, limit)
            if q is None:
                return None
        elif t == 'D':
            q = textblock_end(d, p, limit)
            if q is None:
                return None
        elif t == 'T':
            v = d[p + 1]
            q += {0x28: 5, 0x46: 4, 0x47: 16}.get(v, 0)
        else:
            q += TSIZE[t]
        if q > limit:
            return None
    return q

def load_labels(d, code_end, pool_off):
    labels = []
    pos = code_end
    while pos < pool_off:
        e = d.find(b'\x00', pos)
        s = d[pos:e].decode()
        v = struct.unpack('<I', d[e + 1:e + 5])[0]
        labels.append((s, v))
        pos = e + 5
    return labels

def segments(d, code_end, pool_off):
    labels = load_labels(d, code_end, pool_off)
    offs = sorted(set(v for _, v in labels))
    segs = [(8, offs[0])] + [(offs[i], offs[i + 1]) for i in range(len(offs) - 1)] + [(offs[-1], code_end)]
    return labels, segs
