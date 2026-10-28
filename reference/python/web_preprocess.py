#!/usr/bin/env python3
"""Preprocess a flat web package (anim-webpkg/1 tree) for the Web player.

The desktop loader does three things per byte / per pixel on the main
thread that a single-threaded wasm build cannot afford; all three move
here, to build time:

  * GSecret decryption of the sce, the define and every cg image
    (the player's decrypt is a per-byte GDScript loop, and the Web
    image path used to re-decrypt on every call);
  * cropping cg PNGs whose content bbox is anchored at (0, 0) -- the
    2048x2048 canvases carry 1280x720 of content, so decoding drops
    ~78% of the pixels. Files whose bbox has a nonzero origin are
    left alone: the player positions images by used-rect origin, so
    cropping those would shift them;
  * R/B channel swap of every PSB texture chunk inside
    cg/psbpack.dat, in place (byte length unchanged): PSB textures
    are labeled "RGBA8" but stored B,G,R,A, and the player used to
    swap per pixel at load.

The output tree is a flat package again (same manifest shape, updated
sizes) plus a "pre" flags object; web_package_build.py --bundle-from
carries the flags into the bundled manifest and the player checks
them at open. Files that need no transform are hardlinked.

Usage: web_preprocess.py <flat_in> <flat_out>
"""

import io
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gsecret_fast import decrypt_fast  # noqa: E402
from psb_parse import Psb  # noqa: E402

PNG_SIG = b"\x89PNG\r\n\x1a\n"


def is_gsecret(data: bytes) -> bool:
    return len(data) >= 20 and data[:4] == b"\x00\x00\x00\x01"


def decrypt_like_player(raw: bytes) -> bytes:
    """Mirror GamePackage._decrypt_bytes exactly."""
    if is_gsecret(raw):
        return decrypt_fast(raw)
    return raw[20:]  # "fake header + plaintext" variant


def swap_psbpack(data: bytearray) -> tuple[int, int]:
    """Swap R/B in every texture chunk of every PSB in a GFilePack.

    Returns (psb_count, texture_count). Byte lengths never change.
    """
    import numpy as np

    count = struct.unpack_from("<I", data, 0)[0]
    entries = []
    for i in range(count):
        _zero, off, size = struct.unpack_from("<III", data, 4 + 12 * i)
        entries.append((off, size))
    pos = 4 + 12 * count
    names = []
    for _ in range(count):
        end = data.index(0, pos)
        names.append(bytes(data[pos:end]).decode("ascii", "replace"))
        pos = end + 1
    n_psb = n_tex = 0
    for name, (off, size) in zip(names, entries):
        if not name.lower().endswith(".psb"):
            continue
        psb = Psb(bytes(data[off:off + size]))
        root = psb.root()
        source = root.get("source") or {}
        for tex in source.values():
            if not isinstance(tex, dict):
                continue
            tinfo = tex.get("texture") or {}
            w = int(tinfo.get("width", 0))
            h = int(tinfo.get("height", 0))
            res = (tinfo.get("pixel") or {}).get("$res")
            if w <= 0 or h <= 0 or res is None:
                continue
            coff, clen = psb.chunks[int(res)]
            n = min(w * h * 4, clen)
            if n < 4:
                continue
            arr = np.frombuffer(data, dtype=np.uint8, count=n,
                                offset=off + coff).reshape(-1, 4)
            tmp = arr[:, 0].copy()
            arr[:, 0] = arr[:, 2]
            arr[:, 2] = tmp
            n_tex += 1
        n_psb += 1
    return n_psb, n_tex


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    flat_in, flat_out = sys.argv[1], sys.argv[2]
    with open(os.path.join(flat_in, "manifest.json"), encoding="utf-8") as f:
        man = json.load(f)
    files: dict[str, int] = man["files"]
    sce_rel = man.get("sce", "")
    define_rel = man.get("define", "")
    os.makedirs(flat_out, exist_ok=True)

    from PIL import Image

    out_files: dict[str, int] = {}
    n_dec = n_crop = n_plain = 0
    bytes_saved = 0
    for rel in sorted(files):
        src = os.path.join(flat_in, rel)
        dst = os.path.join(flat_out, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        low = rel.lower()
        is_image = low.startswith("cg/") and low.endswith(".gax")
        if rel in (sce_rel, define_rel) or is_image:
            raw = open(src, "rb").read()
            plain = decrypt_like_player(raw)
            if is_image:
                if plain[:8] != PNG_SIG:
                    print(f"warning: {rel}: decrypted bytes are not PNG; "
                          "keeping the original file")
                    plain = raw
                else:
                    im = Image.open(io.BytesIO(plain))
                    im.load()
                    bbox = (im.getchannel("A").getbbox()
                            if im.mode in ("RGBA", "LA") else None)
                    if bbox and bbox[:2] == (0, 0) \
                            and (bbox[2], bbox[3]) != im.size:
                        im = im.crop((0, 0, bbox[2], bbox[3]))
                        buf = io.BytesIO()
                        im.save(buf, "PNG", compress_level=6)
                        plain = buf.getvalue()
                        n_crop += 1
                    n_dec += 1
            with open(dst, "wb") as f:
                f.write(plain)
            out_files[rel] = len(plain)
            bytes_saved += len(raw) - len(plain)
        elif low == "cg/psbpack.dat":
            data = bytearray(open(src, "rb").read())
            n_psb, n_tex = swap_psbpack(data)
            with open(dst, "wb") as f:
                f.write(data)
            out_files[rel] = len(data)
            print(f"psbpack: swapped {n_tex} textures in {n_psb} PSBs")
        else:
            try:
                os.link(src, dst)
            except OSError:
                import shutil
                shutil.copy2(src, dst)
            out_files[rel] = files[rel]
            n_plain += 1

    out = dict(man)
    out["files"] = out_files
    out["pre"] = {"decrypted": True, "swapped": True, "cropped": n_crop}
    with open(os.path.join(flat_out, "manifest.json"), "w",
              encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    print(f"done: {n_dec} decrypted ({n_crop} cropped), {n_plain} linked, "
          f"net size change {-bytes_saved / 1e6:+.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
