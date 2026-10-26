"""Minimal PNG reader and RGBA comparison (standard library only).

Supports 8-bit RGBA, non-interlaced PNGs, which is what the reference renderer writes.
"""
import struct
import zlib

_SIG = b"\x89PNG\r\n\x1a\n"


class PngError(Exception):
    pass


def read_png_rgba(data):
    """Return (width, height, bytes) with raw RGBA rows concatenated."""
    if data[:8] != _SIG:
        raise PngError("not a PNG file")
    pos, idat, hdr = 8, [], None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            hdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat.append(body)
        pos += 12 + length
    if hdr is None:
        raise PngError("missing IHDR")
    width, height, depth, ctype, _comp, _filt, interlace = hdr
    if (depth, ctype, interlace) != (8, 6, 0):
        raise PngError("only 8-bit RGBA non-interlaced PNG is supported")
    raw = zlib.decompress(b"".join(idat))
    stride = width * 4
    if len(raw) != height * (stride + 1):
        raise PngError("unexpected decompressed size")
    out = bytearray(height * stride)
    prev = bytearray(stride)
    for y in range(height):
        base = y * (stride + 1)
        ft = raw[base]
        row = bytearray(raw[base + 1:base + 1 + stride])
        if ft == 1:
            for i in range(4, stride):
                row[i] = (row[i] + row[i - 4]) & 255
        elif ft == 2:
            for i in range(stride):
                row[i] = (row[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                left = row[i - 4] if i >= 4 else 0
                row[i] = (row[i] + ((left + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = row[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[i] = (row[i] + pred) & 255
        elif ft != 0:
            raise PngError("unknown filter type %d" % ft)
        out[y * stride:(y + 1) * stride] = row
        prev = row
    return width, height, bytes(out)


_BUCKETS = ((1, 1), (2, 4), (5, 16), (17, 64), (65, 255))


def compare_rgba(a, b):
    """Compare two (width, height, rgba) images. Returns a dict describing the difference."""
    wa, ha, da = a
    wb, hb, db = b
    if (wa, ha) != (wb, hb):
        return {"equal": False, "dimensions_differ": True, "expected": [wa, ha], "actual": [wb, hb]}
    stride = wa * 4
    differing, max_diff = 0, 0
    hist = {"%d-%d" % bk if bk[0] != bk[1] else str(bk[0]): 0 for bk in _BUCKETS}
    keys = list(hist)
    xs, ys = [], []
    for y in range(ha):
        ra = da[y * stride:(y + 1) * stride]
        rb = db[y * stride:(y + 1) * stride]
        if ra == rb:
            continue
        for x in range(wa):
            pa, pb = ra[x * 4:x * 4 + 4], rb[x * 4:x * 4 + 4]
            if pa == pb:
                continue
            d = max(abs(pa[k] - pb[k]) for k in range(4))
            differing += 1
            max_diff = max(max_diff, d)
            for key, (lo, hi) in zip(keys, _BUCKETS):
                if lo <= d <= hi:
                    hist[key] += 1
                    break
            xs.append(x)
            ys.append(y)
    if differing == 0:
        return {"equal": True, "dimensions_differ": False, "differing_pixels": 0}
    return {
        "equal": False,
        "dimensions_differ": False,
        "differing_pixels": differing,
        "total_pixels": wa * ha,
        "max_channel_diff": max_diff,
        "histogram_by_max_channel_diff": hist,
        "bbox_x_y_x_y": [min(xs), min(ys), max(xs), max(ys)],
    }
