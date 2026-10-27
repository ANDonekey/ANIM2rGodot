import struct, sys, os, json
sys.path.insert(0, '.')
import sce_token as T
import sce_parse as P

os.makedirs('../out', exist_ok=True)

def load(fn):
    d = open(fn, 'rb').read()
    code_end, pool_off = struct.unpack('<II', d[:8])
    return d, code_end, pool_off

def run(fn, tag):
    d, CODE_END, POOL = load(fn)
    labels, segs = T.segments(d, CODE_END, POOL)
    pool = P.load_pool(d, POOL)
    off2name = {}
    for n, v in labels:
        if v <= CODE_END:
            off2name.setdefault(v, []).append(n)
    all_recs = []
    fails = []
    for (a, b) in segs:
        if a > CODE_END:
            continue
        recs, bad = P.parse_segment(d, a, b)
        all_recs.extend(recs)
        if bad is not None:
            fails.append((a, b, bad))
    print('%s: code_end=%d pool=%d labels=%d pool_entries=%d records=%d seg_fails=%s' % (
        tag, CODE_END, POOL, len(labels), len(pool), len(all_recs), fails[:5]))
    return d, CODE_END, POOL, labels, pool, off2name, all_recs, segs

d, CODE_END, POOL, labels, pool, off2name, recs, segs = run('sce_orig_dec.bin', 'orig')

# ---- op usage stats
from collections import Counter
opc = Counter(r.op for r in recs)
print('distinct ops used:', len(opc), 'd6 count:', opc.get(0xd6, 0), 'd3:', opc.get(0xd3, 0),
      'd5:', opc.get(0xd5, 0), 'd2:', opc.get(0xd2, 0), 'd4:', opc.get(0xd4, 0))

# ---- dialogue export
def seg_name(off):
    names = off2name.get(off)
    return names[0] if names else '?'

# map each record to its segment label (largest label offset <= rec.off)
lab_offs = sorted(off2name)
import bisect
def scene_of(off):
    i = bisect.bisect_right(lab_offs, off) - 1
    return seg_name(lab_offs[i]) if i >= 0 else '<init>'

lines = []
speakers = Counter()
INIT_END = segs[1][0] if len(segs) > 1 else 0
for r in recs:
    if r.off < INIT_END:
        continue  # init/data section before first label: not dialogue
    sc = scene_of(r.off)
    if r.op == 0xd3:
        name_i, text_i, seq, _z = r.ops
        sp = P.pool_str(pool, name_i)
        speakers[sp] += 1
        lines.append((sc, r.off, seq, sp, P.pool_str(pool, text_i)))
    elif r.op == 0xd4:
        name_i, text_i, seq, _z = r.ops
        sp = P.pool_str(pool, name_i)
        speakers[sp] += 1
        lines.append((sc, r.off, seq, sp, P.pool_str(pool, text_i)))
    elif r.op == 0xd5:
        text_i, seq, _z = r.ops
        lines.append((sc, r.off, seq, '', P.pool_str(pool, text_i)))
    elif r.op == 0xd2:
        x_i, name_i, text_i, seq, _z = r.ops
        sp = P.pool_str(pool, name_i)
        speakers[sp] += 1
        lines.append((sc, r.off, seq, sp, P.pool_str(pool, text_i)))
    elif r.op == 0xd6:
        cur_sp = ''
        for ent in r.ops[0][1]:
            if ent[0] == 'speaker':
                cur_sp = P.pool_str(pool, ent[1])
            else:
                _k, a_i, b_i, seq, _x = ent
                # a_i = text? (FUN_004439a0(0, iVar6, iVar12, ..)) in d6: args are (strA, strB) -> treat a as name if it matches a known speaker else text
                sa = P.pool_str(pool, a_i)
                sb = P.pool_str(pool, b_i)
                lines.append((sc, r.off, seq, cur_sp or sa, sb))

print('dialogue lines:', len(lines))
print('top speakers:', speakers.most_common(12))
with open('../out/kabe2_dialogue.txt', 'w', encoding='utf-8') as f:
    f.write('# kabe2_sce dialogue export (orig, Japanese)\n')
    f.write('# total lines: %d\n\n' % len(lines))
    cur = None
    for sc, off, seq, sp, tx in lines:
        if sc != cur:
            f.write('\n===== %s =====\n' % sc)
            cur = sc
        if sp:
            f.write('%s：%s\n' % (sp, tx))
        else:
            f.write('%s\n' % tx)

# ---- pool export
with open('../out/kabe2_pool.txt', 'w', encoding='utf-8') as f:
    f.write('# string pool of kabe2_sce.dat (decrypted): %d entries, pool offset %d\n' % (len(pool), POOL))
    for i, (off, raw) in enumerate(pool):
        try:
            s = raw.decode('cp932')
        except Exception:
            s = raw.decode('cp932', 'replace')
        f.write('%d\t%d\t%s\n' % (i, off, s.replace('\t', ' ')))
print('pool written')
json.dump({'records': len(recs), 'lines': len(lines)}, open('../out/stats.json', 'w'))
