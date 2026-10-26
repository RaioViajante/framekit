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

    # --- malformed input is always PngError --------------------------------------------------
    def _good(self):
        return make_png(6, 4, px)

    def test_truncated_and_corrupted_inputs_raise_pngerror(self):
        g = self._good()
        for name, bad in (
            ("empty", b""),
            ("truncated mid-chunk", g[:40]),
            ("truncated header", g[:30]),
            ("missing IEND", g[:-12]),
            ("trailing data", g + b"junk"),
            ("corrupted IDAT byte", g[:60] + bytes([g[60] ^ 255]) + g[61:]),
        ):
            with self.subTest(name):
                with self.assertRaises(pngcmp.PngError):
                    pngcmp.read_png_rgba(bad)
                with self.assertRaises(pngcmp.PngError):
                    pngcmp.read_png_header(bad)

    def test_implausible_dimensions_are_rejected_without_allocating(self):
        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        huge = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 100000, 100000, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(b"\0" * 100)) + chunk(b"IEND", b""))
        with self.assertRaises(pngcmp.PngError):
            pngcmp.read_png_rgba(huge)

    def test_header_reports_format(self):
        h = pngcmp.read_png_header(self._good())
        self.assertEqual((h["width"], h["height"]), (6, 4))
        self.assertTrue(pngcmp.is_rgba8(h))

        def chunk(kind, body):
            return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        rgb = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
               + chunk(b"IDAT", zlib.compress(b"\0" * 14)) + chunk(b"IEND", b""))
        self.assertFalse(pngcmp.is_rgba8(pngcmp.read_png_header(rgb)))
        with self.assertRaises(pngcmp.PngError):
            pngcmp.read_png_rgba(rgb)

    # --- cross-environment sanity metrics ------------------------------------------------------
    def test_ink_stats_and_sanity_metrics(self):
        def img(shift=0, blank=False):
            return pngcmp.read_png_rgba(make_png(40, 20, lambda x, y: (255, 255, 255, 255) if (not blank and 10 + shift <= x < 20 + shift and 5 <= y < 10) else (0, 0, 0, 0)))
        g = img()
        self.assertEqual(pngcmp.ink_stats(g), (50, [10, 5, 19, 9]))
        same = pngcmp.visual_sanity_metrics(g, g, pngcmp.compare_rgba(g, g))
        self.assertEqual(same["ink_diff_fraction"], 0)
        blank = img(blank=True)
        m = pngcmp.visual_sanity_metrics(g, blank, pngcmp.compare_rgba(g, blank))
        self.assertEqual(m["ink_diff_fraction"], 1.0)
        moved = img(shift=3)
        m = pngcmp.visual_sanity_metrics(g, moved, pngcmp.compare_rgba(g, moved))
        self.assertEqual((m["ink_diff_fraction"], m["bbox_max_edge_shift"]), (30 / 50, 3))
        empty = img(blank=True)
        stray = pngcmp.read_png_rgba(make_png(40, 20, lambda x, y: (1, 1, 1, 9) if (x, y) == (3, 3) else (0, 0, 0, 0)))
        m = pngcmp.visual_sanity_metrics(empty, stray, pngcmp.compare_rgba(empty, stray))
        self.assertEqual(m["ink_diff_fraction"], 1.0)  # an empty frame must stay empty

    def test_invisible_rgb_under_alpha_zero_is_not_a_visible_difference(self):
        a = pngcmp.read_png_rgba(make_png(4, 4, lambda x, y: (0, 0, 0, 0)))
        b = pngcmp.read_png_rgba(make_png(4, 4, lambda x, y: (200, 10, 10, 0) if x < 2 else (0, 0, 0, 0)))
        d = pngcmp.compare_rgba(a, b)
        self.assertEqual((d["differing_pixels"], d["visible_differing_pixels"]), (8, 0))
        self.assertEqual(pngcmp.visual_sanity_metrics(a, b, d)["ink_diff_fraction"], 0)

    def test_visible_difference_uses_premultiplied_values(self):
        # alpha 1: a change of 100 in R scales to 0 after premultiplication (invisible); alpha 255: visible.
        faint_a = pngcmp.read_png_rgba(make_png(2, 1, lambda x, y: (0, 0, 0, 1)))
        faint_b = pngcmp.read_png_rgba(make_png(2, 1, lambda x, y: (100, 0, 0, 1)))
        self.assertEqual(pngcmp.compare_rgba(faint_a, faint_b)["visible_differing_pixels"], 0)
        solid_a = pngcmp.read_png_rgba(make_png(2, 1, lambda x, y: (0, 0, 0, 255)))
        solid_b = pngcmp.read_png_rgba(make_png(2, 1, lambda x, y: (1, 0, 0, 255)))
        self.assertEqual(pngcmp.compare_rgba(solid_a, solid_b)["visible_differing_pixels"], 2)
        alpha_a = pngcmp.read_png_rgba(make_png(2, 1, lambda x, y: (0, 0, 0, 0)))
        alpha_b = pngcmp.read_png_rgba(make_png(2, 1, lambda x, y: (0, 0, 0, 1)))
        self.assertEqual(pngcmp.compare_rgba(alpha_a, alpha_b)["visible_differing_pixels"], 2)  # alpha itself is visible


if __name__ == "__main__":
    unittest.main()
