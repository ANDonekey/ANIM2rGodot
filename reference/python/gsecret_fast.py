#!/usr/bin/env python3
"""Block-wise fast GSecret decryptor (ANIM teamMM engine).

Same algorithm as re/anim_gsecret.py (reference, byte-wise), but XORs
16-byte blocks as integers; the key update still runs once per block
with fb = plaintext byte at block offset 14. A trailing partial block
(<16 bytes) is handled byte-wise and triggers no key update.
Validated byte-for-byte against the reference implementation.
"""
import sys
sys.path.insert(0, __file__.rsplit('/', 2)[0] + '/re')
from anim_gsecret import update_key  # noqa: E402

MAGIC = b'\x00\x00\x00\x01'


def decrypt_fast(data: bytes) -> bytes:
    if data[:4] != MAGIC:
        raise ValueError('not a GSecret file (bad magic)')
    key = bytearray(data[4:20])
    body = data[20:]
    out = bytearray(len(body))
    nfull = len(body) // 16
    for blk in range(nfull):
        s = blk * 16
        kb = int.from_bytes(key, 'little')
        cb = int.from_bytes(body[s:s + 16], 'little')
        pb = (cb ^ kb).to_bytes(16, 'little')
        out[s:s + 16] = pb
        key = update_key(key, pb[14])
    # tail (<16 bytes): plain XOR with current key, no update afterwards
    s = nfull * 16
    for i in range(s, len(body)):
        out[i] = body[i] ^ key[i & 15]
    return bytes(out)


if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    open(dst, 'wb').write(decrypt_fast(open(src, 'rb').read()))
    print('decrypted', src, '->', dst)
