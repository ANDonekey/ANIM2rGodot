"""Full record-level parser for ANIM sce (uses sce_token v2 signatures)."""
import struct
import sce_token as T

class Rec:
    __slots__ = ('off', 'op', 'ops', 'end')

    def __init__(self, off, op, ops, end):
        self.off, self.op, self.ops, self.end = off, op, ops, end

    def __repr__(self):
        return '<Rec @%d op=%02x %r>' % (self.off, self.op, self.ops)

def parse_expr(d, q):
    tag = d[q]
    q += 1
    if tag in T.IDX_TAGS:
        idx = struct.unpack('<H', d[q:q + 2])[0]
        return ('flag', '@' if tag == 0x40 else 'A', idx), q + 2
    val = struct.unpack('<I', d[q:q + 4])[0]
    return ('imm', tag, val), q + 4

def parse_stack(d, q, limit):
    """op b2/b3 body from q (after opcode). Returns (value, end)."""
    v0, q = parse_expr(d, q)
    entries = []
    while True:
        tag = struct.unpack('<I', d[q:q + 4])[0]
        q += 4
        if tag == 0xbc:
            break
        sub = d[q]
        q += 1
        params = []
        if sub == 0xba:
            a = d[q]; b = struct.unpack('<H', d[q + 1:q + 3])[0]; t = d[q + 3]
            q += 4
            if t == 0x43:
                v = struct.unpack('<I', d[q:q + 4])[0]; q += 4
            else:
                v = struct.unpack('<H', d[q:q + 2])[0]; q += 2
            params = [a, b, t, v]
        else:
            for tt in T.SUBPARAMS.get(sub, ()):
                if tt == 'E':
                    v, q = parse_expr(d, q)
                    params.append(v)
                elif tt == '1':
                    params.append(d[q]); q += 1
                elif tt == '2':
                    params.append(struct.unpack('<H', d[q:q + 2])[0]); q += 2
                elif tt == '4':
                    params.append(struct.unpack('<I', d[q:q + 4])[0]); q += 4
        entries.append((tag, sub, params))
    return ('stack', v0, entries), q

def parse_record(d, p, limit):
    op = d[p]
    sig = T.sig_options(op)
    if not sig:
        return None
    sig = sig[0]
    q = p + 1
    ops = []
    for t in sig:
        if t == 'S':
            e = d.find(b'\x00', q, limit)
            ops.append(d[q:e].decode('ascii'))
            q = e + 1
        elif t == '1':
            ops.append(d[q]); q += 1
        elif t == '2':
            ops.append(struct.unpack('<H', d[q:q + 2])[0]); q += 2
        elif t == '4':
            ops.append(struct.unpack('<I', d[q:q + 4])[0]); q += 4
        elif t == '8':
            ops.append(struct.unpack('<d', d[q:q + 8])[0]); q += 8
        elif t == 'E':
            v, q = parse_expr(d, q)
            ops.append(v)
        elif t == 'T':
            v = d[p + 1]
            tail = {0x28: ('u8x5', list(d[q:q + 5])), 0x46: ('u32', struct.unpack('<I', d[q:q + 4])[0]),
                    0x47: ('u32x4', list(struct.unpack('<IIII', d[q:q + 16])))}.get(v)
            if tail:
                ops.append(tail)
                q += {0x28: 5, 0x46: 4, 0x47: 16}[v]
        elif t == 'K':
            v, q = parse_stack(d, q, limit)
            ops.append(v)
        elif t == 'C':
            n = d[q]; q += 1
            pairs = []
            for _ in range(n):
                tgt, sidx = struct.unpack('<II', d[q:q + 8])
                pairs.append((tgt, sidx))
                q += 8
            ops.append(('select', pairs))
        elif t == 'D':
            entries = []
            while True:
                c = d[q]; q += 1
                if c == 0xd7:
                    break
                if c == 0xd3:
                    # interpreter (FUN_004374e0 case 0xd6): u32 speaker,
                    # u32 text, u16 seq = 10 bytes after the tag
                    a, b, s = struct.unpack('<IIH', d[q:q + 10])
                    entries.append(('line', a, b, s))
                    q += 10
                elif c == 0xd8:
                    # pending render parameter for the next line entry
                    v = struct.unpack('<I', d[q:q + 4])[0]
                    entries.append(('param', v))
                    q += 4
                else:
                    return None
            ops.append(('textblock', entries))
    return Rec(p, op, ops, q)

def parse_segment(d, a, b):
    recs = []
    p = a
    while p < b:
        r = parse_record(d, p, b)
        if r is None or r.end > b or r.end <= p:
            return recs, p  # partial + failure offset
        recs.append(r)
        p = r.end
    return recs, None

def load_pool(d, pool_off):
    pool = []
    pos = pool_off
    while pos < len(d):
        e = d.find(b'\x00', pos)
        if e == -1:
            break
        pool.append((pos, d[pos:e]))
        pos = e + 1
    return pool

def pool_str(pool, idx):
    if 0 <= idx < len(pool):
        try:
            return pool[idx][1].decode('cp932')
        except Exception:
            return pool[idx][1].decode('cp932', 'replace')
    return '<idx %d out of range>' % idx
