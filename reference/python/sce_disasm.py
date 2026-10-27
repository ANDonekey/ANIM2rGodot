import struct, sys, os, bisect
sys.path.insert(0, '.')
import sce_token as T
import sce_parse as P
from sce_export import run, pool, off2name, lab_offs, scene_of, CODE_END, POOL

MNEM = {
    0x0a: 'Label', 0x0b: 'Goto', 0x0c: 'Gosub', 0x0d: 'Return',
    0x19: 'FlagAdd', 0x1a: 'FlagSub', 0x1b: 'FlagMul', 0x1c: 'FlagDiv',
    0x1d: 'FlagMod', 0x1e: 'FlagSet', 0x22: 'FlagLoad', 0x26: 'FlagRand',
    0x27: 'JumpIfEq', 0x28: 'JumpIfNe', 0x29: 'JumpIfLt', 0x2a: 'JumpIfGt',
    0x2b: 'JumpIfLe', 0x2c: 'JumpIfGe',
    0x3a: 'JumpIfEq', 0x3b: 'JumpIfNe', 0x3c: 'JumpIfLt', 0x3d: 'JumpIfGt',
    0x3e: 'JumpIfLe', 0x3f: 'JumpIfGe',
    0x2d: 'GosubIfEq?', 0x2e: 'GosubIfNe?', 0x2f: 'GosubIfLt?', 0x30: 'GosubIfGt?',
    0x31: 'GosubIfLe?', 0x32: 'GosubIfGe?',
    0x52: 'CgCmd52', 0x5f: 'CgCmd5F', 0x67: 'ParamSet?', 0x68: 'ParamSet',
    0x7c: 'CgCmd7C', 0xb2: 'StackCmd', 0xb3: 'StackCmd',
    0xc0: 'Select', 0xc8: 'Select', 0xd2: 'Text2', 0xd3: 'Text', 0xd4: 'TextAlt',
    0xd5: 'TextNarr', 0xd6: 'TextBlock', 0xdc: 'SceneEnd?',
}
STRIDX_OPS = {0x52: 1, 0x5f: 1, 0x7d: 1, 0x7e: 1, 0x80: 1, 0x56: 1, 0x62: 1}

def fmt_e(v):
    if isinstance(v, tuple):
        if v[0] == 'imm':
            return 'imm %d (tag %02x)' % (v[2], v[1])
        if v[0] == 'flag':
            return '%s[%d]' % (v[1], v[2])
    return repr(v)

def fmt_ops(r):
    op = r.op
    o = r.ops
    if op == 0x0a:
        return '"%s"' % o[0]
    if op in (0x0b, 0x0c):
        names = off2name.get(o[0])
        return '-> %d%s' % (o[0], ' (%s)' % names[0] if names else '')
    if op == 0xd3 or op == 0xd4:
        return 'name=%d "%s" text=%d "%s" seq=%d' % (o[0], P.pool_str(pool, o[0]), o[1], P.pool_str(pool, o[1]), o[2])
    if op == 0xd5:
        return 'text=%d "%s" seq=%d' % (o[0], P.pool_str(pool, o[0]), o[1])
    if op == 0xd2:
        return 'x=%d "%s" name=%d "%s" text=%d "%s" seq=%d' % (
            o[0], P.pool_str(pool, o[0]), o[1], P.pool_str(pool, o[1]), o[2], P.pool_str(pool, o[2]), o[3])
    if op in (0xc0, 0xc8):
        pairs = o[0][1]
        return ' '.join('[->%d "%s"]' % (t, P.pool_str(pool, s)) for t, s in pairs)
    if op in (0xb2, 0xb3):
        _k, v0, entries = o[0]
        parts = ['head=%s' % fmt_e(v0)]
        for tag, sub, params in entries:
            pp = []
            for i, pv in enumerate(params):
                if sub == 0xb6 and i == 1 and isinstance(pv, int):
                    pp.append('%d "%s"' % (pv, P.pool_str(pool, pv)))
                elif isinstance(pv, tuple):
                    pp.append(fmt_e(pv))
                else:
                    pp.append(str(pv))
            parts.append('(%d sub=%02x %s)' % (tag, sub, ' '.join(pp)))
        return ' '.join(parts)
    if op == 0xd6:
        return repr(o)
    parts = []
    for i, v in enumerate(o):
        if isinstance(v, tuple) and v and v[0] in ('imm', 'flag'):
            parts.append(fmt_e(v))
        elif op in STRIDX_OPS and i == STRIDX_OPS[op] and isinstance(v, int):
            parts.append('%d "%s"' % (v, P.pool_str(pool, v)))
        elif op in MNEM and MNEM[op].startswith(('Jump', 'Gosub')) and i == len(o) - 1 and isinstance(v, int):
            names = off2name.get(v)
            parts.append('->%d%s' % (v, ' (%s)' % names[0] if names else ''))
        else:
            parts.append(repr(v) if isinstance(v, float) else str(v))
    return ' '.join(parts)

d = open('sce_orig_dec.bin', 'rb').read()
labels, segs = T.segments(d, CODE_END, POOL)
with open('../out/kabe2_disasm.txt', 'w', encoding='utf-8') as f:
    f.write('# kabe2_sce.dat full instruction-stream disassembly (decrypted orig)\n')
    f.write('# code region [0,%d) label table [%d,%d) string pool [%d,%d)\n\n' % (CODE_END, CODE_END, POOL, POOL, len(d)))
    for (a, b) in segs:
        if a > CODE_END:
            continue
        names = off2name.get(a, [])
        f.write('\n===== segment @%d %s =====\n' % (a, ' '.join(names) if names else ('<init>' if a == 0 else '')))
        recs, bad = P.parse_segment(d, a, b)
        for r in recs:
            raw = d[r.off:r.end]
            hexs = raw.hex() if len(raw) <= 40 else raw[:40].hex() + '..'
            f.write('%6d  %02x  %-10s %-60s ; %s\n' % (r.off, r.op, MNEM.get(r.op, 'op_%02x' % r.op), fmt_ops(r), hexs))
        if bad is not None:
            f.write('!! parse stopped at %d\n' % bad)
print('disasm written')

# ---- nanfang cross-validation
dn = open('sce_nanfang_dec.bin', 'rb').read()
CE2, PO2 = struct.unpack('<II', dn[:8])
print('nanfang header: code_end=%d pool=%d size=%d' % (CE2, PO2, len(dn)))
labels_n, segs_n = T.segments(dn, CE2, PO2)
ok = 0; bad_segs = []
for (a, b) in segs_n:
    if a > CE2:
        continue
    recs, bad = P.parse_segment(dn, a, b)
    if bad is None:
        ok += 1
    else:
        bad_segs.append((a, b, bad))
print('nanfang segments tiled: %d/%d, fails: %s' % (ok, len([s for s in segs_n if s[0] <= CE2]), bad_segs[:5]))
