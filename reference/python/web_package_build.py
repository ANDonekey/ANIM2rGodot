#!/usr/bin/env python3
"""Build a web package from an original ANIM game data directory.

The web player cannot seek inside local files the way the desktop
loader does, and browsers have no MPEG-1 decoder, so an online package
is preprocessed once:

  * every file is copied verbatim (hardlinked when possible), EXCEPT
  * movie/*.mpg, which are transcoded to Ogg Theora/Vorbis (.ogv) --
    the one video format Godot plays natively on every platform;
  * a manifest.json describes the result: for every file its size
    (the web loader fetches whole small files and uses HTTP Range
    against the two big GFilePack blobs, whose headers it parses
    exactly like the desktop loader), plus the movie name mapping
    (original .mpg name -> transcoded .ogv path).

Usage: web_package_build.py <game_dir> <out_dir> [--workers N]

Bundle mode (anim-webpkg/2): instead of thousands of loose files,
pack an existing flat (v1) package into a handful of large bundle
files with a span index in the manifest -- the shape real browser
games ship (one .pck / a few asset bundles). The player Range-reads
individual assets straight out of the bundles.

Usage: web_package_build.py --bundle-from <flat_dir> <out_dir>
           [--chunk-mb 256]
"""

import concurrent.futures
import json
import os
import shutil
import struct
import subprocess
import sys

THEORA_Q = "6"   # libtheora quality (0..10)
VORBIS_Q = "4"   # libvorbis quality (-1..10)


def copy_file(src: str, dst: str) -> None:
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if os.path.exists(dst) and os.path.getsize(dst) == os.path.getsize(src):
        return
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)


def transcode_one(job) -> tuple[str, bool, str]:
    src, dst = job
    if os.path.exists(dst) and os.path.getsize(dst) > 0:
        return (src, True, "exists")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    cmd = ["ffmpeg", "-v", "error", "-i", src,
           "-c:v", "libtheora", "-q:v", THEORA_Q,
           "-c:a", "libvorbis", "-q:a", VORBIS_Q,
           "-f", "ogg", "-y", dst + ".tmp"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(dst + ".tmp"):
        return (src, False, r.stderr.strip().splitlines()[-1] if r.stderr.strip() else "ffmpeg failed")
    os.rename(dst + ".tmp", dst)
    return (src, True, "ok")


def build_bundles(flat_dir: str, out_dir: str, chunk_mb: int) -> int:
    """Pack a flat v1 package directory into v2 bundles + manifest.

    The v1 manifest's file list is authoritative (exactly what the
    player can reference), so stray files in the flat directory are
    excluded by construction.
    """
    with open(os.path.join(flat_dir, "manifest.json"), encoding="utf-8") as f:
        man = json.load(f)
    files_in: dict[str, int] = man["files"]
    chunk_size = chunk_mb * 1024 * 1024
    os.makedirs(os.path.join(out_dir, "bundles"), exist_ok=True)
    spans: dict[str, list] = {}
    bundles: list[str] = []
    cur = None
    cur_off = 0
    for rel in sorted(files_in):
        if rel == "manifest.json":
            continue  # the manifest is package metadata, not content
        size = files_in[rel]
        src = os.path.join(flat_dir, rel)
        disk_size = os.path.getsize(src)
        if disk_size != size:
            # The flat tree was built from a working directory, so
            # stray logs can have grown since; content files must
            # never drift. The bundle is self-consistent either way
            # because spans record the bytes actually written.
            if rel.lower().endswith((".dat", ".pck", ".gax", ".eog",
                                      ".ogv", ".mpg")) or disk_size == 0:
                print(f"error: content size drift for {rel}: "
                      f"manifest {size}, disk {disk_size}")
                return 1
            print(f"warning: non-content size drift for {rel}: "
                  f"manifest {size}, disk {disk_size} (using disk)")
            size = disk_size
        if cur is None or (cur_off > 0 and cur_off + size > chunk_size):
            if cur is not None:
                cur.close()
            name = f"bundles/bundle-{len(bundles):03d}.bin"
            bundles.append(name)
            cur = open(os.path.join(out_dir, name), "wb")
            cur_off = 0
        with open(src, "rb") as fsrc:
            shutil.copyfileobj(fsrc, cur, 1024 * 1024)
        spans[rel] = [len(bundles) - 1, cur_off, size]
        cur_off += size
    if cur is not None:
        cur.close()
    # Embed the GFilePack indexes in the manifest: opening a pack
    # otherwise costs three serial Range round trips (count, entry
    # table, name table) before the first byte of content moves.
    packs: dict[str, dict] = {}
    for rel in spans:
        low = rel.lower()
        if low == "cg/psbpack.dat" or (low.startswith("voice/")
                                       and low.endswith(".pck")):
            with open(os.path.join(flat_dir, rel), "rb") as f:
                blob = f.read()
            count = struct.unpack_from("<I", blob, 0)[0]
            entries = []
            for i in range(count):
                _z, off, size = struct.unpack_from("<III", blob,
                                                   4 + 12 * i)
                entries.append([off, size])
            pos = 4 + 12 * count
            names = []
            for _ in range(count):
                end = blob.index(b"\x00", pos)
                names.append(blob[pos:end].decode("ascii", "replace"))
                pos = end + 1
            packs[rel] = {"names": names, "entries": entries}
            print(f"embedded pack index: {rel} ({count} entries)")
    out = {
        "format": "anim-webpkg/2",
        "sce": man.get("sce", ""),
        "define": man.get("define", ""),
        "bundles": bundles,
        "files": spans,
        "movies": man.get("movies", {}),
    }
    if man.get("pre"):
        out["pre"] = man["pre"]
    if packs:
        out["packs"] = packs
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    total = sum(files_in.values())
    print(f"done: {len(spans)} files in {len(bundles)} bundles, "
          f"{total / 1e6:.0f} MB total")
    return 0


def main() -> int:
    argv = sys.argv[1:]
    bundle_from = ""
    chunk_mb = 256
    rest = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a.startswith("--bundle-from="):
            bundle_from = a.split("=", 1)[1]
        elif a.startswith("--chunk-mb="):
            chunk_mb = int(a.split("=", 1)[1])
        else:
            rest.append(a)
        i += 1
    if bundle_from:
        if len(rest) != 1:
            print(__doc__)
            return 2
        return build_bundles(bundle_from, rest[0], chunk_mb)
    args = [a for a in rest if not a.startswith("--")]
    workers = 2
    for a in rest:
        if a.startswith("--workers="):
            workers = int(a.split("=", 1)[1])
    if len(args) != 2:
        print(__doc__)
        return 2
    game_dir, out_dir = args
    os.makedirs(out_dir, exist_ok=True)

    files: dict[str, int] = {}
    movies: dict[str, str] = {}
    jobs = []
    sce = define = ""
    out_real = os.path.realpath(out_dir)
    for dirpath, dirnames, filenames in os.walk(game_dir):
        # Never ingest our own output when out_dir sits inside game_dir.
        dirnames[:] = [d for d in dirnames
                       if os.path.realpath(os.path.join(dirpath, d)) != out_real]
        for fn in filenames:
            src = os.path.join(dirpath, fn)
            rel = os.path.relpath(src, game_dir).replace(os.sep, "/")
            low = rel.lower()
            if low.endswith("_sce.dat"):
                sce = rel
            elif low.endswith("_define.dat"):
                define = rel
            if low.startswith("movie/") and low.endswith(".mpg"):
                ogv_rel = rel[:-4] + ".ogv"
                movies[fn.lower()] = ogv_rel
                jobs.append((src, os.path.join(out_dir, ogv_rel)))
                continue
            dst = os.path.join(out_dir, rel)
            copy_file(src, dst)
            files[rel] = os.path.getsize(dst)

    if not sce:
        print("error: no *_sce.dat found in", game_dir)
        return 1

    print(f"transcoding {len(jobs)} movies with {workers} workers...")
    failed = []
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as ex:
        for src, ok, msg in ex.map(transcode_one, jobs):
            done += 1
            if not ok:
                failed.append((src, msg))
            if done % 10 == 0 or not ok:
                print(f"  [{done}/{len(jobs)}] {os.path.basename(src)}: {msg}")
    for rel in movies.values():
        p = os.path.join(out_dir, rel)
        if os.path.exists(p):
            files[rel] = os.path.getsize(p)

    manifest = {
        "format": "anim-webpkg/1",
        "sce": sce,
        "define": define,
        "files": files,
        "movies": movies,
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    total = sum(files.values())
    print(f"done: {len(files)} files, {total / 1e6:.0f} MB total, "
          f"{len(jobs) - len(failed)}/{len(jobs)} movies transcoded")
    for src, msg in failed:
        print("  FAILED:", src, "-", msg)
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
