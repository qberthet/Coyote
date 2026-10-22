#!/usr/bin/env python3
# Generates the UNSHIFT matrices of hw/hdl/network/rdma/icrc.sv and checks them against a reference
# CRC. icrc carries a packet's last beat through its 64-byte CRC path with the bytes past tkeep
# zeroed; each matrix takes those trailing zero bytes back out of the reflected CRC-32 (0xEDB88320)
# state. Prints the SystemVerilog table; given the path of icrc.sv, checks the table there instead.
#   python3 sim/tests/icrc/unshift.py [hw/hdl/network/rdma/icrc.sv]
import random
import re
import sys
import zlib

POLY = 0xEDB88320


def unstep(c):
    """Inverse of one zero-bit step of the reflected CRC: bit 31 of the result is the bit shifted out"""
    b = c >> 31
    t = c ^ (POLY if b else 0)
    return ((t << 1) & 0xFFFFFFFF) | b


def crc_bytes(data, c):
    for byte in data:
        for i in range(8):
            c = (c >> 1) ^ (POLY if ((c ^ (byte >> i)) & 1) else 0)
    return c


def unshift_cols(nbytes):
    """Columns of the matrix that undoes nbytes trailing zero bytes"""
    cols = []
    for j in range(32):
        c = 1 << j
        for _ in range(8 * nbytes):
            c = unstep(c)
        cols.append(c)
    return cols


def apply(cols, x):
    r = 0
    for j in range(32):
        if x >> j & 1:
            r ^= cols[j]
    return r


# UNSHIFT[i]: for a tail ending on 32-bit word i, i.e. 60 - 4i zero bytes (i = 15: the identity)
M = [unshift_cols(64 - 4 * (i + 1)) for i in range(16)]

# The CRC over a tail of k bytes zero-padded to 64, undone, equals the CRC over the k bytes
assert crc_bytes(b"123456789", 0xFFFFFFFF) ^ 0xFFFFFFFF == zlib.crc32(b"123456789")
for _ in range(2000):
    i = random.randrange(16)
    k = 4 * (i + 1)
    s = random.getrandbits(32)
    data = bytes(random.getrandbits(8) for _ in range(k))
    assert apply(M[i], crc_bytes(data + bytes(64 - k), s)) == crc_bytes(data, s), (i, k)

values = [c for row in M for c in row]
if len(sys.argv) > 1:
    src = open(sys.argv[1]).read()
    table = src[src.index("localparam logic [31:0] UNSHIFT"):]
    table = table[:table.index("};")]
    found = [int(v, 16) for v in re.findall(r"32'h([0-9a-fA-F]{8})", table)]
    if found != values:
        sys.exit("UNSHIFT in %s does not match" % sys.argv[1])
    print("UNSHIFT in %s matches" % sys.argv[1])
else:
    print("localparam logic [31:0] UNSHIFT [16][32] = '{")
    print(",\n".join("    '{" + ", ".join("32'h%08x" % c for c in row) + "}" for row in M))
    print("};")
