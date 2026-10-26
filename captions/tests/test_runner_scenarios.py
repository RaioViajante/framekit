"""End-to-end scenario tests for run_reference_regression.py (macOS with swiftc only).

Each scenario builds a private fixture copy whose goldens are rendered *on this machine*, so the
scenarios are independent of the committed goldens and of the machine's OS version. They check that
the runner distinguishes: exact PASS, exact FAIL, environment mismatch (NOT VERIFIED), unsupported
dependencies, nondeterministic rendering, renderer crashes and fixture integrity problems.

Run: python3 -I -m unittest discover -s captions/tests
"""
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngcmp  # noqa: E402
from test_pngcmp import make_png  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
RUNNER = os.path.join(HERE, "run_reference_regression.py")
REFERENCE = os.path.join(REPO, "captions", "reference", "render_caps.swift")
FIXTURES = os.path.join(HERE, "fixtures", "ep001")
SWIFTC = shutil.which("swiftc")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def run_runner(fixture_dir, *extra, env=None):
    r = subprocess.run([sys.executable, "-I", RUNNER, "--fixture-dir", fixture_dir, *extra],
                       capture_output=True, text=True, env=env)
    return r.returncode, r.stdout + r.stderr


@unittest.skipUnless(platform.system() == "Darwin" and SWIFTC, "needs macOS and swiftc")
class RunnerScenarios(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="raio-scenarios-")
        cls.env = json.loads(subprocess.run([sys.executable, "-I", RUNNER, "--print-environment"],
                                            capture_output=True, text=True, check=True).stdout)
        binp = os.path.join(cls.tmp, "render_caps")
        subprocess.run([SWIFTC, "-O", REFERENCE, "-o", binp], check=True, capture_output=True)
        cls.golden_src = os.path.join(cls.tmp, "golden_src")
        subprocess.run([binp, os.path.join(FIXTURES, "frames.json"), cls.golden_src], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def make_fixture(self, name, mutate_env=False):
        d = os.path.join(self.tmp, name)
        shutil.copytree(os.path.join(FIXTURES, "golden"), os.path.join(d, "golden"))
        for f in os.listdir(self.golden_src):
            shutil.copy(os.path.join(self.golden_src, f), os.path.join(d, "golden", f))
        shutil.copy(os.path.join(FIXTURES, "frames.json"), d)
        with open(os.path.join(FIXTURES, "manifest.json")) as f:
            m = json.load(f)
        m["environment"] = json.loads(json.dumps(self.env))
        for fr in m["frames"]:
            fr["sha256"] = sha(read_bytes(os.path.join(d, "golden", fr["png"])))
        if mutate_env:
            m["environment"]["swift_version"] = "Apple Swift version 0.0 (recorded elsewhere)"
        self.save(d, m)
        return d, m

    @staticmethod
    def save(d, m):
        with open(os.path.join(d, "manifest.json"), "w") as f:
            json.dump(m, f)

    def tamper(self, d, m, png="0123.png"):
        p = os.path.join(d, "golden", png)
        w, h, data = pngcmp.read_png_rgba(read_bytes(p))
        data = bytearray(data)
        for i in [i for i in range(0, len(data), 4) if data[i + 3] > 0][:3]:
            data[i] ^= 1
        new = make_png(w, h, lambda x, y: tuple(data[(y * w + x) * 4:(y * w + x) * 4 + 4]))
        with open(p, "wb") as f:
            f.write(new)
        for fr in m["frames"]:
            if fr["png"] == png:
                fr["sha256"] = sha(new)
        self.save(d, m)

    def variant_renderer(self, name, old, new):
        with open(REFERENCE) as f:
            src = f.read()
        self.assertIn(old, src)
        p = os.path.join(self.tmp, name)
        with open(p, "w") as f:
            f.write(src.replace(old, new, 1))
        return p

    # --- scenarios -------------------------------------------------------------------------------
    def test_1_exact_pass(self):
        d, _ = self.make_fixture("s1")
        code, out = run_runner(d)
        self.assertEqual(code, 0, out)
        self.assertIn("EXACT_GOLDEN_EQUIVALENCE: VERIFIED", out)
        self.assertIn("ENVIRONMENT:   MATCHES", out)

    def test_2_exact_fail_on_matching_environment(self):
        d, m = self.make_fixture("s2")
        self.tamper(d, m)
        code, out = run_runner(d)
        self.assertEqual(code, 1, out)
        self.assertIn("EXACT_GOLDEN_EQUIVALENCE: FAILED", out)
        self.assertIn('"differing_pixels": 3', out)

    def test_3_environment_mismatch_is_not_verified(self):
        d, m = self.make_fixture("s3", mutate_env=True)
        self.tamper(d, m)
        code, out = run_runner(d, "--report-dir", os.path.join(self.tmp, "rep3"))
        self.assertEqual(code, 3, out)
        self.assertIn("EXACT_GOLDEN_EQUIVALENCE: NOT VERIFIED", out)
        self.assertIn("ENVIRONMENT:   DIFFERS", out)
        self.assertIn("RENDER:", out)
        self.assertIn("DETERMINISM:   ok", out)  # other checks still ran
        with open(os.path.join(self.tmp, "rep3", "report.json")) as f:
            rep = json.load(f)
        self.assertEqual(rep["summary"]["differing_pixels"], 3)
        self.assertFalse(rep["environment_match"])

    def test_4_environment_differs_but_frames_identical_is_pass_with_note(self):
        d, _ = self.make_fixture("s4", mutate_env=True)
        code, out = run_runner(d)
        self.assertEqual(code, 0, out)
        self.assertIn("NOTE: environment differs", out)

    def test_5_missing_font_is_unsupported(self):
        d, m = self.make_fixture("s5")
        m["fonts_required"].append("FonteQueNaoExiste-Regular")
        self.save(d, m)
        code, out = run_runner(d)
        self.assertEqual(code, 2, out)
        self.assertIn("EXACT_GOLDEN_EQUIVALENCE: NOT EXECUTED", out)

    def test_6_missing_swiftc_is_unsupported(self):
        d, _ = self.make_fixture("s6")
        empty = os.path.join(self.tmp, "emptybin")
        os.makedirs(empty, exist_ok=True)
        code, out = run_runner(d, env={"PATH": empty})
        self.assertEqual(code, 2, out)
        self.assertIn("swiftc not found", out)

    def test_7_nondeterministic_renderer_is_a_hard_failure_even_on_other_environments(self):
        for label, mutate in (("match", False), ("differs", True)):
            d, _ = self.make_fixture("s7" + label, mutate_env=mutate)
            src = self.variant_renderer("nondet.swift", 'let alpha = it["alpha"] as! Double;',
                                        'let alpha = (it["alpha"] as! Double) * Double.random(in: 0.5...1.0);')
            code, out = run_runner(d, "--renderer-src", src)
            self.assertEqual(code, 1, label + out)
            self.assertIn("DETERMINISM:   FAIL", out)

    def test_8_renderer_crash_is_a_hard_failure(self):
        d, _ = self.make_fixture("s8", mutate_env=True)
        src = self.variant_renderer("crash.swift", "let args = CommandLine.arguments",
                                    'if CommandLine.arguments.count > 0 { fatalError("boom") }\nlet args = CommandLine.arguments')
        code, out = run_runner(d, "--renderer-src", src)
        self.assertEqual(code, 1, out)
        self.assertIn("RENDER:", out)

    def test_9_golden_changed_without_manifest_is_integrity_failure(self):
        d, _ = self.make_fixture("s9", mutate_env=True)
        with open(os.path.join(d, "golden", "0034.png"), "ab") as f:
            f.write(b"x")
        code, out = run_runner(d)
        self.assertEqual(code, 1, out)
        self.assertIn("INTEGRITY:", out)


if __name__ == "__main__":
    unittest.main()
