#!/usr/bin/env python3
"""Regression test for the frozen EP001 reference caption renderer.

Compiles captions/reference/render_caps.swift, renders the fixture frames twice into isolated
temporary directories and compares them with the committed golden PNGs.

The golden PNGs are only meaningful on the environment they were captured on (macOS build, Swift
toolchain, arch and font versions, recorded in manifest.json). The policy is therefore:

  environment MATCHES the recorded one -> an exact pixel mismatch is a FAIL
  environment DIFFERS                  -> the pixel comparison is still executed and reported, but a
                                          mismatch is NOT VERIFIED (exact golden equivalence was not
                                          established), never a PASS

Everything else is a hard failure in any environment: fixture/manifest inconsistencies, a compile
error, a renderer crash, a wrong output file set, or nondeterministic output across repeated runs.

Exit status (also printed in the final RESULT line):
  0  PASS          every frame was byte-identical to its golden (exact equivalence established;
                   a note is printed when the environment differed from the recorded one)
  1  FAIL          see above
  2  UNSUPPORTED  the environment cannot run the test (not macOS, no swiftc, fonts missing).
                   Nothing was compared. This is NOT a pass.
  3  NOT VERIFIED  everything except exact golden equivalence passed, but frames differ from the
                   goldens and the environment differs from the recorded one. Exact equivalence is
                   NOT VERIFIED; see the pixel-difference report. This is NOT a pass.

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

PASS, FAIL, UNSUPPORTED, NOT_VERIFIED = 0, 1, 2, 3
LABELS = {
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


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def mac_build():
    r = run(["sw_vers", "-buildVersion"])
    return r.stdout.strip() if r.returncode == 0 else ""


def swift_first_line(swiftc):
    return run([swiftc, "--version"]).stdout.strip().splitlines()[0]


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
        self.renderer_src = os.path.abspath(args.renderer_src) if args.renderer_src else RENDERER_SRC
        self.report = {"checks": {}, "frames": [], "notes": []}

    # -- reporting ------------------------------------------------------------------------------
    def check(self, name, status, detail=""):
        self.report["checks"][name] = {"status": status, "detail": detail}
        print("%-14s %s%s" % (name.upper() + ":", status, (" - " + detail) if detail else ""))

    def finish(self, code, message, equivalence):
        self.report["exact_golden_equivalence"] = equivalence
        self.report["result"] = {"code": code, "label": LABELS[code], "message": message}
        print("\nEXACT_GOLDEN_EQUIVALENCE: %s" % equivalence)
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
                 "**Exact golden equivalence: %s**" % equivalence, "", message, "",
                 "| Check | Status | Detail |", "|---|---|---|"]
        for name, c in self.report["checks"].items():
            lines.append("| %s | %s | %s |" % (name, c["status"], c["detail"].replace("|", "/")))
        if self.report["frames"]:
            lines += ["", "| Frame | Covers | Exact | Differing px | Max channel diff |", "|---|---|---|---|---|"]
            for fr in self.report["frames"]:
                d = fr.get("diff") or {}
                lines.append("| %s | %s | %s | %s | %s |" % (
                    fr["source_frame"], fr["covers"], "yes" if fr["byte_identical"] else "NO",
                    d.get("differing_pixels", 0), d.get("max_channel_diff", 0)))
        for n in self.report["notes"]:
            lines += ["", "> " + n]
        return "\n".join(lines) + "\n"

    # -- main flow ------------------------------------------------------------------------------
    def main(self):
        rec = self.manifest["environment"]
        print("Environment: %s %s (%s)" % (platform.system(), platform.mac_ver()[0] or platform.release(), platform.machine()))
        if self.args.renderer_src:
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
        if not self.args.renderer_src and sha256_file(self.renderer_src) != self.manifest["renderer"]["sha256"]:
            problems.append("renderer source differs from manifest SHA-256")
        if sha256_file(self.frames_json) != self.manifest["frames_json"]["sha256"]:
            problems.append("frames.json differs from manifest SHA-256")
        expected = {fr["png"]: fr for fr in self.manifest["frames"]}
        present = sorted(n for n in os.listdir(self.golden_dir) if n.endswith(".png"))
        if present != sorted(expected):
            problems.append("golden file set %s does not match manifest %s" % (present, sorted(expected)))
        for name, fr in expected.items():
            p = os.path.join(self.golden_dir, name)
            if os.path.exists(p) and sha256_file(p) != fr["sha256"]:
                problems.append("golden %s differs from manifest SHA-256" % name)
        if problems:
            self.check("integrity", "FAIL", "; ".join(problems))
            return self.finish(FAIL, "fixtures are inconsistent with manifest.json (goldens are never updated automatically)", "NOT VERIFIED")
        self.check("integrity", "ok", "renderer, frames.json and %d goldens match manifest.json" % len(expected))

        with tempfile.TemporaryDirectory(prefix="raio-caption-reg-") as tmp:
            # fonts: a missing font is an unsupported environment (CoreText would substitute)
            fonts_bin = os.path.join(tmp, "check_fonts")
            r = run([swiftc, "-O", FONT_CHECK_SRC, "-o", fonts_bin])
            if r.returncode != 0:
                print(r.stderr)
                self.check("fonts", "FAIL", "could not compile check_fonts.swift")
                return self.finish(FAIL, "could not compile check_fonts.swift", "NOT VERIFIED")
            r = run([fonts_bin] + self.manifest["fonts_required"])
            missing = []
            for line in r.stdout.strip().splitlines():
                info = json.loads(line)
                print("Font:        %-22s %s (version %s, file %s)" % (
                    info["requested"], "ok" if info["available"] else "MISSING -> resolved to " + info["resolved"], info["version"], info["file"]))
                current["fonts"][info["requested"]] = {"version": info["version"], "file": info["file"]}
                if not info["available"]:
                    missing.append(info["requested"])
            self.report["current_environment"] = current
            if missing:
                self.check("fonts", "UNSUPPORTED", "not available: %s" % ", ".join(missing))
                return self.finish(UNSUPPORTED, "required fonts are not available; CoreText would substitute and the comparison would be meaningless", "NOT EXECUTED")
            self.check("fonts", "ok", "all %d required fonts resolve exactly" % len(current["fonts"]))

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
                self.check("build", "FAIL", "reference renderer failed to compile")
                return self.finish(FAIL, "reference renderer failed to compile", "NOT VERIFIED")
            self.check("build", "ok")
            outs = []
            for label in ("A", "B"):
                out = os.path.join(tmp, "out_" + label)
                r = run([renderer_bin, self.frames_json, out])
                if r.returncode != 0:
                    print(r.stdout, r.stderr)
                    self.check("render", "FAIL", "renderer exited with status %d (run %s)" % (r.returncode, label))
                    return self.finish(FAIL, "renderer crashed or failed", "NOT VERIFIED")
                outs.append(out)
            out_a, out_b = outs
            names_a, names_b = sorted(os.listdir(out_a)), sorted(os.listdir(out_b))
            if names_a != sorted(expected) or names_b != sorted(expected):
                self.check("render", "FAIL", "rendered file set %s does not match manifest %s" % (names_a, sorted(expected)))
                return self.finish(FAIL, "unexpected renderer output", "NOT VERIFIED")
            self.check("render", "ok", "%d frames per run" % len(names_a))

            hard_failures = 0
            nondet = [n for n in names_a if sha256_file(os.path.join(out_a, n)) != sha256_file(os.path.join(out_b, n))]
            if nondet:
                hard_failures += 1
                self.check("determinism", "FAIL", "two runs differ for %s" % ", ".join(nondet))
            else:
                self.check("determinism", "ok", "two runs identical for all %d frames" % len(names_a))

            # exact comparison with the goldens: always executed and reported
            mismatched = 0
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
                    a = pngcmp.read_png_rgba(open(golden, "rb").read())
                    b = pngcmp.read_png_rgba(open(actual, "rb").read())
                    d = pngcmp.compare_rgba(a, b)
                    entry["diff"] = d
                    if d["equal"]:
                        print("%s: bytes differ, decoded RGBA identical (PNG encoding/metadata only)" % tag)
                    else:
                        print("%s: DIFFERS %s" % (tag, json.dumps(d, sort_keys=True)))
                self.report["frames"].append(entry)

            if self.args.keep_output:
                if os.path.exists(self.args.keep_output):
                    print("--keep-output: %s already exists, not overwriting" % self.args.keep_output)
                else:
                    shutil.copytree(out_a, self.args.keep_output)
                    print("Rendered PNGs kept in %s" % self.args.keep_output)

        total_px = sum((fr.get("diff") or {}).get("differing_pixels", 0) for fr in self.report["frames"])
        self.report["summary"] = {"frames": len(expected), "mismatched_frames": mismatched, "differing_pixels": total_px}
        if mismatched == 0:
            self.check("golden-compare", "ok", "all %d frames byte-identical to the goldens" % len(expected))
        elif env_match:
            self.check("golden-compare", "FAIL", "%d of %d frames differ (%d px) on the recorded environment" % (mismatched, len(expected), total_px))
        else:
            self.check("golden-compare", "NOT VERIFIED", "%d of %d frames differ (%d px); informational on a different environment" % (mismatched, len(expected), total_px))

        if hard_failures:
            return self.finish(FAIL, "nondeterministic rendering", "NOT VERIFIED")
        if mismatched == 0:
            if not env_match:
                self.report["notes"].append("Environment differs from the recorded one, but every frame was byte-identical in this run.")
                print("NOTE: environment differs from the recorded one, but every frame was byte-identical in this run.")
            return self.finish(PASS, "%d frames rendered twice, deterministic, byte-identical to the goldens" % len(expected), "VERIFIED")
        if env_match:
            return self.finish(FAIL, "%d frame(s) differ from the goldens on the recorded environment" % mismatched, "FAILED")
        return self.finish(NOT_VERIFIED, "%d frame(s) differ from the goldens (%d px) and the environment differs from the recorded one" % (mismatched, total_px), "NOT VERIFIED")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep-output", metavar="DIR", help="copy the rendered PNGs of run A into DIR (must not exist)")
    ap.add_argument("--report-dir", metavar="DIR", help="write report.json and report.md into DIR")
    ap.add_argument("--print-environment", action="store_true", help="print the current environment as JSON in the manifest format and exit")
    ap.add_argument("--fixture-dir", default=FIXTURE_DIR, help=argparse.SUPPRESS)
    ap.add_argument("--renderer-src", help=argparse.SUPPRESS)  # test hook for the scenario tests only
    args = ap.parse_args()
    if args.print_environment:
        return print_environment()
    return Runner(args).main()


def print_environment():
    swiftc = shutil.which("swiftc")
    env = {"macos_version": platform.mac_ver()[0], "macos_build": mac_build(), "arch": platform.machine(),
           "swift_version": swift_first_line(swiftc) if swiftc else "", "fonts": {}}
    if swiftc and platform.system() == "Darwin":
        with tempfile.TemporaryDirectory(prefix="raio-env-") as tmp:
            binp = os.path.join(tmp, "check_fonts")
            if run([swiftc, "-O", FONT_CHECK_SRC, "-o", binp]).returncode == 0:
                names = json.load(open(os.path.join(FIXTURE_DIR, "manifest.json")))["fonts_required"]
                for line in run([binp] + names).stdout.strip().splitlines():
                    info = json.loads(line)
                    env["fonts"][info["requested"]] = {"version": info["version"], "file": info["file"]}
    print(json.dumps(env, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
