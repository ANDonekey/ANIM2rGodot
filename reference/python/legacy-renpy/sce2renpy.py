#!/usr/bin/env python3
"""Convert a decrypted ANIM (teamMM) sce to a Ren'Py script.

Mapping (evidence-based; see out/kabe2_sce_format.md and the op/resource
cross-reference run of 2026-10-28):
  segments/labels        -> label blocks (fall-through preserved)
  0x0b Goto / 0x0c Gosub / 0x0d Return -> jump / call / return
  0x1e FlagSet, 0x19-0x1d Add/Sub/Mul/Div/Mod, 0x26 Rand -> $ assignments
       (bank byte 0x40 -> lf_<idx>, 0x41 -> gf_<idx>; EXPR flags likewise)
  0x27-0x2c JumpIf Eq/Ne/Lt/Gt/Le/Ge -> if <flag> <cmp> <expr>: jump
  0x2d-0x32 (inferred conditional Gosub) -> if ...: call
  0xc0/0xc8 Select: pairs are (global choice value, text stridx); the menu
       is followed by [0xc9 case][goto dest][goto END] per option -> menu:
  0xd2 (voice, speaker, text) -> voice "..." + say
  0xd3/0xd4 (speaker, text)   -> say
  0xd5 (text)                 -> narration say
  0x4b (image stridx)         -> scene <image>
  0x82 (u8 track)             -> play music "audio/bgm/<NN>.ogg"
       (handler FUN_00406250 builds the "%02d" name and loops it)
  0x83                        -> stop music (FUN_00406b70)
  0x8e/0x8f (img name, .mpg)  -> movie_cutscene of the .mpg operand
       (the KF base-name operand is read but unused by the player)
  [0x4b][0x65][0x66][0x68 id in {1,33,34,35}, val>=100ms] quadruplet
                              -> scene + bare `with Dissolve(val/1000)`
       (0x68 ParamSet builds the transition for the image just shown;
        ids 1/33/34/35 are the fade / box / strips / radial variants)
  other image/voice-referencing ops and everything else -> comments
       carrying the resolved names / raw operands, nothing is dropped.

Usage: sce2renpy.py <dec_sce.bin> <pool_codec> <out_script.rpy> <out_characters.rpy>
"""
import re
import struct
import sys
from collections import Counter

sys.path.insert(0, __file__.rsplit('/', 2)[0] + '/re')
import sce_token as T      # noqa: E402
import sce_parse as P      # noqa: E402

RUBY = re.compile(r'@\[([^:\]]+):([^\]]+)\]')
IMG_OPS = {0x52, 0x57, 0x59, 0x5d, 0x5f, 0x61, 0x77, 0x7c, 0x80, 0x8e, 0x8f, 0xac}
TRANS_IDS = {1, 33, 34, 35}  # 0x68 ParamSet ids that build a timed transition
VOICE_OPS = {0x88, 0x8b}
CMP = {0x27: '==', 0x28: '!=', 0x29: '<', 0x2a: '>', 0x2b: '<=', 0x2c: '>='}
CMP_GOSUB = {0x2d: '==', 0x2e: '!=', 0x2f: '<', 0x30: '>', 0x31: '<=', 0x32: '>='}
ARITH = {0x19: '+=', 0x1a: '-=', 0x1b: '*=', 0x1c: '//=', 0x1d: '%='}


def escape_plain(t):
    return (t.replace('\\', '\\\\').replace('"', '\\"')
             .replace('[', '[[').replace('{', '{{'))


def renpy_text(s):
    out, pos = [], 0
    for m in RUBY.finditer(s):
        out.append(escape_plain(s[pos:m.start()]))
        out.append('{rb}' + escape_plain(m.group(1)) + '{/rb}{rt}' +
                   escape_plain(m.group(2)) + '{/rt}')
        pos = m.end()
    out.append(escape_plain(s[pos:]))
    return ''.join(out)


def sanitize(name):
    s = re.sub(r'[^A-Za-z0-9_]', '_', name)
    if not s or s[0].isdigit():
        s = 'l_' + s
    return s


def main():
    src, codec, out_script, out_chars = sys.argv[1:5]
    d = open(src, 'rb').read()
    lt_off, pool_off = struct.unpack_from('<II', d, 0)
    labels, segs = T.segments(d, lt_off, pool_off)
    pool = P.load_pool(d, pool_off)

    def ps(i):
        if 0 <= i < len(pool):
            return pool[i][1].decode(codec, 'replace')
        return f'<idx{i}>'

    # ---- parse all records linearly ----
    recs = []
    for a, b in segs:
        r, fail = P.parse_segment(d, a, b)
        if fail is not None:
            print(f'WARN: segment @{a} failed at {fail}')
        recs.extend(r)
    rec_offsets = {r.off for r in recs}
    stats = Counter(r.op for r in recs)

    # ---- label map ----
    label_at = {}
    used = set()
    for name, off in labels:
        if off in rec_offsets and off not in label_at:
            nm = sanitize(name)
            if nm in used:
                nm = f'{nm}_{off}'
            label_at[off] = nm
            used.add(nm)
    if 8 not in label_at:
        label_at[8] = 'start'
        used.add('start')
    elif label_at[8] != 'start':
        pass  # entry label keeps its sce name; start jumps to it (emitted below)

    def target_label(off):
        if off not in label_at:
            nm = f'tgt_{off}'
            if nm in used:  # pragma: no cover
                nm = f'tgt_{off}_x'
            label_at[off] = nm
            used.add(nm)
        return label_at[off]

    # collect flow targets first so synthetic labels exist
    bad_targets = []
    for r in recs:
        tgts = []
        if r.op in (0x0b, 0x0c):
            tgts = [r.ops[0]]
        elif r.op in CMP or r.op in CMP_GOSUB or r.op in (0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f):
            tgts = [r.ops[3]]
        # select pairs are (global choice value, text stridx) - NOT targets;
        # the case bodies are plain 0x0b records and are collected as such.
        for t in tgts:
            if t in rec_offsets:
                target_label(t)
            else:
                bad_targets.append((r.off, t))

    # ---- speakers / characters ----
    speakers = []
    seen_spk = set()
    for r in recs:
        if r.op in (0xd2, 0xd3, 0xd4):
            s = ps(r.ops[1] if r.op == 0xd2 else r.ops[0])
            if s and s not in seen_spk:
                seen_spk.add(s)
                speakers.append(s)
    char_var = {s: f'ch_{i:03d}' for i, s in enumerate(speakers)}

    # ---- expression rendering ----
    flag_vars = set()

    def var_of(bank_byte, idx):
        v = ('lf_' if bank_byte == 0x40 else 'gf_') + str(idx)
        flag_vars.add(v)
        return v

    def expr(v):
        if isinstance(v, tuple) and v and v[0] == 'flag':
            return var_of(0x40 if v[1] == '@' else 0x41, v[2])
        if isinstance(v, tuple) and v and v[0] == 'imm':
            val = v[2]
            return str(val - (1 << 32) if val >= (1 << 31) else val)
        return repr(v)

    def raw_ops(r):
        parts = []
        sig = T.sig_options(r.op)[0]
        for t, v in zip(sig, r.ops):
            if t == 'E':
                parts.append('E:' + expr(v))
            elif t == '4' and isinstance(v, int) and 0 <= v < len(pool):
                s = ps(v)
                parts.append(f'"{s}"' if s.isprintable() and len(s) <= 40 else str(v))
            else:
                parts.append(repr(v))
        return ', '.join(parts)

    # ---- emission ----
    lines = []
    lines.append('# Generated by pipeline/sce2renpy.py from a decrypted ANIM sce.')
    lines.append('# Unmapped engine ops are preserved as comments; nothing is dropped.')
    lines.append('')
    entry_label = label_at[8]
    if entry_label != 'start':
        lines.append('label start:')
        lines.append(f'    jump {entry_label}')
        lines.append('')

    n_text = 0
    n_voice_ok = 0
    n_menu = 0
    n_bgm = 0
    n_bgm_stop = 0
    n_kf_movie = 0
    n_trans = 0

    def slot_str(v):
        """Render an EXPR used as a slot/layer index."""
        if isinstance(v, tuple) and v and v[0] == 'imm':
            return str(v[2])
        return expr(v)

    def emit_stmt(r, ind):
        """Emit one non-select record; returns list of lines."""
        nonlocal n_text, n_voice_ok, n_bgm, n_bgm_stop, n_kf_movie
        op = r.op
        if op == 0x0a:
            return [f'{ind}# label "{r.ops[0]}"']
        if op == 0x0b:
            return [f'{ind}jump {label_at[r.ops[0]]}']
        if op == 0x0c:
            return [f'{ind}call {label_at[r.ops[0]]}']
        if op == 0x0d:
            return [f'{ind}return']
        if op == 0x1e:
            return [f'{ind}$ {var_of(r.ops[0], r.ops[1])} = {expr(r.ops[2])}']
        if op in ARITH:
            return [f'{ind}$ {var_of(r.ops[0], r.ops[1])} {ARITH[op]} {expr(r.ops[2])}']
        if op == 0x26:
            return [f'{ind}$ {var_of(r.ops[0], r.ops[1])} = renpy.random.randint({r.ops[2]}, {r.ops[3]})  # FlagRand bounds unchecked']
        if op in CMP or op in (0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f):
            cmpop = CMP.get(op) or {0x3a: '==', 0x3b: '!=', 0x3c: '<', 0x3d: '>', 0x3e: '<=', 0x3f: '>='}[op]
            return [f'{ind}if {var_of(r.ops[0], r.ops[1])} {cmpop} {expr(r.ops[2])}:',
                    f'{ind}    jump {label_at[r.ops[3]]}']
        if op in CMP_GOSUB:
            return [f'{ind}if {var_of(r.ops[0], r.ops[1])} {CMP_GOSUB[op]} {expr(r.ops[2])}:  # conditional gosub (inferred)',
                    f'{ind}    call {label_at[r.ops[3]]}']
        if op == 0xd2:
            voice_name = ps(r.ops[0])
            n_voice_ok += 1
            n_text += 1
            spk = ps(r.ops[1])
            return [f'{ind}voice "audio/voice/{voice_name}.ogg"',
                    f'{ind}{char_var[spk]} "{renpy_text(ps(r.ops[2]))}"']
        if op in (0xd3, 0xd4):
            spk = ps(r.ops[0])
            txt = ps(r.ops[1])
            n_text += 1
            if spk:
                return [f'{ind}{char_var[spk]} "{renpy_text(txt)}"']
            return [f'{ind}"{renpy_text(txt)}"']
        if op == 0xd5:
            n_text += 1
            return [f'{ind}"{renpy_text(ps(r.ops[0]))}"']
        if op == 0x4b:
            # lowercased: Ren'Py image names are normalized to lowercase;
            # lint's image check is case-sensitive (verified on 8.5.3).
            return [f'{ind}scene {ps(r.ops[0]).lower()}']
        if op == 0x21 and ps(r.ops[0]).endswith('.mpg'):
            return [f'{ind}$ renpy.movie_cutscene("movies/{ps(r.ops[0])}")']
        if op == 0x82:
            n_bgm += 1
            return [f'{ind}play music "audio/bgm/{r.ops[0]:02d}.ogg"']
        if op == 0x83:
            n_bgm_stop += 1
            return [f'{ind}stop music']
        if op in (0x8e, 0x8f):
            n_kf_movie += 1
            flag = 1 if op == 0x8f else 0
            return [f'{ind}# [kf op 0x{op:02x}] base {ps(r.ops[0])} (operand1 unused by player), flag {flag}',
                    f'{ind}$ renpy.movie_cutscene("movies/{ps(r.ops[1])}")']
        if op == 0x57:
            # same vtable call as 0x52 load, with a NULL name: unload slot
            return [f'{ind}# [emote op 0x57] unload model in slot {slot_str(r.ops[0])}']
        if op == 0x5f:
            return [f'{ind}# [emote op 0x5f] load {ps(r.ops[1])} into HC slot {slot_str(r.ops[0])} (alt loader)']
        if op == 0xac:
            return [f'{ind}# [bgv op 0xac] ({slot_str(r.ops[0])}, {slot_str(r.ops[1])})']
        if op == 0x16:
            return [f'{ind}# [checkpoint op 0x16] snapshot slot {r.ops[0]}']
        if op in IMG_OPS:
            names = []
            sig = T.sig_options(op)[0]
            for t, v in zip(sig, r.ops):
                if t == '4' and 0 <= v < len(pool):
                    names.append(ps(v))
                elif t == 'E' and isinstance(v, tuple) and v[0] == 'imm':
                    names.append(ps(v[2]) if v[2] else '<clear>')
            return [f'{ind}# [img op 0x{op:02x}] {", ".join(names) or raw_ops(r)}']
        if op in VOICE_OPS:
            return [f'{ind}# [voice op 0x{op:02x}] {ps(r.ops[1]) if len(r.ops) > 1 else raw_ops(r)}']
        if op == 0xdc:
            return [f'{ind}# [scene end 0xdc] ({r.ops[0]}, {r.ops[1]})']
        if op == 0xc9:
            return [f'{ind}# case marker (outside select block)']
        return [f'{ind}# op 0x{op:02x} ({raw_ops(r)})']

    def select_block(i):
        """If recs[i] (a 0xc0/0xc8) heads a well-formed case block
        ([0xc9 k][goto dest][goto END] * n, next record at END), return
        (menu_lines, next_index); else return None.
        Pattern verified on all 50 selects of kabe2 orig sce."""
        r = recs[i]
        pairs = r.ops[0][1]
        j = i + 1
        dests = []
        END = None
        for k in range(len(pairs)):
            if j + 2 >= len(recs) or recs[j].op != 0xc9 or recs[j].ops[0] != k + 1:
                return None
            g1, g2 = recs[j + 1], recs[j + 2]
            if g1.op != 0x0b or g2.op != 0x0b:
                return None
            if END is None:
                END = g2.ops[0]
            elif g2.ops[0] != END:
                return None
            dests.append(g1.ops[0])
            j += 3
        if j >= len(recs) or recs[j].off != END:
            return None
        out = ['    menu:']
        for (val, sidx), dest in zip(pairs, dests):
            out.append(f'        "{renpy_text(ps(sidx))}":  # choice value {val}')
            out.append(f'            jump {label_at[dest]}')
        return out, j

    i = 0
    while i < len(recs):
        r = recs[i]
        if r.off in label_at:
            lines.append('')
            lines.append(f'label {label_at[r.off]}:')
        if r.op in (0xc0, 0xc8):
            blk = select_block(i)
            if blk is not None:
                menu_lines, i = blk
                lines.extend(menu_lines)
                n_menu += 1
                continue
            lines.append(f'    # op 0x{r.op:02x} select (unstructured, kept raw) ({raw_ops(r)})')
            i += 1
            continue
        if (r.op == 0x4b and i + 3 < len(recs)
                and recs[i + 1].op == 0x65 and recs[i + 2].op == 0x66
                and recs[i + 3].op == 0x68
                and recs[i + 3].ops[0] in TRANS_IDS
                and recs[i + 3].ops[1] >= 100):
            # [image][trans begin][trans end][ParamSet]: the ParamSet builds
            # the transition for the image just shown (FUN_00413ca0 setters
            # enqueue their render commands immediately).
            lines.extend(emit_stmt(r, '    '))
            for k in (i + 1, i + 2, i + 3):
                if recs[k].off in label_at:
                    lines.append('')
                    lines.append(f'label {label_at[recs[k].off]}:')
            pid, val = recs[i + 3].ops[0], recs[i + 3].ops[1]
            lines.append(f'    # trans (ops 65/66/68) id={pid}, {val}ms')
            lines.append(f'    with Dissolve({val / 1000.0:g})')
            n_trans += 1
            i += 4
            continue
        lines.extend(emit_stmt(r, '    '))
        i += 1

    # defaults for every flag var, inserted before the first label
    defaults = [f'default {v} = 0' for v in sorted(flag_vars)]
    out = []
    inserted = False
    for ln in lines:
        if not inserted and ln.startswith('label '):
            out.extend(defaults)
            out.append('')
            inserted = True
        out.append(ln)
    with open(out_script, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out) + '\n')
    with open(out_chars, 'w', encoding='utf-8') as f:
        f.write('# Characters in first-appearance order.\n')
        for s in speakers:
            f.write(f'define {char_var[s]} = Character("{escape_plain(s)}")  # {s}\n')
    print(f'records={len(recs)} text_lines={n_text} voiced={n_voice_ok} menus={n_menu} '
          f'labels={len(label_at)} speakers={len(speakers)} flag_vars={len(flag_vars)} '
          f'bad_targets={len(bad_targets)}')
    print(f'bgm_play={n_bgm} bgm_stop={n_bgm_stop} kf_movies={n_kf_movie} transitions={n_trans}')
    if bad_targets:
        print('bad targets (not on record boundaries):', bad_targets[:10])
    print('op stats:', {hex(k): v for k, v in stats.most_common(8)})


if __name__ == '__main__':
    main()
