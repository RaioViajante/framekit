"""Tests for verify_fonts(): the font check must never succeed vacuously. Portable (uses fake checkers)."""
import json
import os
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_reference_regression as rr  # noqa: E402

NAMES = ["FontA", "FontB"]


def ok_line(name, available=True, version="1.0", file="x.ttc"):
    return json.dumps({"requested": name, "resolved": name if available else "Helvetica", "available": available,
                       "version": version, "file": file})


class VerifyFonts(unittest.TestCase):
    def fake(self, body):
        d = tempfile.mkdtemp(prefix="framekit-fakefont-")
        self.addCleanup(lambda: __import__("shutil").rmtree(d, ignore_errors=True))
        path = os.path.join(d, "check_fonts")
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body + "\n")
        os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)
        return path

    def printer(self, lines, status):
        return self.fake("cat <<'EOF'\n%s\nEOF\nexit %d" % ("\n".join(lines), status))

    def check(self, body_or_path, names=NAMES, timeout=10):
        return rr.verify_fonts(body_or_path, names, timeout=timeout)

    def test_all_fonts_ok(self):
        r = self.check(self.printer([ok_line("FontA"), ok_line("FontB")], 0))
        self.assertEqual((r["status"], r["missing"]), (rr.FONT_OK, []))
        self.assertEqual(len(r["infos"]), 2)

    def test_missing_font_is_unsupported_not_failed(self):
        r = self.check(self.printer([ok_line("FontA"), ok_line("FontB", available=False)], 1))
        self.assertEqual((r["status"], r["missing"]), (rr.FONT_UNSUPPORTED, ["FontB"]))

    def test_empty_output_with_success_status_is_failed(self):
        self.assertEqual(self.check(self.fake("exit 0"))["status"], rr.FONT_FAILED)

    def test_empty_output_with_status_one_is_failed(self):
        self.assertEqual(self.check(self.fake("exit 1"))["status"], rr.FONT_FAILED)

    def test_crash_and_other_nonzero_status_are_failed(self):
        self.assertEqual(self.check(self.fake("kill -SEGV $$"))["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(self.fake("echo oops >&2; exit 3"))["status"], rr.FONT_FAILED)

    def test_timeout_is_failed(self):
        r = self.check(self.fake("sleep 5"), timeout=1)
        self.assertEqual(r["status"], rr.FONT_FAILED)
        self.assertIn("timed out", r["detail"])

    def test_malformed_output_is_failed(self):
        self.assertEqual(self.check(self.printer(["not json", ok_line("FontB")], 0))["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(self.printer(['{"requested": "FontA"}', ok_line("FontB")], 0))["status"], rr.FONT_FAILED)
        bad_type = json.dumps({"requested": "FontA", "resolved": "FontA", "available": "yes", "version": "1", "file": "x"})
        self.assertEqual(self.check(self.printer([bad_type, ok_line("FontB")], 0))["status"], rr.FONT_FAILED)

    def test_wrong_number_or_names_of_entries_is_failed(self):
        self.assertEqual(self.check(self.printer([ok_line("FontA")], 0))["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(self.printer([ok_line("FontA"), ok_line("FontA")], 0))["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(self.printer([ok_line("FontA"), ok_line("FontB"), ok_line("FontC")], 0))["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(self.printer([ok_line("FontA"), ok_line("Other")], 0))["status"], rr.FONT_FAILED)

    def test_output_contradicting_exit_status_is_failed(self):
        self.assertEqual(self.check(self.printer([ok_line("FontA"), ok_line("FontB")], 1))["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(self.printer([ok_line("FontA"), ok_line("FontB", available=False)], 0))["status"], rr.FONT_FAILED)

    def test_empty_or_duplicate_requested_names_are_failed(self):
        ok = self.printer([ok_line("FontA")], 0)
        self.assertEqual(self.check(ok, names=[])["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(ok, names=["FontA", "FontA"])["status"], rr.FONT_FAILED)
        self.assertEqual(self.check(ok, names=[""])["status"], rr.FONT_FAILED)

    def test_missing_checker_binary_is_failed(self):
        r = rr.verify_fonts("/nonexistent/check_fonts", NAMES, timeout=5)
        self.assertEqual(r["status"], rr.FONT_FAILED)


if __name__ == "__main__":
    unittest.main()
