#!/usr/bin/env python3
"""One-shot S3-compatible uploader for Cloudflare R2 (stdlib only,
AWS SigV4). Credentials are read from stdin (line 1 = access key id,
line 2 = secret access key) so they never touch disk, argv or env.

Usage:
  r2_upload.py <endpoint> <bucket> <prefix> <root_dir> [state.json]
  r2_upload.py <endpoint> <bucket> --list-only

Behaviour: HEAD-skip objects already present with the same size,
single PUT up to 16 MiB, multipart (32 MiB parts) above that with a
resume state file, retries with backoff, and a final ListObjects
comparison against the local inventory.
"""
import hashlib
import hmac
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor

AK, SK = "", ""
ENDPOINT = ""
BUCKET = ""
_print_lock = threading.Lock()

CTYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript",
    ".wasm": "application/wasm",
    ".json": "application/json",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".ogv": "video/ogg",
    ".ogg": "audio/ogg",
    ".css": "text/css",
    ".txt": "text/plain; charset=utf-8",
}


def log(*a):
    with _print_lock:
        print(*a, flush=True)


def _sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def request(method, key_path, body=None, headers=None, query=None):
    """key_path is the bucket-relative object key, or '' for bucket ops."""
    url = ENDPOINT + "/" + BUCKET
    if key_path:
        url += "/" + urllib.parse.quote(key_path, safe="/")
    if query:
        url += "?" + query
    now = time.gmtime()
    amz_date = time.strftime("%Y%m%dT%H%M%SZ", now)
    date_stamp = time.strftime("%Y%m%d", now)
    host = urllib.parse.urlparse(ENDPOINT).netloc
    hdrs = {
        "host": host,
        "x-amz-date": amz_date,
        "x-amz-content-sha256": "UNSIGNED-PAYLOAD",
    }
    if headers:
        hdrs.update(headers)
    # SigV4 canonical header names must be lowercase (a mixed-case
    # "Content-Type" key here silently broke every PUT signature
    # while GET/HEAD, whose headers were already lowercase, passed).
    signed = ";".join(sorted(k.lower() for k in hdrs))
    canon_headers = "".join(
        f"{k.lower()}:{str(hdrs[k]).strip()}\n"
        for k in sorted(hdrs, key=lambda s: s.lower()))
    canon_uri = urllib.parse.urlparse(url).path
    raw_qs = urllib.parse.urlparse(url).query
    if raw_qs:
        # Canonical query: sorted, bare keys gain "=" (the multipart
        # initiate "?uploads" signs as "uploads=", not "uploads").
        pairs = urllib.parse.parse_qsl(raw_qs, keep_blank_values=True)
        canon_qs = "&".join(
            f"{urllib.parse.quote(k, safe='-_.~')}="
            f"{urllib.parse.quote(v, safe='-_.~')}"
            for k, v in sorted(pairs))
    else:
        canon_qs = ""
    payload_hash = "UNSIGNED-PAYLOAD"
    canon_req = "\n".join([method, canon_uri, canon_qs, canon_headers, signed, payload_hash])
    scope = f"{date_stamp}/auto/s3/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope,
                         hashlib.sha256(canon_req.encode()).hexdigest()])
    k_date = _sign(("AWS4" + SK).encode(), date_stamp)
    k_region = _sign(k_date, "auto")
    k_service = _sign(k_region, "s3")
    k_signing = _sign(k_service, "aws4_request")
    signature = hmac.new(k_signing, to_sign.encode(), hashlib.sha256).hexdigest()
    hdrs["Authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
        f"SignedHeaders={signed}, Signature={signature}")
    req = urllib.request.Request(url, data=body, method=method, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            return resp.status, dict(resp.headers), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read()


def with_retries(fn, what, tries=4):
    last = None
    for i in range(tries):
        try:
            st, hd, body = fn()
            if st in (200, 201, 204):
                return st, hd, body
            last = (st, body[:200])
            if st in (400, 403, 404):
                break
        except Exception as e:  # connection resets etc.
            last = ("exc", repr(e)[:200])
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"{what} failed: {last}")


def head_size(key):
    # The egress path drops connections sporadically; retry, and on
    # persistent failure report "unknown" (None) so the caller just
    # re-uploads identical bytes instead of dying.
    for i in range(4):
        try:
            st, hd, _ = request("HEAD", key)
            if st == 200:
                return int(hd.get("Content-Length", -1))
            return None
        except Exception:
            time.sleep(2 * (i + 1))
    return None


def put_single(key, path, size):
    ctype = CTYPES.get(os.path.splitext(path)[1].lower(), "application/octet-stream")
    with open(path, "rb") as f:
        data = f.read()
    with_retries(lambda: request("PUT", key, body=data,
                                  headers={"Content-Type": ctype}),
                 f"PUT {key}")


def put_multipart(key, path, size, state, _attempt=0):
    part_size = 32 * 1024 * 1024
    nparts = (size + part_size - 1) // part_size
    ent = state.get(key)
    if not ent or ent.get("size") != size:
        st, hd, body = with_retries(
            lambda: request("POST", key, query="uploads"), f"initiate {key}")
        root = ET.fromstring(body)
        ns = {"s": "http://s3.amazonaws.com/doc/2006-03-01/"}
        upload_id = root.find("s:UploadId", ns).text
        ent = {"upload_id": upload_id, "size": size, "parts": {}}
        state[key] = ent
        save_state()
    upload_id = ent["upload_id"]

    def upload_part(n):
        if str(n) in ent["parts"]:
            return
        off = (n - 1) * part_size
        ln = min(part_size, size - off)
        with open(path, "rb") as f:
            f.seek(off)
            data = f.read(ln)
        qid = urllib.parse.quote(upload_id, safe="")
        st, hd, body = with_retries(
            lambda: request("PUT", key, body=data,
                            query=f"partNumber={n}&uploadId={qid}"),
            f"part {n} of {key}")
        ent["parts"][str(n)] = hd.get("ETag") or hd.get("Etag")
        save_state()
        log(f"  part {n}/{nparts} of {key} done")

    with ThreadPoolExecutor(max_workers=4) as ex:
        list(ex.map(upload_part, range(1, nparts + 1)))
    parts_xml = "".join(
        f"<Part><PartNumber>{n}</PartNumber><ETag>{ent['parts'][str(n)]}</ETag></Part>"
        for n in range(1, nparts + 1))
    body = ("<CompleteMultipartUpload>" + parts_xml +
            "</CompleteMultipartUpload>").encode()
    try:
        with_retries(lambda: request(
            "POST", key, body=body,
            query=f"uploadId={urllib.parse.quote(upload_id, safe='')}"),
            f"complete {key}")
    except RuntimeError as e:
        # R2 occasionally answers Complete with NoSuchUpload for a
        # just-finished part sequence (and a resumed state entry can
        # point at an upload that no longer exists). Drop the entry
        # and redo the whole upload once under a fresh uploadId.
        if "NoSuchUpload" in str(e) and _attempt == 0:
            state.pop(key, None)
            save_state()
            return put_multipart(key, path, size, state, _attempt=1)
        raise
    state.pop(key, None)
    save_state()


STATE_PATH = ""
_state_lock = threading.Lock()
STATE = {}


def save_state():
    if not STATE_PATH:
        return
    with _state_lock:
        with open(STATE_PATH, "w") as f:
            json.dump(STATE, f)


def list_all():
    out = {}
    token = ""
    while True:
        q = "list-type=2&max-keys=1000"
        if token:
            q += "&continuation-token=" + urllib.parse.quote(token)
        st, hd, body = with_retries(lambda: request("GET", "", query=q), "list")
        root = ET.fromstring(body)
        ns = {"s": "http://s3.amazonaws.com/doc/2006-03-01/"}
        for c in root.findall("s:Contents", ns):
            out[c.find("s:Key", ns).text] = int(c.find("s:Size", ns).text)
        trunc = root.find("s:IsTruncated", ns)
        if trunc is not None and trunc.text == "true":
            token = root.find("s:NextContinuationToken", ns).text
        else:
            return out


def main():
    global AK, SK, ENDPOINT, BUCKET, STATE_PATH, STATE
    AK = sys.stdin.readline().strip()
    SK = sys.stdin.readline().strip()
    ENDPOINT = sys.argv[1].rstrip("/")
    BUCKET = sys.argv[2]
    if sys.argv[3] == "--list-only":
        inv = list_all()
        log(f"LIST {len(inv)} objects, {sum(inv.values())} bytes")
        return 0
    prefix, root_dir = sys.argv[3], sys.argv[4]
    if len(sys.argv) > 5:
        STATE_PATH = sys.argv[5]
        if os.path.exists(STATE_PATH):
            STATE = json.load(open(STATE_PATH))
    files = []
    for dp, dns, fns in os.walk(root_dir):
        dns.sort()
        for fn in sorted(fns):
            full = os.path.join(dp, fn)
            rel = os.path.relpath(full, root_dir).replace(os.sep, "/")
            files.append((prefix + rel, full, os.path.getsize(full)))
    log(f"inventory: {len(files)} files, {sum(s for _, _, s in files)} bytes")
    done = skipped = 0
    done_bytes = 0
    failures = []

    def handle(item):
        i, (key, full, size) = item
        if head_size(key) == size:
            return ("skip", i, key, size, "")
        try:
            if size <= 16 * 1024 * 1024:
                put_single(key, full, size)
            else:
                put_multipart(key, full, size, STATE)
        except Exception as e:
            return ("fail", i, key, size, repr(e)[:160])
        return ("new", i, key, size, "")

    # Files upload concurrently (the serial loop was latency-bound:
    # HEAD + PUT round trips per file over a flaky egress). Resume
    # state stays safe: entries are per-key and saves are locked.
    with ThreadPoolExecutor(max_workers=4) as ex:
        for kind, i, key, size, err in ex.map(handle, enumerate(files)):
            if kind == "skip":
                skipped += 1
            elif kind == "fail":
                failures.append((key, err))
                log(f"[{i + 1}/{len(files)}] FAILED {key}: {err}")
            else:
                done += 1
                done_bytes += size
                log(f"[{i + 1}/{len(files)}] uploaded {key} ({size} B) "
                    f"total_new={done} skipped={skipped}")
    log(f"upload phase done: new={done} ({done_bytes} B) skipped={skipped} "
        f"failures={len(failures)}")
    for key, err in failures:
        log(f"  FAILED: {key} :: {err}")
    remote = list_all()
    bad = []
    for key, full, size in files:
        if remote.get(key) != size:
            bad.append((key, size, remote.get(key)))
    if bad:
        log(f"VERIFY MISMATCHES: {len(bad)}")
        for b in bad[:20]:
            log("  ", b)
        return 1
    log(f"VERIFY OK: all {len(files)} objects present with exact sizes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
