#!/usr/bin/env python3
"""Extract the E-mote pose table from a decrypted ANIM define file.

Pose record (measured on kabe2 define_orig):
  [u32 9][u32 0] 'emNNN' then 18 (varname, value-as-ascii-float) string
  pairs in fixed order, then a ('', '0.0') terminator pair.
Also extracts the readable chara -> em-labels and chara -> models
association sections (string runs terminated by a '}' token).
Output: JSON {poses: {label: {var: float}}, chara_labels, chara_models}.
"""
import json
import re
import struct
import sys

MARKER = b'\x09\x00\x00\x00'  # u32 record-type 9; flags u32 follows
LABEL_RE = re.compile(r'em[A-Za-z0-9_]+$')


def read_cstr(d, pos):
    end = d.index(b'\x00', pos)
    return d[pos:end].decode('cp932'), end + 1


def extract_poses(d):
    """Record: [u32 9][u32 flags] label, then (varname, ascii-float)
    pairs until the ('', '0.0') terminator pair. Full poses carry 18
    pairs in fixed order; partial sets (emSet*, *_EyeOnly) fewer."""
    poses = {}
    for m in re.finditer(re.escape(MARKER), d):
        pos = m.start() + 4
        flags = struct.unpack_from('<I', d, pos)[0]
        pos += 4
        try:
            label, pos = read_cstr(d, pos)
            if not LABEL_RE.fullmatch(label):
                continue
            vals = {}
            while True:
                name, pos = read_cstr(d, pos)
                val, pos = read_cstr(d, pos)
                if name == '' and val == '0.0':
                    break
                vals[name] = float(val)
                if len(vals) > 40:
                    raise ValueError('runaway')
            poses[label] = {'flags': flags, 'vars': vals}
        except (ValueError, IndexError, struct.error):
            continue
    return poses


def extract_assoc(d):
    """Token-stream scan for the chara association sections."""
    tokens = []  # (offset, string)
    pos = 0
    while pos < len(d):
        end = d.find(b'\x00', pos)
        if end == -1:
            break
        raw = d[pos:end]
        if raw and all(32 <= b < 127 for b in raw):
            tokens.append(raw.decode('ascii'))
        pos = end + 1
    chara_labels, chara_models = {}, {}
    charas = ('Mchina', 'Mfumi', 'Mkosu', 'Mhide')
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t in charas:
            # labels section: following tokens are emNNN until '}'
            labs = []
            j = i + 1
            while j < len(tokens) and tokens[j] != '}' and re.fullmatch(r'em\d{3}[a-z]?', tokens[j]):
                labs.append(tokens[j])
                j += 1
            if labs and j < len(tokens) and tokens[j] == '}':
                chara_labels.setdefault(t, labs)
                i = j
                continue
            # models section: following tokens are model names (charaNNN[a])
            mods = []
            j = i + 1
            while j < len(tokens) and tokens[j] != '}' and re.fullmatch(re.escape(t) + r'\d{3}[a-z]?', tokens[j]):
                mods.append(tokens[j])
                j += 1
            if mods and j < len(tokens) and tokens[j] == '}':
                chara_models.setdefault(t, mods)
                i = j
                continue
        i += 1
    return chara_labels, chara_models


if __name__ == '__main__':
    d = open(sys.argv[1], 'rb').read()
    poses = extract_poses(d)
    chara_labels, chara_models = extract_assoc(d)
    out = {'poses': poses, 'chara_labels': chara_labels,
           'chara_models': chara_models}
    with open(sys.argv[2], 'w', encoding='utf-8') as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    all_vars = sorted({v for p in poses.values() for v in p['vars']})
    print(f'poses: {len(poses)}  distinct vars: {len(all_vars)} {all_vars}')
    print(f'chara_labels: {{ {", ".join(f"{k}:{len(v)}" for k, v in chara_labels.items())} }}  '
          f'chara_models: {{ {", ".join(f"{k}:{len(v)}" for k, v in chara_models.items())} }}')
