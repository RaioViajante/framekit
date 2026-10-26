"""Minimal PNG reader and RGBA comparison (standard library only).

Supports 8-bit RGBA, non-interlaced PNGs, which is what the reference renderer writes.
Every malformed input raises PngError (never a bare zlib/struct error): bad signature, truncated or
out-of-bounds chunks, CRC mismatch, missing IHDR/IEND, data after IEND, unsupported format,
implausible dimensions and decompressed size mismatch.
"""
import struct
import zlib

_SIG = b"\x89PNG\r\n\x1a\n"
MAX_DIMENSION = 16384
MAX_RAW_BYTES = 1 << 28  # 256 MiB of decoded RGBA, far above the 1080x1916 frames used here


class PngError(Exception):
    pass


def _chunks(data):
    """Yield (type, body) for every chunk after validating signature, bounds, CRC, IEND and trailing data."""
    if data[:8] != _SIG:
        raise PngError("not a PNG file")
    pos, seen_iend = 8, False
    while pos < len(data):
        if seen_iend:
            raise PngError("data after IEND")
        if pos + 12 > len(data):
            raise PngError("truncated chunk header")
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        kind = data[pos + 4:pos + 8]
        end = pos + 8 + length
        if end + 4 > len(data):
            raise PngError("chunk %r extends past end of file" % kind)
        body = data[pos + 8:end]
        (crc,) = struct.unpack(">I", data[end:end + 4])
        if zlib.crc32(kind + body) & 0xFFFFFFFF != crc:
            raise PngError("CRC mismatch in chunk %r" % kind)
        if kind == b"IEND":
            seen_iend = True
        yield kind, body
        pos = end + 4
    if not seen_iend:
        raise PngError("missing IEND")


def _ihdr(kind, body):
    if kind != b"IHDR" or len(body) != 13:
        raise PngError("first chunk is not a valid IHDR")
    width, height, depth, ctype, comp, filt, interlace = struct.unpack(">IIBBBBB", body)
    if not (0 < width <= MAX_DIMENSION and 0 < height <= MAX_DIMENSION):
        raise PngError("implausible dimensions %dx%d" % (width, height))
    return {"width": width, "height": height, "bit_depth": depth, "color_type": ctype,
            "compression": comp, "filter": filt, "interlace": interlace}


def read_png_header(data):
    """Validate the whole chunk structure (signature, CRCs, IEND) and return the IHDR fields as a dict."""
    hdr = None
    for i, (kind, body) in enumerate(_chunks(data)):
        if i == 0:
            hdr = _ihdr(kind, body)
    if hdr is None:
        raise PngError("no chunks")
    return hdr


def is_rgba8(header):
    """True for 8-bit RGBA, non-interlaced, the only format this module decodes."""
    return (header["bit_depth"], header["color_type"], header["interlace"]) == (8, 6, 0)


def read_png_rgba(data):
    """Return (width, height, bytes) with raw RGBA rows concatenated."""
    hdr, idat = None, []
    for i, (kind, body) in enumerate(_chunks(data)):
        if i == 0:
            hdr = _ihdr(kind, body)
        elif kind == b"IDAT":
            idat.append(body)
    if not is_rgba8(hdr):
        raise PngError("only 8-bit RGBA non-interlaced PNG is supported")
    width, height = hdr["width"], hdr["height"]
    stride = width * 4
    expected = height * (stride + 1)
    if expected > MAX_RAW_BYTES:
        raise PngError("decoded size too large")
    try:
        d = zlib.decompressobj()
        raw = d.decompress(b"".join(idat), expected + 1)
        if not d.eof:
            raw += d.flush()
    except zlib.error as e:
        raise PngError("zlib error: %s" % e)
    if len(raw) != expected:
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


def _visible(px):
    """Premultiplied form of one straight-alpha RGBA pixel: what is actually visible.

    Under alpha 0 the RGB values are invisible, so every such pixel maps to (0, 0, 0, 0); at low alpha
    the visible contribution of each channel is scaled down accordingly.
    """
    a = px[3]
    if a == 0:
        return (0, 0, 0, 0)
    return (a, (px[0] * a + 127) // 255, (px[1] * a + 127) // 255, (px[2] * a + 127) // 255)


def compare_rgba(a, b):
    """Compare two (width, height, rgba) images. Returns a dict describing the difference.

    differing_pixels is the raw count (any stored byte differs) and is what exact equivalence means.
    visible_differing_pixels counts only pixels whose premultiplied (visible) value differs; it is
    what the cross-environment sanity screen uses, so changes to invisible RGB under alpha 0 do not
    count as visual differences.
    """
    wa, ha, da = a
    wb, hb, db = b
    if (wa, ha) != (wb, hb):
        return {"equal": False, "dimensions_differ": True, "expected": [wa, ha], "actual": [wb, hb]}
    stride = wa * 4
    differing, visible, max_diff = 0, 0, 0
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
            if _visible(pa) != _visible(pb):
                visible += 1
            max_diff = max(max_diff, d)
            for key, (lo, hi) in zip(keys, _BUCKETS):
                if lo <= d <= hi:
                    hist[key] += 1
                    break
            xs.append(x)
            ys.append(y)
    if differing == 0:
        return {"equal": True, "dimensions_differ": False, "differing_pixels": 0, "visible_differing_pixels": 0}
    return {
        "equal": False,
        "dimensions_differ": False,
        "differing_pixels": differing,
        "visible_differing_pixels": visible,
        "total_pixels": wa * ha,
        "max_channel_diff": max_diff,
        "histogram_by_max_channel_diff": hist,
        "bbox_x_y_x_y": [min(xs), min(ys), max(xs), max(ys)],
    }


def ink_stats(img):
    """Return (ink_pixels, bbox) where ink is any pixel with alpha > 0; bbox is [x0, y0, x1, y1] or None."""
    w, h, data = img
    alpha = data[3::4]
    count, x0, x1, ys = 0, w, -1, []
    for y in range(h):
        row = alpha[y * w:(y + 1) * w]
        n = w - row.count(0)
        if n:
            count += n
            ys.append(y)
            x0 = min(x0, w - len(row.lstrip(b"\0")))
            x1 = max(x1, w - len(row.rstrip(b"\0")) - 1)
    return count, ([x0, ys[0], x1, ys[-1]] if count else None)


def visual_sanity_metrics(golden, actual, diff):
    """Metrics for the cross-environment gross-defect screen. `diff` is compare_rgba(golden, actual).

    ink_diff_fraction = visible differing pixels / max(ink pixels in golden, ink pixels in actual, 1),
    where "visible" compares premultiplied values (RGB under alpha 0 is ignored; see compare_rgba).
    A blank caption, an extra caption on an empty frame, displaced, resized or restyled text all give
    large values; anti-aliasing noise between OS builds gives very small ones.
    """
    gi, gb = ink_stats(golden)
    ai, ab = ink_stats(actual)
    differing = diff.get("visible_differing_pixels", 0)
    shift = None
    if gb and ab:
        shift = max(abs(p - q) for p, q in zip(gb, ab))
    return {"golden_ink_pixels": gi, "actual_ink_pixels": ai, "differing_pixels": diff.get("differing_pixels", 0),
            "visible_differing_pixels": differing,
            "ink_diff_fraction": differing / max(gi, ai, 1), "bbox_max_edge_shift": shift}
