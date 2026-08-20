#!/usr/bin/env python3
"""stxl_decode.py — reference decoder for SAPscript long texts stored in STXL.

A deliberately literal Python port of the SQLScript AMDP procedure
ZCLBC_LTEXT_DECODE=>DECODE_LINES, kept line-for-line comparable with the
SQLScript so it can serve as an executable specification. It decodes the
raw bytes of STXL-CLUSTD (chunks concatenated after trimming each to
CLUSTR) into (tdformat, tdline) rows.

Container format (reverse engineered, verified against READ_TEXT):
  offset 0      FF            signature
  offset 1      03..06        container version
  offset 8..11  '1100' etc.   code page as ASCII digits
  offset 16..19 uint32 LE     uncompressed length (compressed case)
  offset 20     0x12          compression algorithm (LZH); 0x10 would be LZC
  offset 21..22 1F 9D         compression magic (inherited from compress(1))
  offset 24..   bit stream    LZ77 + canonical Huffman, deflate-like
If bytes 21..22 are not 1F 9D the payload is stored uncompressed from
offset 16.

Usage:
  python3 stxl_decode.py <hexfile>     # file with CLUSTD hex (already
                                       # trimmed to CLUSTR and concatenated)
"""

import sys


class BitReader:
    """LSB-first bit reader over a byte list, mirrors the SQLScript loops."""

    def __init__(self, data, pos):
        self.data = data          # list of ints
        self.pos = pos            # next byte index (0-based)
        self.buf = 0
        self.cnt = 0

    def bit(self):
        if self.cnt == 0:
            self.buf = self.data[self.pos]
            self.pos += 1
            self.cnt = 8
        b = self.buf & 1
        self.buf >>= 1
        self.cnt -= 1
        return b

    def bits(self, n):
        """n bits, LSB first (value bits accumulate low to high)."""
        v = 0
        for k in range(n):
            v += self.bit() << k
        return v


class Huff:
    """Canonical Huffman decoder from code lengths: cnt/first/offs/syms."""

    def __init__(self, lengths):
        # lengths: list, code length per symbol (0 = unused), symbol = index
        maxlen = 15
        self.cnt = [0] * (maxlen + 1)
        for l_ in lengths:
            if l_ > 0:
                self.cnt[l_] += 1
        self.first = [0] * (maxlen + 1)
        self.offs = [0] * (maxlen + 1)
        code = 0
        tot = 0
        pos = [0] * (maxlen + 1)
        for l_ in range(1, maxlen + 1):
            if l_ > 1:
                code = (code + self.cnt[l_ - 1]) * 2
            self.first[l_] = code
            self.offs[l_] = tot
            tot += self.cnt[l_]
            pos[l_] = tot - self.cnt[l_]
        self.syms = [0] * tot
        for sym, l_ in enumerate(lengths):
            if l_ > 0:
                self.syms[pos[l_]] = sym
                pos[l_] += 1

    def decode(self, br):
        code = 0
        length = 0
        while True:
            code = code * 2 + br.bit()
            length += 1
            if length > 15:
                raise ValueError('LZH: invalid Huffman code')
            if self.cnt[length] > 0:
                tmp = code - self.first[length]
                if 0 <= tmp < self.cnt[length]:
                    return self.syms[self.offs[length] + tmp]


# deflate length/distance code tables (mirror la_lenx/la_lens/la_dstx/la_dsts)
LEN_EXTRA = [0] * 8 + [c for c in range(1, 6) for _ in range(4)] + [0]
LEN_BASE = []
_c = 3
for _j in range(28):
    LEN_BASE.append(_c)
    _c += 1 << LEN_EXTRA[_j]
LEN_BASE.append(258)
LEN_EXTRA = LEN_EXTRA[:29]

DST_EXTRA = [0 if j <= 3 else (j - 2) // 2 for j in range(30)]
DST_BASE = []
_c = 1
for _j in range(30):
    DST_BASE.append(_c)
    _c += 1 << DST_EXTRA[_j]

# order in which code lengths of the code-length alphabet arrive
CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def inflate_lzh(data, expect):
    """Decompress the SAP LZH bit stream starting at byte 24 (0-based)."""
    br = BitReader(data, 24)
    out = []
    win = [0] * 16384
    wc = 0

    v1 = br.bits(2)               # SAP framing before the deflate blocks
    if v1 > 0:
        br.bits(v1)               # value read and discarded, as in the kernel

    last = 0
    while last == 0:
        last = br.bits(1)
        btype = br.bits(2)

        if btype == 1:            # fixed Huffman tables
            lit_len = [8] * 144 + [9] * 112 + [7] * 24 + [8] * 8
            dst_len = [5] * 30
        elif btype == 2:          # dynamic tables
            nlit = 257 + br.bits(5)
            ndist = 1 + br.bits(5)
            nbl = 4 + br.bits(4)
            cl_len = [0] * 19
            for j in range(nbl):
                cl_len[CL_ORDER[j]] = br.bits(3)
            cl_huff = Huff(cl_len)

            def read_lengths(n):
                res = []
                lastlen = 0
                while len(res) < n:
                    c = cl_huff.decode(br)
                    if c < 16:
                        res.append(c)
                        lastlen = c
                    elif c == 16:
                        res += [lastlen] * (3 + br.bits(2))
                    elif c == 17:
                        res += [0] * (3 + br.bits(3))
                        lastlen = 0
                    else:
                        res += [0] * (11 + br.bits(7))
                        lastlen = 0
                return res

            lit_len = read_lengths(nlit)
            dst_len = read_lengths(ndist)
        else:
            raise ValueError('LZH: unknown block type %d' % btype)

        lit = Huff(lit_len)
        dst = Huff(dst_len)

        while True:
            sym = lit.decode(br)
            if sym < 256:
                out.append(sym)
                win[wc % 16384] = sym
                wc += 1
            elif sym == 256:
                break
            else:
                lc = sym - 256    # 1-based length code, as in the SQLScript
                mlen = LEN_BASE[lc - 1] + br.bits(LEN_EXTRA[lc - 1])
                dc = dst.decode(br)
                dist = DST_BASE[dc] + br.bits(DST_EXTRA[dc])
                src = wc - dist
                for _ in range(mlen):
                    b = win[src % 16384]
                    out.append(b)
                    win[wc % 16384] = b
                    wc += 1
                    src += 1

    if len(out) != expect:
        raise ValueError('LZH: length mismatch after decompression: '
                         '%d != %d' % (len(out), expect))
    return out


def cp1500_char(code):
    """ISO 8859-5 byte -> unicode code point, incl. the two irregulars."""
    if code >= 161:
        if code == 173:
            return 173
        if code == 240:
            return 8470      # NUMERO SIGN
        if code == 253:
            return 167       # SECTION SIGN
        return code + 864
    return code


def decode_container(data):
    """data: list of ints (CLUSTD trimmed by CLUSTR, chunks concatenated).
    Returns list of (line_no, tdformat, tdline)."""
    if data[0] != 0xFF:
        raise ValueError('STXL: stream does not start with FF')
    ver = data[1]
    cp = ''.join(chr(b) for b in data[8:12])
    if cp.startswith('8'):
        raise ValueError('STXL: unsupported MBCS codepage ' + cp)
    csize = 2 if cp in ('4102', '4103') else 1

    if len(data) >= 24 and data[21] == 0x1F and data[22] == 0x9D:
        if data[20] != 0x12:
            raise ValueError('STXL: unsupported algorithm, only LZH')
        expect = (data[16] + data[17] * 256
                  + data[18] * 65536 + data[19] * 16777216)
        out = inflate_lzh(data, expect)
    else:
        out = data[16:]

    # walk the ABAP cluster container. p is a 0-based index into out.
    rows = []
    p = 0
    rowsum = 0
    lineno = 0
    n = len(out)

    def emit_row(start, rowlen):
        nonlocal lineno
        lineno += 1
        fmt = []
        line = []
        chpos = start
        for j2 in range(1, rowlen // csize + 1):
            if csize == 2:
                # the deployed decoder reads UTF-16 pairs little-endian for
                # both 4102 and 4103 — mirrored here on purpose
                chcode = out[chpos] + out[chpos + 1] * 256
                chpos += 2
            else:
                chcode = out[chpos]
                chpos += 1
                if cp == '1500':
                    chcode = cp1500_char(chcode)
            if chcode > 0:
                (fmt if j2 <= 2 else line).append(chr(chcode))
        rows.append((lineno, ''.join(fmt).rstrip(), ''.join(line).rstrip()))

    while p < n:
        m = out[p]
        if m == 3:                                   # table descriptor
            rowsum = 0
            if ver >= 6:
                namelen = out[p + 11]
                p += 32 + namelen * csize
            elif ver >= 4:
                namelen = out[p + 6]
                p += 15 + namelen * csize
            else:
                namelen = out[p + 6]
                p += 7 + namelen
        elif m in (160, 161, 173, 174):              # typed field descriptor
            p += 7 if ver >= 6 else 4
        elif m == 170:                               # char field descriptor
            if ver >= 6:
                v = ((out[p + 3] * 256 + out[p + 4]) * 256
                     + out[p + 5]) * 256 + out[p + 6]
                p += 7
            else:
                v = ((out[p + 1] * 256 + out[p + 2]) * 256
                     + out[p + 3]) * csize
                p += 4
            rowsum += v
        elif m == 190:                               # wide descriptor
            p += 9
        elif m == 188:                               # row with explicit length
            rowlen = ((out[p + 1] * 256 + out[p + 2]) * 256
                      + out[p + 3]) * 256 + out[p + 4]
            emit_row(p + 5, rowlen)
            p += 5 + rowlen
        elif m in (189, 191):
            p += 1
        elif m == 187:                               # row, length = descriptors
            emit_row(p + 1, rowsum)
            p += 1 + rowsum
        elif m in (4, 0):                            # end / filler
            p += 1
        else:
            raise ValueError('STXL: unknown container marker %d at %d'
                             % (m, p))
    return rows


def main():
    hexstr = open(sys.argv[1]).read()
    hexstr = ''.join(hexstr.split())
    data = [int(hexstr[i:i + 2], 16) for i in range(0, len(hexstr), 2)]
    for line_no, fmt, line in decode_container(data):
        print('%3d |%-2s| %s' % (line_no, fmt, line))


if __name__ == '__main__':
    main()
