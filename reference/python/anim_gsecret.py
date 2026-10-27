#!/usr/bin/env python3
"""ANIM (teamMM) engine 'GSecretFile' decryptor.
Format: [00 00 00 01][16-byte key][body]; body[i] = plain[i] XOR key[i%16];
after every 16 bytes the key is updated by update_key(key, plain[i-1])
(the plaintext byte at block offset 14). Algorithm reversed from
kabetuma2_GPT.exe GSecret::Decode (0x47de80) / key update (0x47d900).
"""
import sys

def update_key(k, fb):
    k = bytearray(k); s = fb & 7
    if s == 0:
        k[0]=(k[0]+fb)&0xff; k[3]=(k[3]+fb+2)&0xff; k[4]=(k[2]+fb+0x0b)&0xff; k[8]=(k[6]+7)&0xff
    elif s == 1:
        k[2]=(k[10]+k[9])&0xff; k[6]=(k[15]+k[7])&0xff; k[8]=(k[8]+k[1])&0xff; k[15]=(k[3]+k[5])&0xff
    elif s == 2:
        k[1]=(k[1]+k[2])&0xff; k[5]=(k[5]+k[6])&0xff; k[7]=(k[7]+k[8])&0xff; k[10]=(k[10]+k[11])&0xff
    elif s == 3:
        k[9]=(k[1]+k[2])&0xff; k[11]=(k[5]+k[6])&0xff; k[12]=(k[7]+k[8])&0xff; k[13]=(k[10]+k[11])&0xff
    elif s == 4:
        k[0]=(k[1]+0x6f)&0xff; k[3]=(k[4]+0x47)&0xff; k[4]=(k[5]+0x11)&0xff; k[14]=(k[15]+0x40)&0xff
    elif s == 5:
        k[2]=(k[10]+k[2])&0xff; k[4]=(k[12]+k[5])&0xff; k[6]=(k[14]+k[8])&0xff; k[8]=(k[0]+k[11])&0xff
    elif s == 6:
        k[9]=(k[1]+k[11])&0xff; k[11]=(k[3]+k[13])&0xff; k[13]=(k[5]+k[15])&0xff; k[15]=(k[7]+k[9])&0xff
        k[1]=(k[5]+k[9])&0xff; k[2]=(k[6]+k[10])&0xff; k[3]=(k[7]+k[11])&0xff; k[4]=(k[8]+k[12])&0xff
    else:
        k[1]=(k[5]+k[9])&0xff; k[2]=(k[6]+k[10])&0xff; k[3]=(k[7]+k[11])&0xff; k[4]=(k[8]+k[12])&0xff
    return k

def decrypt(data: bytes) -> bytes:
    if data[:4] != b'\x00\x00\x00\x01':
        raise ValueError('not a GSecret file (bad magic)')
    key = bytearray(data[4:20]); body = data[20:]
    out = bytearray(len(body))
    for i, b in enumerate(body):
        out[i] = b ^ key[i & 15]
        if (i & 15) == 15:
            key = update_key(key, out[i-1])
    return bytes(out)

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    open(dst, 'wb').write(decrypt(open(src, 'rb').read()))
    print('decrypted', src, '->', dst)
