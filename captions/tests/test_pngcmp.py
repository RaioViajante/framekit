"""Unit tests for pngcmp (portable; no macOS required). Run: python3 -I -m unittest discover captions/tests"""
import os
import struct
import sys
import unittest
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngcmp  # noqa: E402


def make_png(w, h, pixel, filter_type=0):
    """Encode a w*h RGBA PNG. pixel(x, y) -> (r, g, b, a). filter_type applies to every row."""
    rows = []
    prev = bytes(w * 4)
    for y in range(h):
        cur = bytes(c for x in range(w) for c in pixel(x, y))
        if filter_type == 0:
            enc = cur
        elif filter_type == 1:
            enc = bytes((cur[i] - (cur[i - 4] if i >= 4 else 0)) & 255 for i in range(len(cur)))
        elif filter_type == 2:
            enc = bytes((cur[i] - prev[i]) & 255 for i in range(len(cur)))
        elif filter_type == 3:
            enc = bytes((cur[i] - (((cur[i - 4] if i >= 4 else 0) + prev[i]) >> 1)) & 255 for i in range(len(cur)))
        else:
            def paeth(a, b, c):
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                return a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            enc = bytes((cur[i] - paeth(cur[i - 4] if i >= 4 else 0, prev[i], prev[i - 4] if i >= 4 else 0)) & 255 for i in range(len(cur)))
        rows.append(bytes([filter_type]) + enc)
        prev = cur

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows))) + chunk(b"IEND", b""))


def px(x, y):
    return ((x * 37) & 255, (y * 91) & 255, (x * y) & 255, 255 if (x + y) % 3 else 128)


class PngCmpTests(unittest.TestCase):
    def test_roundtrip_all_filters(self):
        for ft in range(5):
            w, h, data = pngcmp.read_png_rgba(make_png(7, 5, px, ft))
            self.assertEqual((w, h), (7, 5))
            self.assertEqual(data, bytes(c for y in range(5) for x in range(7) for c in px(x, y)), "filter %d" % ft)

    def test_identical(self):
        a = pngcmp.read_png_rgba(make_png(6, 4, px))
        self.assertTrue(pngcmp.compare_rgba(a, a)["equal"])

    def test_one_channel_off_by_one_is_reported(self):
        a = pngcmp.read_png_rgba(make_png(6, 4, px))
        b = pngcmp.read_png_rgba(make_png(6, 4, lambda x, y: (px(x, y)[0] ^ 1,) + px(x, y)[1:] if (x, y) == (2, 3) else px(x, y)))
        d = pngcmp.compare_rgba(a, b)
        self.assertFalse(d["equal"])
        self.assertEqual((d["differing_pixels"], d["max_channel_diff"]), (1, 1))
        self.assertEqual(d["bbox_x_y_x_y"], [2, 3, 2, 3])
        self.assertEqual(d["histogram_by_max_channel_diff"]["1"], 1)

    def test_alpha_difference_is_reported(self):
        a = pngcmp.read_png_rgba(make_png(3, 3, lambda x, y: (10, 20, 30, 255)))
        b = pngcmp.read_png_rgba(make_png(3, 3, lambda x, y: (10, 20, 30, 200)))
        d = pngcmp.compare_rgba(a, b)
        self.assertEqual((d["differing_pixels"], d["max_channel_diff"]), (9, 55))

    def test_dimension_mismatch(self):
        d = pngcmp.compare_rgba(pngcmp.read_png_rgba(make_png(3, 3, px)), pngcmp.read_png_rgba(make_png(4, 3, px)))
        self.assertTrue(d["dimensions_differ"])

    def test_rejects_unsupported(self):
        with self.assertRaises(pngcmp.PngError):
            pngcmp.read_png_rgba(b"not a png")


if __name__ == "__main__":
    unittest.main()
