# Development (FrameKit)

## Requirements

- macOS (CoreText is required); the goldens were captured on arm64.
- Xcode Command Line Tools providing `swiftc` (captured with Apple Swift 6.4).
- Python 3, standard library only. Run it with `-I`.
- Fonts `AvenirNext-Medium`, `AvenirNext-DemiBold` and `Palatino-Italic`, as provided by macOS. They
  are not redistributed here.

## Tests

```sh
python3 -I -m unittest discover -s captions/tests       # unit + scenario tests (scenarios need macOS)
python3 -I captions/tests/run_reference_regression.py   # reference renderer vs goldens
```

`run_reference_regression.py` works in an isolated temporary directory and never writes to the
repository. It:

1. checks the platform and `swiftc`, and verifies the fonts (see below);
2. checks that renderer, `frames.json` and every golden match `manifest.json` (SHA-256, size, 8-bit RGBA);
3. compares the environment fingerprint with the manifest (see below);
4. compiles `captions/reference/render_caps.swift`, renders the nine frames twice and checks that every
   output is a valid 8-bit RGBA PNG of the expected width and height and that both runs are identical;
5. compares each frame with its golden, byte equality first and a decoded-pixel report otherwise.

Options: `--keep-output DIR` keeps the PNGs of the first run (DIR must **not** exist; otherwise usage
error 64 and nothing runs). `--report-dir DIR` writes `report.json` and `report.md` (DIR is created if
needed, existing report files are overwritten). `--print-environment` prints the current fingerprint.

### Font verification

CoreText silently substitutes unknown fonts, so a small Swift helper (`check_fonts.swift`) reports
whether each required PostScript name resolves to itself. The runner never treats a missing result as
success:

| Outcome | Meaning | Result |
|---|---|---|
| fonts verified | the helper ran, reported exactly the required fonts (no more, no fewer, no duplicates) and all resolve | continue |
| unsupported | the helper ran correctly and reports fonts that do not resolve exactly | exit 2 (`UNSUPPORTED`) |
| verification failed | empty or malformed output, wrong entry count, output contradicting the helper's exit status, crash, timeout, nonzero status other than 1, missing binary, or an empty/duplicated font list in the manifest | exit 1 (`FAIL`) |

### Environment fingerprint

macOS version **and build**, architecture, the first line of `swiftc --version`, and for each required
font the version string and file name reported by CoreText. Matching macOS alone is not enough.
Limits: the font file is identified by name and version string, not by content hash or location, and
the CPU model is not recorded.

### Three separate results

| Line | Values |
|---|---|
| `EXACT_GOLDEN_EQUIVALENCE` | `VERIFIED` (every frame byte-identical), `FAILED` (environment matches, a frame differs), `NOT VERIFIED`, `NOT EXECUTED`, or `NOT APPLICABLE (TEST HOOK…)` |
| `RENDER_INTEGRITY` | `OK`, `FAILED` or `NOT EVALUATED`: fixtures vs manifest, compile, render, output files, PNG structure, determinism |
| `CROSS_ENV_VISUAL_SANITY` | `PASSED`, `FAILED`, `NOT APPLICABLE` or `NOT EVALUATED`: a gross-defect screen, only when the environment differs and frames differ. **`PASSED` is not pixel equivalence** |

### Exit codes

| Code | RESULT | When |
|---|---|---|
| 0 | `PASS` | Every frame was byte-identical to its golden (a note is printed if the environment differed) |
| 1 | `FAIL` | Environment matches and a frame differs; **or**, in any environment: fixtures disagree with the manifest, a golden or rendered PNG is not a valid 8-bit RGBA PNG of the expected width/height, compile error, renderer crash or timeout, wrong output files, nondeterministic output, or the sanity screen failed |
| 2 | `UNSUPPORTED` | Not macOS, no `swiftc`, or a required font is missing. Nothing was compared |
| 3 | `NOT VERIFIED` | Frames differ from the goldens **and** the environment differs, render integrity is OK and the sanity screen passed. Exact equivalence is not established |
| 64 | usage error | Invalid options (for example `--keep-output` on an existing path). Nothing ran |

A different macOS, Swift or font version never turns structurally invalid output (wrong width/height
or format), a crash, a compile error or nondeterminism into `NOT VERIFIED`: those are `FAIL`.

### Cross-environment visual sanity

Used only when the environment differs and frames differ. For each differing frame:
`ink_diff_fraction = visible differing pixels / max(ink pixels in golden, ink pixels in output, 1)`, with
ink meaning alpha > 0 and *visible* meaning that the premultiplied RGBA values differ (RGB under alpha 0
is invisible and is ignored; at low alpha its contribution is scaled down). It must be **≤ 0.01** (1%). No tolerance is applied to exact equivalence.

Calibration (measured, not chosen to make CI pass):

| Output vs goldens | Worst ink_diff_fraction (nine frames) |
|---|---|
| Real GitHub-hosted run: macOS 26.6.2 vs goldens from macOS 27.0.1 (27 px, max 2/255) | **0.000381** |
| Text shifted 1 px down | 0.855 (min over frames 0.627) |
| Text shifted 1 px right | 0.723 (min 0.495) |
| Text shifted 3, 6, 20, 200 px | 0.98, 1.08, 1.42, 2.00 |
| Caption not drawn | 1.00 |
| Font replaced by Helvetica, text 5% larger, opacity ×0.9, no outline | 0.96, 0.94, 0.93, 1.00 |

The metric counts visible differences only. Exact equivalence is a separate check on the stored
bytes and is unaffected: a golden whose alpha-0 pixels carry stray RGB fails exact comparison but not
the sanity screen. Switching from raw to visible differences was revalidated on all cases above and
the values are unchanged to six decimals (the renderer writes zeros under alpha 0).

The threshold is about 26× above the largest real cross-environment variation and about 49× below
the mildest degradation tried.

Limitations: calibrated on a single environment pair and nine frames. It cannot detect defects that
change under 1% of the ink pixels (for example one small glyph or a few pixels), so it is not a
substitute for exact comparison on a matching environment. A genuinely different rasterizer (new OS
hinting, new font version) may exceed the threshold and fail; that is deliberate: it needs a human
decision and, if accepted, a dedicated PR re-baselining the goldens on a new environment.

### Test hook

`--renderer-src FILE` exists only for the scenario tests. It is refused (usage error 64) unless
`FRAMEKIT_CAPTION_TEST_HOOK=1` is set, and when active the output says `TEST HOOK`, the equivalence line
reads `NOT APPLICABLE (TEST HOOK…)` and can never be `VERIFIED`.

### Scenario tests

`test_runner_scenarios.py` runs the runner end to end with goldens rendered on the local machine (so it
does not depend on the committed goldens or on the OS version) and covers: exact PASS; exact FAIL;
environment mismatch with the measured 27-pixel variation (NOT VERIFIED, sanity PASSED); environment
mismatch with identical frames; wrong dimensions; blank caption; displaced content (1, 6 and 200 px);
blank caption on a matching environment; goldens with wrong format, wrong size, truncated or garbage
content; missing font; missing `swiftc`; compile failure; renderer crash; nondeterministic renderer;
golden changed without the manifest; invisible RGB under alpha 0 (exact FAIL, or NOT VERIFIED with
sanity PASSED on a different environment); an empty required-font list; test-hook opt-in;
`--keep-output` handling. `test_font_verification.py` covers every font-verification outcome with fake
helpers, `test_pngcmp.py` the PNG reader and the visible/premultiplied comparison.

## Continuous integration and its limitations

- The committed goldens originate from **macOS 27.0.1, Swift 6.4** and the font versions recorded in
  `manifest.json`.
- GitHub-hosted `macos-latest` currently runs a **different environment** (macOS 26.6.2, Swift 6.3.3,
  different font versions).
- The hosted CI therefore validates fixture integrity, font verification, compilation, determinism,
  PNG structure, the unit and scenario tests and the cross-environment sanity screen.
- Exact equivalence to the committed goldens stays **NOT VERIFIED** in hosted CI whenever the output
  differs across environments (exit code 3). The job passes with a warning annotation, the step
  summary and artifacts (rendered frames, `report.json`, `report.md`, log); it is not a pixel-equivalence pass.
- A compatible environment (same macOS build, arch, Swift and font versions) is required to verify the
  original goldens exactly; there, any difference fails.
- Exit codes 1, 2 and 64 fail the job.

## Golden files

`captions/tests/fixtures/ep001/` holds `frames.json` (nine frame objects), `golden/*.png` and
`manifest.json` (SHA-256, dimensions, image format, source frame, environment, font requirements and
provenance).

- Goldens are **never updated automatically**: no test or script rewrites them.
- No tolerance is applied to exact equivalence.
- Re-baselining on a new environment is a dedicated PR that replaces the goldens and the manifest's
  `environment` together, with the runner's mismatch report attached.
- The goldens prove only that **this reference renderer** is stable. No new renderer exists yet, so no
  claim of pixel equivalence for one can be made.

## Licensing, provenance and privacy

Terms and classification: [../NOTICE.md](../NOTICE.md); provenance:
[PROVENANCE-AND-LICENSING.md](PROVENANCE-AND-LICENSING.md). The fixtures contain caption text and style
parameters from EP001 only: no audio, video, local paths or personal data. The PNGs carry only `sRGB`
and `eXIf` (pixel dimensions) metadata besides the image data. The original EP001 source files were
read, never modified.
