#!/usr/bin/env python3
"""Regression test for the frozen EP001 reference caption renderer.

Compiles captions/reference/render_caps.swift, renders the fixture frames twice into isolated
temporary directories and compares them with the committed golden PNGs.

Exit status (also printed in the final RESULT line):
  0  PASS         pixel regression executed and every frame matched
  1  FAIL         pixel regression executed and something did not match (or a golden/fixture
                  does not match its manifest entry)
  2  UNSUPPORTED  the environment cannot run the test (not macOS, no swiftc, fonts missing).
                  Nothing was compared. This is NOT a pass.

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

PASS, FAIL, UNSUPPORTED = 0, 1, 2


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def finish(code, message):
    label = {PASS: "PASS", FAIL: "FAIL", UNSUPPORTED: "UNSUPPORTED (visual regression NOT executed)"}[code]
    print("\nRESULT: %s - %s" % (label, message))
    return code


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep-output", metavar="DIR", help="copy the rendered PNGs of run A into DIR (must not exist)")
    ap.add_argument("--fixture-dir", default=FIXTURE_DIR, help=argparse.SUPPRESS)
    args = ap.parse_args()

    fixture_dir = os.path.abspath(args.fixture_dir)
    with open(os.path.join(fixture_dir, "manifest.json")) as f:
        manifest = json.load(f)
    golden_dir = os.path.join(fixture_dir, "golden")
    frames_json = os.path.join(fixture_dir, "frames.json")

    # --- environment --------------------------------------------------------------------------
    print("Environment: %s %s (%s)" % (platform.system(), platform.mac_ver()[0] or platform.release(), platform.machine()))
    if platform.system() != "Darwin":
        return finish(UNSUPPORTED, "requires macOS (CoreText); running on %s" % platform.system())
    swiftc = shutil.which("swiftc")
    if not swiftc:
        return finish(UNSUPPORTED, "swiftc not found; install Xcode Command Line Tools")
    swift_version = run([swiftc, "--version"]).stdout.strip().replace("\n", " | ")
    print("Swift:       %s" % swift_version)
    rec = manifest["environment"]
    print("Recorded:    macOS %s (%s), %s" % (rec["macos_version"], rec["macos_build"], rec["swift_version"]))
    if platform.mac_ver()[0] != rec["macos_version"] or rec["swift_version"] not in swift_version:
        print("NOTE: environment differs from the one the goldens were captured on; "
              "any mismatch below may be environmental, but it is still reported as FAIL.")

    # --- fixture integrity (goldens must match the manifest) ------------------------------------
    problems = []
    if sha256_file(RENDERER_SRC) != manifest["renderer"]["sha256"]:
        problems.append("renderer source differs from manifest SHA-256")
    if sha256_file(frames_json) != manifest["frames_json"]["sha256"]:
        problems.append("frames.json differs from manifest SHA-256")
    expected = {fr["png"]: fr for fr in manifest["frames"]}
    present = sorted(n for n in os.listdir(golden_dir) if n.endswith(".png"))
    if present != sorted(expected):
        problems.append("golden file set %s does not match manifest %s" % (present, sorted(expected)))
    for name, fr in expected.items():
        p = os.path.join(golden_dir, name)
        if os.path.exists(p) and sha256_file(p) != fr["sha256"]:
            problems.append("golden %s differs from manifest SHA-256" % name)
    if problems:
        for p in problems:
            print("INTEGRITY: " + p)
        return finish(FAIL, "fixtures are inconsistent with manifest.json (goldens are never updated automatically)")

    with tempfile.TemporaryDirectory(prefix="raio-caption-reg-") as tmp:
        # --- fonts ------------------------------------------------------------------------------
        fonts_bin = os.path.join(tmp, "check_fonts")
        r = run([swiftc, "-O", FONT_CHECK_SRC, "-o", fonts_bin])
        if r.returncode != 0:
            print(r.stderr)
            return finish(FAIL, "could not compile check_fonts.swift")
        r = run([fonts_bin] + manifest["fonts_required"])
        for line in r.stdout.strip().splitlines():
            info = json.loads(line)
            print("Font:        %-22s %s (version %s)" % (info["requested"], "ok" if info["available"] else "MISSING -> resolved to " + info["resolved"], info["version"]))
        if r.returncode != 0:
            return finish(UNSUPPORTED, "required fonts are not available; CoreText would substitute and the comparison would be meaningless")

        # --- build renderer ---------------------------------------------------------------------
        renderer_bin = os.path.join(tmp, "render_caps")
        r = run([swiftc, "-O", RENDERER_SRC, "-o", renderer_bin])
        if r.returncode != 0 or not os.path.exists(renderer_bin):
            print(r.stderr)
            return finish(FAIL, "reference renderer failed to compile")

        # --- render twice -----------------------------------------------------------------------
        outs = []
        for label in ("A", "B"):
            out = os.path.join(tmp, "out_" + label)
            r = run([renderer_bin, frames_json, out])
            if r.returncode != 0:
                print(r.stdout, r.stderr)
                return finish(FAIL, "renderer exited with status %d (run %s)" % (r.returncode, label))
            outs.append(out)
        out_a, out_b = outs

        names_a = sorted(os.listdir(out_a))
        if names_a != sorted(expected):
            return finish(FAIL, "rendered file set %s does not match manifest %s" % (names_a, sorted(expected)))

        failures = 0

        # --- determinism ------------------------------------------------------------------------
        nondet = [n for n in names_a if sha256_file(os.path.join(out_a, n)) != sha256_file(os.path.join(out_b, n))]
        if nondet:
            failures += 1
            print("DETERMINISM: FAIL - two runs differ for %s" % ", ".join(nondet))
        else:
            print("DETERMINISM: ok - two runs produced identical files for all %d frames" % len(names_a))

        # --- compare with goldens ---------------------------------------------------------------
        for name in names_a:
            fr = expected[name]
            actual = os.path.join(out_a, name)
            golden = os.path.join(golden_dir, name)
            tag = "frame %-4d (%s)" % (fr["source_frame"], fr["covers"])
            if open(actual, "rb").read() == open(golden, "rb").read():
                print("%s: ok - byte-identical, sha256 %s" % (tag, fr["sha256"][:12]))
                continue
            failures += 1
            print("%s: MISMATCH - file bytes differ" % tag)
            a = pngcmp.read_png_rgba(open(golden, "rb").read())
            b = pngcmp.read_png_rgba(open(actual, "rb").read())
            d = pngcmp.compare_rgba(a, b)
            if d["equal"]:
                print("    decoded RGBA is identical; only PNG encoding/metadata differs (still reported as FAIL)")
            else:
                print("    " + json.dumps(d, sort_keys=True))
            # reported only; never auto-accepted, see docs/DEVELOPMENT.md

        if args.keep_output:
            if os.path.exists(args.keep_output):
                print("--keep-output: %s already exists, not overwriting" % args.keep_output)
            else:
                shutil.copytree(out_a, args.keep_output)
                print("Rendered PNGs kept in %s" % args.keep_output)

    if failures:
        return finish(FAIL, "%d check(s) failed" % failures)
    return finish(PASS, "%d frames rendered twice, deterministic, byte-identical to the goldens" % len(expected))


if __name__ == "__main__":
    sys.exit(main())
