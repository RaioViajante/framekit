#!/usr/bin/env python3
"""Regression test for the frozen EP001 reference caption renderer.

Compiles captions/reference/render_caps.swift, renders the fixture frames twice into isolated
temporary directories and compares them with the committed golden PNGs.

Three results are reported separately:

  EXACT_GOLDEN_EQUIVALENCE  VERIFIED | FAILED | NOT VERIFIED | NOT EXECUTED | NOT APPLICABLE (test hook)
  RENDER_INTEGRITY          OK | FAILED | NOT EVALUATED
                            fixtures vs manifest, compile, render, output file set, PNG structure
                            (width, height, 8-bit RGBA), determinism across repeated runs
  CROSS_ENV_VISUAL_SANITY   PASSED | FAILED | NOT APPLICABLE | NOT EVALUATED
                            a conservative gross-defect screen, used only when the environment
                            differs from the recorded one. PASSED is NOT pixel equivalence.

The golden PNGs are only meaningful on the environment they were captured on (macOS version and
build, arch, Swift toolchain, and the version/file of each font; see manifest.json):

  environment MATCHES, any pixel difference          -> FAIL
  environment DIFFERS, frames identical              -> PASS
  environment DIFFERS, frames differ, structure ok,
    sanity screen passed                             -> NOT VERIFIED
  environment DIFFERS, frames differ, sanity failed  -> FAIL

Hard failures in ANY environment: fixture/manifest inconsistencies, a golden or rendered PNG that is
not a valid 8-bit RGBA PNG of the expected width and height, compile error, renderer crash or timeout,
wrong output files, nondeterministic output, and a font verification that did not work (empty or
malformed checker output, wrong number of entries, crash, timeout). Fonts that verifiably do not
resolve exactly are a different outcome: UNSUPPORTED.

Sanity screen: for each differing frame, ink_diff_fraction = visible differing pixels / max(ink pixels
in the golden, ink pixels in the output, 1), where ink is alpha > 0 and "visible" compares premultiplied
values (RGB under alpha 0 is invisible and ignored). It must be <= SANITY_MAX_INK_DIFF_FRACTION. Exact
equivalence is a separate check on the stored bytes and is not affected by this definition.
Calibration and limits are documented in docs/regression-testing.md. No tolerance applies to exact equivalence.

Exit status (also printed in the final RESULT line):
  0   PASS          every frame was byte-identical to its golden (exact equivalence established;
                    a note is printed when the environment differed from the recorded one)
  1   FAIL          see above
  2   UNSUPPORTED   the environment cannot run the test (not macOS, no swiftc, fonts missing).
                    Nothing was compared. This is NOT a pass.
  3   NOT VERIFIED  frames differ from the goldens, the environment differs from the recorded one,
                    render integrity is OK and the sanity screen passed. Exact equivalence is NOT
                    established. This is NOT a pass.
  64  USAGE         invalid command-line usage; nothing was run.

Note: the Python interpreter itself exits with 2 when the script path is wrong; that is not UNSUPPORTED.

This runner never writes to the golden directory. Goldens change only by a deliberate commit.
"""
import argparse
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngcmp  # noqa: E402

REPO = os.path.dirname(os.path.dirname(HERE))
RENDERER_SRC = os.path.join(REPO, "captions", "reference", "render_caps.swift")
FONT_CHECK_SRC = os.path.join(HERE, "check_fonts.swift")
FIXTURE_DIR = os.path.join(HERE, "fixtures", "ep001")

PASS, FAIL, UNSUPPORTED, NOT_VERIFIED, USAGE = 0, 1, 2, 3, 64

# Cross-environment sanity screen. Calibrated on one environment pair (macOS 26.6.2 vs 27.0.1, nine
# frames): the largest variation measured was 0.038% of ink pixels, while the mildest degradation tried
# (text shifted by 1 px) already changed 49% or more. 1% is ~26x above the former and ~49x below the
# latter. See docs/regression-testing.md for limits.
SANITY_MAX_INK_DIFF_FRACTION = 0.01
RENDER_TIMEOUT_S = 300
BUILD_TIMEOUT_S = 900
HOOK_ENV = "FRAMEKIT_CAPTION_TEST_HOOK"
FONT_CHECK_TIMEOUT_S = 120
LABELS = {
    USAGE: "USAGE ERROR (nothing was run)",
    PASS: "PASS",
    FAIL: "FAIL",
    UNSUPPORTED: "UNSUPPORTED (visual regression NOT executed)",
    NOT_VERIFIED: "NOT VERIFIED (environment differs from the goldens; exact equivalence NOT established)",
}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd, timeout=BUILD_TIMEOUT_S, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, **kw)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(cmd, 124, "", "timed out after %ss" % timeout)
    except OSError as e:  # missing or non-executable binary
        return subprocess.CompletedProcess(cmd, 127, "", "cannot execute %s: %s" % (cmd[0], e))


def mac_build():
    r = run(["sw_vers", "-buildVersion"])
    return r.stdout.strip() if r.returncode == 0 else ""


def swift_first_line(swiftc):
    return run([swiftc, "--version"]).stdout.strip().splitlines()[0]


FONT_OK, FONT_UNSUPPORTED, FONT_FAILED = "ok", "unsupported", "failed"


def verify_fonts(fonts_bin, names, timeout=FONT_CHECK_TIMEOUT_S):
    """Run the font checker and return {"status", "infos", "missing", "detail"}.

    status is one of:
      ok           the checker ran, reported exactly the requested fonts, and all resolve exactly
      unsupported  the checker ran correctly and reports that some fonts do not resolve exactly
      failed       the verification itself did not work: empty or malformed output, a missing or
                   duplicated font entry, a crash, a nonzero status other than 1, a timeout, or
                   output that contradicts the exit status. Never treated as success.
    """
    def fail(detail):
        return {"status": FONT_FAILED, "infos": [], "missing": [], "detail": detail}

    if not isinstance(names, list) or not names or len(set(names)) != len(names) or not all(isinstance(n, str) and n for n in names):
        return fail("the manifest must list at least one distinct required font name")
    r = run([fonts_bin] + names, timeout=timeout)
    if r.returncode == 124:
        return fail("font checker timed out after %ss" % timeout)
    if r.returncode not in (0, 1):
        return fail("font checker exited with status %s%s" % (r.returncode, (": " + r.stderr.strip()[:120]) if r.stderr.strip() else ""))
    lines = [ln for ln in r.stdout.splitlines() if ln.strip()]
    infos = []
    for ln in lines:
        try:
            info = json.loads(ln)
            if not (isinstance(info["requested"], str) and isinstance(info["resolved"], str) and isinstance(info["available"], bool)
                    and isinstance(info["version"], str) and isinstance(info["file"], str)):
                raise TypeError("wrong field types")
        except (ValueError, KeyError, TypeError) as e:
            return fail("malformed font checker output (%s): %r" % (e, ln[:80]))
        infos.append(info)
    if sorted(i["requested"] for i in infos) != sorted(names):
        return fail("font checker reported %d entries for %d requested fonts (%s)"
                    % (len(infos), len(names), ", ".join(i["requested"] for i in infos) or "none"))
    missing = [i["requested"] for i in infos if not i["available"]]
    if (r.returncode == 1) != bool(missing):
        return fail("font checker exit status %d contradicts its output (%d fonts unavailable)" % (r.returncode, len(missing)))
    return {"status": FONT_UNSUPPORTED if missing else FONT_OK, "infos": infos, "missing": missing, "detail": ""}


def environment_differences(recorded, current):
    """Compare the recorded environment with the current one; return a list of readable differences."""
    diffs = []
    for key in ("macos_version", "macos_build", "arch", "swift_version"):
        if recorded.get(key) != current.get(key):
            diffs.append("%s: recorded %r, current %r" % (key, recorded.get(key), current.get(key)))
    rec_fonts, cur_fonts = recorded.get("fonts", {}), current.get("fonts", {})
    for name in sorted(set(rec_fonts) | set(cur_fonts)):
        r, c = rec_fonts.get(name), cur_fonts.get(name)
        if r != c:
            diffs.append("font %s: recorded %r, current %r" % (name, r, c))
    return diffs


class Runner:
    def __init__(self, args):
        self.args = args
        self.fixture_dir = os.path.abspath(args.fixture_dir)
        self.golden_dir = os.path.join(self.fixture_dir, "golden")
        self.frames_json = os.path.join(self.fixture_dir, "frames.json")
        with open(os.path.join(self.fixture_dir, "manifest.json")) as f:
            self.manifest = json.load(f)
        self.hook = bool(args.renderer_src)
        self.renderer_src = os.path.abspath(args.renderer_src) if self.hook else RENDERER_SRC
        self.integrity = "NOT EVALUATED"
        self.sanity = "NOT EVALUATED"
        self.report = {"checks": {}, "frames": [], "notes": []}

    # -- reporting ------------------------------------------------------------------------------
    def check(self, name, status, detail=""):
        self.report["checks"][name] = {"status": status, "detail": detail}
        print("%-14s %s%s" % (name.upper() + ":", status, (" - " + detail) if detail else ""))

    def finish(self, code, message, equivalence):
        if self.hook:
            equivalence = "NOT APPLICABLE (TEST HOOK: the renderer is not the frozen reference)"
            message += " [TEST HOOK - not a baseline run]"
        self.report["exact_golden_equivalence"] = equivalence
        self.report["render_integrity"] = self.integrity
        self.report["cross_env_visual_sanity"] = self.sanity
        self.report["result"] = {"code": code, "label": LABELS[code], "message": message}
        print("\nEXACT_GOLDEN_EQUIVALENCE: %s" % equivalence)
        print("RENDER_INTEGRITY: %s" % self.integrity)
        print("CROSS_ENV_VISUAL_SANITY: %s" % self.sanity)
        print("RESULT: %s - %s" % (LABELS[code], message))
        if self.args.report_dir:
            os.makedirs(self.args.report_dir, exist_ok=True)
            with open(os.path.join(self.args.report_dir, "report.json"), "w") as f:
                json.dump(self.report, f, indent=2, sort_keys=True)
                f.write("\n")
            with open(os.path.join(self.args.report_dir, "report.md"), "w") as f:
                f.write(self.markdown(code, message, equivalence))
        return code

    def markdown(self, code, message, equivalence):
        lines = ["# Caption reference regression", "", "**Result: %s**" % LABELS[code], "",
                 "| Dimension | Status |", "|---|---|",
                 "| Exact golden equivalence | %s |" % equivalence,
                 "| Render integrity | %s |" % self.integrity,
                 "| Cross-environment visual sanity | %s |" % self.sanity, "",
                 message, "",
                 "| Check | Status | Detail |", "|---|---|---|"]
        for name, c in self.report["checks"].items():
            lines.append("| %s | %s | %s |" % (name, c["status"], c["detail"].replace("|", "/")))
        if self.report["frames"]:
            lines += ["", "| Frame | Covers | Exact | Differing px | Max channel diff | Ink diff fraction |", "|---|---|---|---|---|---|"]
            for fr in self.report["frames"]:
                d = fr.get("diff") or {}
                sm = fr.get("sanity") or {}
                lines.append("| %s | %s | %s | %s | %s | %s |" % (
                    fr["source_frame"], fr["covers"], "yes" if fr["byte_identical"] else "NO",
                    d.get("differing_pixels", 0), d.get("max_channel_diff", 0),
                    ("%.6f" % sm["ink_diff_fraction"]) if "ink_diff_fraction" in sm else "-"))
        for n in self.report["notes"]:
            lines += ["", "> " + n]
        return "\n".join(lines) + "\n"

    def header_problems(self, label, data, frame):
        """Structure problems of a PNG against the manifest (size and 8-bit RGBA format)."""
        fmt = self.manifest["image_format"]
        try:
            h = pngcmp.read_png_header(data)
        except pngcmp.PngError as e:
            return ["%s: invalid PNG (%s)" % (label, e)]
        problems = []
        if (h["width"], h["height"]) != (frame["width"], frame["height"]):
            problems.append("%s: dimensions %dx%d, expected %dx%d" % (label, h["width"], h["height"], frame["width"], frame["height"]))
        if (h["bit_depth"], h["color_type"], h["interlace"]) != (fmt["bit_depth"], fmt["color_type"], fmt["interlace"]):
            problems.append("%s: format bit_depth=%d color_type=%d interlace=%d, expected %s"
                            % (label, h["bit_depth"], h["color_type"], h["interlace"], fmt["description"]))
        return problems

    # -- main flow ------------------------------------------------------------------------------
    def main(self):
        rec = self.manifest["environment"]
        print("Environment: %s %s (%s)" % (platform.system(), platform.mac_ver()[0] or platform.release(), platform.machine()))
        if self.hook:
            print("TEST HOOK: using renderer source %s instead of the frozen reference" % self.renderer_src)
            self.report["notes"].append("TEST HOOK active: renderer source overridden; not a baseline run")
        if platform.system() != "Darwin":
            self.check("platform", "UNSUPPORTED", "requires macOS (CoreText); running on %s" % platform.system())
            return self.finish(UNSUPPORTED, "requires macOS", "NOT EXECUTED")
        swiftc = shutil.which("swiftc")
        if not swiftc:
            self.check("toolchain", "UNSUPPORTED", "swiftc not found; install Xcode Command Line Tools")
            return self.finish(UNSUPPORTED, "swiftc not found", "NOT EXECUTED")
        current = {"macos_version": platform.mac_ver()[0], "macos_build": mac_build(),
                   "arch": platform.machine(), "swift_version": swift_first_line(swiftc), "fonts": {}}

        # fixture/manifest integrity: a hard failure in every environment
        problems = []
        if not self.hook and sha256_file(self.renderer_src) != self.manifest["renderer"]["sha256"]:
            problems.append("renderer source differs from manifest SHA-256")
        if sha256_file(self.frames_json) != self.manifest["frames_json"]["sha256"]:
            problems.append("frames.json differs from manifest SHA-256")
        if not self.manifest.get("fonts_required"):
            problems.append("manifest lists no required fonts")
        expected = {fr["png"]: fr for fr in self.manifest["frames"]}
        present = sorted(n for n in os.listdir(self.golden_dir) if n.endswith(".png"))
        if present != sorted(expected):
            problems.append("golden file set %s does not match manifest %s" % (present, sorted(expected)))
        for name, fr in expected.items():
            p = os.path.join(self.golden_dir, name)
            if not os.path.exists(p):
                continue
            if sha256_file(p) != fr["sha256"]:
                problems.append("golden %s differs from manifest SHA-256" % name)
            with open(p, "rb") as f:
                problems += self.header_problems("golden " + name, f.read(), fr)
        if problems:
            self.integrity = "FAILED"
            self.check("integrity", "FAIL", "; ".join(problems))
            return self.finish(FAIL, "fixtures are inconsistent with manifest.json (goldens are never updated automatically)", "NOT VERIFIED")
        self.check("integrity", "ok", "renderer, frames.json and %d goldens match manifest.json (SHA-256, size, 8-bit RGBA)" % len(expected))

        with tempfile.TemporaryDirectory(prefix="framekit-caption-reg-") as tmp:
            # fonts: a missing font is an unsupported environment (CoreText would substitute)
            fonts_bin = os.path.join(tmp, "check_fonts")
            r = run([swiftc, "-O", FONT_CHECK_SRC, "-o", fonts_bin])
            if r.returncode != 0:
                print(r.stderr)
                self.integrity = "FAILED"
                self.check("fonts", "FAIL", "could not compile check_fonts.swift")
                return self.finish(FAIL, "could not compile check_fonts.swift", "NOT VERIFIED")
            fv = verify_fonts(fonts_bin, self.manifest["fonts_required"])
            for info in fv["infos"]:
                print("Font:        %-22s %s (version %s, file %s)" % (
                    info["requested"], "ok" if info["available"] else "MISSING -> resolved to " + info["resolved"], info["version"], info["file"]))
                current["fonts"][info["requested"]] = {"version": info["version"], "file": info["file"]}
            self.report["current_environment"] = current
            if fv["status"] == FONT_FAILED:
                self.integrity = "FAILED"
                self.check("fonts", "FAIL", "font verification failed: " + fv["detail"])
                return self.finish(FAIL, "font verification failed (not the same as unsupported fonts): " + fv["detail"], "NOT VERIFIED")
            if fv["status"] == FONT_UNSUPPORTED:
                self.check("fonts", "UNSUPPORTED", "not available: %s" % ", ".join(fv["missing"]))
                return self.finish(UNSUPPORTED, "required fonts are not available; CoreText would substitute and the comparison would be meaningless", "NOT EXECUTED")
            self.check("fonts", "ok", "all %d required fonts verified and resolve exactly" % len(current["fonts"]))

            # environment match (macOS build, arch, Swift and each font's version/file)
            diffs = environment_differences(rec, current)
            env_match = not diffs
            self.report["environment_match"] = env_match
            self.report["environment_differences"] = diffs
            if env_match:
                self.check("environment", "MATCHES", "same macOS build, arch, Swift and font versions as the goldens")
            else:
                self.check("environment", "DIFFERS", "; ".join(diffs))

            # build and render twice
            renderer_bin = os.path.join(tmp, "render_caps")
            r = run([swiftc, "-O", self.renderer_src, "-o", renderer_bin])
            if r.returncode != 0 or not os.path.exists(renderer_bin):
                print(r.stderr)
                self.integrity = "FAILED"
                self.check("build", "FAIL", "reference renderer failed to compile")
                return self.finish(FAIL, "reference renderer failed to compile", "NOT VERIFIED")
            self.check("build", "ok")
            outs = []
            for label in ("A", "B"):
                out = os.path.join(tmp, "out_" + label)
                r = run([renderer_bin, self.frames_json, out], timeout=RENDER_TIMEOUT_S)
                if r.returncode != 0:
                    print(r.stdout, r.stderr)
                    self.integrity = "FAILED"
                    self.check("render", "FAIL", "renderer exited with status %d (run %s)" % (r.returncode, label))
                    return self.finish(FAIL, "renderer crashed, failed or timed out", "NOT VERIFIED")
                outs.append(out)
            out_a, out_b = outs
            names_a, names_b = sorted(os.listdir(out_a)), sorted(os.listdir(out_b))
            if names_a != sorted(expected) or names_b != sorted(expected):
                self.integrity = "FAILED"
                self.check("render", "FAIL", "rendered file set %s does not match manifest %s" % (names_a, sorted(expected)))
                return self.finish(FAIL, "unexpected renderer output", "NOT VERIFIED")
            self.check("render", "ok", "%d frames per run" % len(names_a))

            hard_failures = []
            # structure of every rendered PNG: valid PNG, expected width/height, 8-bit RGBA.
            # A different OS or font version never excuses structurally invalid output.
            structural = []
            for name in names_a:
                with open(os.path.join(out_a, name), "rb") as f:
                    structural += self.header_problems("rendered " + name, f.read(), expected[name])
            if structural:
                hard_failures.append("render structure")
                self.check("structure", "FAIL", "; ".join(structural))
            else:
                self.check("structure", "ok", "all %d rendered PNGs have the expected size and 8-bit RGBA format" % len(names_a))

            nondet = [n for n in names_a if sha256_file(os.path.join(out_a, n)) != sha256_file(os.path.join(out_b, n))]
            if nondet:
                hard_failures.append("determinism")
                self.check("determinism", "FAIL", "two runs differ for %s" % ", ".join(nondet))
            else:
                self.check("determinism", "ok", "two runs identical for all %d frames" % len(names_a))

            # exact comparison with the goldens: always executed and reported
            mismatched = 0
            sanity_worst = 0.0
            for name in names_a:
                fr = expected[name]
                actual = os.path.join(out_a, name)
                golden = os.path.join(self.golden_dir, name)
                entry = {"source_frame": fr["source_frame"], "covers": fr["covers"], "png": name}
                tag = "frame %-4d (%s)" % (fr["source_frame"], fr["covers"])
                if sha256_file(actual) == fr["sha256"]:
                    entry["byte_identical"] = True
                    print("%s: identical" % tag)
                else:
                    mismatched += 1
                    entry["byte_identical"] = False
                    try:
                        with open(golden, "rb") as f:
                            a = pngcmp.read_png_rgba(f.read())
                        with open(actual, "rb") as f:
                            b = pngcmp.read_png_rgba(f.read())
                    except pngcmp.PngError as e:
                        hard_failures.append("undecodable PNG")
                        entry["error"] = str(e)
                        print("%s: DIFFERS and cannot be decoded: %s" % (tag, e))
                        self.report["frames"].append(entry)
                        continue
                    d = pngcmp.compare_rgba(a, b)
                    entry["diff"] = d
                    if d["equal"]:
                        print("%s: bytes differ, decoded RGBA identical (PNG encoding/metadata only)" % tag)
                    else:
                        entry["sanity"] = pngcmp.visual_sanity_metrics(a, b, d)
                        sanity_worst = max(sanity_worst, entry["sanity"]["ink_diff_fraction"])
                        print("%s: DIFFERS %s | ink_diff_fraction %.6f" % (tag, json.dumps(d, sort_keys=True), entry["sanity"]["ink_diff_fraction"]))
                self.report["frames"].append(entry)

            if self.args.keep_output:
                shutil.copytree(out_a, self.args.keep_output)
                print("Rendered PNGs kept in %s" % self.args.keep_output)

        total_px = sum((fr.get("diff") or {}).get("differing_pixels", 0) for fr in self.report["frames"])
        self.report["summary"] = {"frames": len(expected), "mismatched_frames": mismatched, "differing_pixels": total_px,
                                  "worst_ink_diff_fraction": sanity_worst, "sanity_threshold": SANITY_MAX_INK_DIFF_FRACTION}
        self.integrity = "FAILED" if hard_failures else "OK"

        if mismatched == 0:
            self.check("golden-compare", "ok", "all %d frames byte-identical to the goldens" % len(expected))
        elif env_match:
            self.check("golden-compare", "FAIL", "%d of %d frames differ (%d px) on the recorded environment" % (mismatched, len(expected), total_px))
        else:
            self.check("golden-compare", "NOT VERIFIED", "%d of %d frames differ (%d px); exact equivalence not established on a different environment" % (mismatched, len(expected), total_px))

        if mismatched == 0:
            self.sanity = "NOT APPLICABLE (frames are byte-identical)"
        elif env_match:
            self.sanity = "NOT APPLICABLE (environment matches; any difference is a FAIL)"
        elif hard_failures:
            self.sanity = "NOT EVALUATED (render integrity failed)"
        elif sanity_worst > SANITY_MAX_INK_DIFF_FRACTION:
            self.sanity = "FAILED (worst ink_diff_fraction %.4f > %.4f)" % (sanity_worst, SANITY_MAX_INK_DIFF_FRACTION)
        else:
            self.sanity = ("PASSED (worst ink_diff_fraction %.6f <= %.4f; gross-defect screen only, NOT pixel equivalence)"
                           % (sanity_worst, SANITY_MAX_INK_DIFF_FRACTION))
        if mismatched and not env_match and not hard_failures:
            self.check("sanity", "FAIL" if sanity_worst > SANITY_MAX_INK_DIFF_FRACTION else "ok", self.sanity)

        if hard_failures:
            return self.finish(FAIL, "render integrity failed: %s" % ", ".join(sorted(set(hard_failures))), "NOT VERIFIED")
        if mismatched == 0:
            if not env_match:
                self.report["notes"].append("Environment differs from the recorded one, but every frame was byte-identical in this run.")
                print("NOTE: environment differs from the recorded one, but every frame was byte-identical in this run.")
            return self.finish(PASS, "%d frames rendered twice, deterministic, byte-identical to the goldens" % len(expected), "VERIFIED")
        if env_match:
            return self.finish(FAIL, "%d frame(s) differ from the goldens on the recorded environment" % mismatched, "FAILED")
        if sanity_worst > SANITY_MAX_INK_DIFF_FRACTION:
            return self.finish(FAIL, "cross-environment visual sanity failed: output differs grossly from the goldens (worst ink_diff_fraction %.4f)" % sanity_worst, "NOT VERIFIED")
        return self.finish(NOT_VERIFIED, "%d frame(s) differ from the goldens (%d px) and the environment differs from the recorded one" % (mismatched, total_px), "NOT VERIFIED")


class _Parser(argparse.ArgumentParser):
    def error(self, message):  # argparse's default exit status 2 would collide with UNSUPPORTED
        sys.stderr.write("usage error: %s\n" % message)
        sys.exit(USAGE)


def main():
    ap = _Parser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep-output", metavar="DIR", help="copy the rendered PNGs of run A into DIR; DIR must not exist (usage error otherwise)")
    ap.add_argument("--report-dir", metavar="DIR", help="write report.json and report.md into DIR (created if needed; existing report files are overwritten)")
    ap.add_argument("--print-environment", action="store_true", help="print the current environment as JSON in the manifest format and exit")
    ap.add_argument("--fixture-dir", default=FIXTURE_DIR, help=argparse.SUPPRESS)
    ap.add_argument("--renderer-src", help=argparse.SUPPRESS)  # test hook; requires %s=1
    args = ap.parse_args()
    if args.renderer_src and os.environ.get(HOOK_ENV) != "1":
        ap.error("--renderer-src is a test hook and requires %s=1" % HOOK_ENV)
    if args.keep_output and os.path.exists(args.keep_output):
        ap.error("--keep-output %s already exists" % args.keep_output)
    if args.print_environment:
        return print_environment()
    return Runner(args).main()


def print_environment():
    swiftc = shutil.which("swiftc")
    env = {"macos_version": platform.mac_ver()[0], "macos_build": mac_build(), "arch": platform.machine(),
           "swift_version": swift_first_line(swiftc) if swiftc else "", "fonts": {}}
    if swiftc and platform.system() == "Darwin":
        with tempfile.TemporaryDirectory(prefix="framekit-env-") as tmp:
            binp = os.path.join(tmp, "check_fonts")
            if run([swiftc, "-O", FONT_CHECK_SRC, "-o", binp]).returncode != 0:
                sys.stderr.write("could not compile check_fonts.swift\n")
                return FAIL
            with open(os.path.join(FIXTURE_DIR, "manifest.json")) as f:
                names = json.load(f)["fonts_required"]
            fv = verify_fonts(binp, names)
            if fv["status"] == FONT_FAILED:
                sys.stderr.write("font verification failed: %s\n" % fv["detail"])
                return FAIL
            for info in fv["infos"]:
                env["fonts"][info["requested"]] = {"version": info["version"], "file": info["file"]}
    print(json.dumps(env, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
