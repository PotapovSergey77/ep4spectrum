# gen.py - memory image and contention block for tb_ttst48
#
# usage: python gen.py <test number> [c]
#
# c is the tape's own flag: 1 (the default) runs the test from $5B00,
# contended; 0 from $DDDD, uncontended.
#
# Writes cont_block.vh (the contention section of ep4spectrum.v, verbatim)
# and mem.hex (the 48K ROM, ttst48's code and BASIC, and the test copied
# to $5B00 the way the tape's own preamble copies it). Also prints the
# result the tape expects for that test on an early-timing machine.
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..'))
SRC = os.path.join(ROOT, 'source', 'ep4spectrum.v')
ROM = os.path.join(ROOT, 'simulation', 'modelsim', '48.hex')
TAP = os.path.join(ROOT, 'testapp', 'Spectrum48K', 'ttst48_my.tap')
TEST = int(sys.argv[1])
CONT = int(sys.argv[2]) if len(sys.argv) > 2 else 1
BASE = 0x5B00 if CONT else 0xDDDD

L = open(SRC, encoding='utf-8').read().split('\n')
s = [i for i, l in enumerate(L) if l.strip().startswith('wire cont_page =')][0]
e = [i for i, l in enumerate(L) if 'reg  ula_io_held' in l][0]
while L[e].strip() != 'end':
    e += 1
open('cont_block.vh', 'w').write('\n'.join(L[s:e + 1]) + '\n')

# The tape: a BASIC loader, then the code block at $BBBB.
blocks = []
d = open(TAP, 'rb').read()
i = 0
while i < len(d):
    n = d[i] | d[i + 1] << 8
    b = d[i + 2:i + 2 + n]
    if b[0] == 0xFF:
        blocks.append(b[1:-1])
    i += 2 + n
bas, code = blocks

mem = bytearray(65536)
for line in open(ROM):
    line = line.strip()
    if not line.startswith(':'):
        continue
    b = bytes.fromhex(line[1:])
    if b[3] == 0:
        a = b[1] << 8 | b[2]
        mem[a:a + b[0]] = b[4:4 + b[0]]
mem[0xBBBB:0xBBBB + len(code)] = code

# What the preamble at $C000 does with the ROM calculator: pick the test
# out of the table at $E000 and copy it to $5B00 (contended) or $DDDD,
# then record where it went. The BASIC's POKEs: test number, contended
# or not, early.
p = mem[0xE000 + 2 * TEST] | mem[0xE001 + 2 * TEST] << 8
mem[BASE:BASE + 256] = mem[p:p + 256]
mem[0xEEE0] = BASE & 0xFF; mem[0xEEE1] = BASE >> 8
mem[0xEF01] = 0; mem[0xEF02] = 0
mem[0x9C40] = TEST; mem[0x9C42] = CONT; mem[0x9C43] = 0; mem[0x9C44] = 0
# The handler finds the interrupted PC by searching the stack for the
# ROM's USR return address, $2D2B.
mem[0xFEFE] = 0x2B; mem[0xFEFF] = 0x2D
# The BASIC program where the ROM keeps it, and CH_ADD where USR leaves
# it (the 0x0D ending RANDOMIZE USR 49152) - test 34's RST $18 reads it.
mem[0x5CCB:0x5CCB + len(bas)] = bas
mem[0x5C5D] = 0xCA; mem[0x5C5E] = 0x70
# DI; LD SP,$FEFE; LD IY,$5C3A; LD IX,$D00A; JP $C053
drv = bytes([0xF3, 0x31, 0xFE, 0xFE, 0xFD, 0x21, 0x3A, 0x5C,
             0xDD, 0x21, 0x0A, 0xD0, 0xC3, 0x53, 0xC0])
mem[0x8000:0x8000 + len(drv)] = drv
mem[0x0000:0x0003] = bytes([0xC3, 0x00, 0x80])
# Tests 35-37 read the floating bus, so their screen matters. The BASIC
# does CLS and then prints l+1 lines of ZXSPECTRUM before the contended
# run - l = 0, 13, 21 for 35, 36, 37 - in INK 7 on PAPER 1.
if CONT and TEST in (35, 36, 37):
    lines = {35: 0, 36: 13, 37: 21}[TEST] + 1
    mem[0x4000:0x5800] = bytes(0x1800)
    mem[0x5800:0x5B00] = bytes([0x0F]) * 0x300
    text = 'ZXSPECTRUMZXSPECTRUMZXSPECTRUMZX'
    for row in range(lines):
        for col, ch in enumerate(text):
            for p in range(8):
                a = 0x4000 | (row & 0x18) << 8 | p << 8 | (row & 7) << 5 | col
                mem[a] = mem[0x3D00 + (ord(ch) - 32) * 8 + p]

open('mem.hex', 'w').write('\n'.join('%02x' % x for x in mem) + '\n')

k = 57856 + TEST * 10 + 5 * CONT
print('R=%d loop=%d sp=%d' % (mem[k], mem[k + 1] | mem[k + 2] << 8,
                              mem[k + 3] | mem[k + 4] << 8))
