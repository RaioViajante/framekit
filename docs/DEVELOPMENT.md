# Development

## Requirements

- macOS (CoreText is required), arm64 was used to capture the goldens.
- Xcode Command Line Tools providing `swiftc` (captured with Apple Swift 6.4).
- Python 3, standard library only. Run it with `-I`.
- System fonts `AvenirNext-Medium`, `AvenirNext-DemiBold` and `Palatino-Italic`. They ship with
  macOS and are not redistributed here.

## Tests

```sh
python3 -I -m unittest discover -s captions/tests       # PNG comparison unit tests, portable
python3 -I captions/tests/run_reference_regression.py   # reference renderer vs goldens
```

`run_reference_regression.py` works in an isolated temporary directory and never writes to the
repository. It:

1. checks the environment (macOS, `swiftc`, fonts resolved *exactly* by CoreText);
2. checks that renderer, `frames.json` and every golden match `manifest.json`;
3. compiles `captions/reference/render_caps.swift`;
4. renders the nine frames twice and checks both runs are byte-identical;
5. compares each frame with its golden: byte equality first; if different, decodes both and reports
   differing pixel count, maximum channel difference, a histogram and the bounding box.

`--keep-output DIR` keeps the rendered PNGs of the first run for inspection (DIR must not exist).

### Result policy

The goldens are only meaningful on the environment they were captured on. The runner compares the
current macOS version **and build**, architecture, Swift version and the **version and file of each
required font** against `manifest.json`; matching macOS alone is not enough.

| Code | RESULT | When |
|---|---|---|
| 0 | `PASS` | Every frame was byte-identical to its golden (exact equivalence established). A note is printed if the environment differed |
| 1 | `FAIL` | Environment matches and a frame differs; **or**, in any environment: fixtures disagree with the manifest, compile error, renderer crash, wrong output files, or nondeterministic output |
| 2 | `UNSUPPORTED` | Not macOS, no `swiftc`, or a required font is missing. Nothing was compared |
| 3 | `NOT VERIFIED` | Everything else passed, but frames differ from the goldens **and** the environment differs. Exact equivalence is not established; read the pixel-difference report |

The comparison is never skipped: on a different environment it still runs and is reported
(`EXACT_GOLDEN_EQUIVALENCE: VERIFIED | FAILED | NOT VERIFIED | NOT EXECUTED`). Exit 3 is not a pass.

CI: exit 0 passes; exit 3 passes the job but adds a warning annotation, a step summary and the
rendered frames/report as artifacts; exits 1 and 2 fail the job.

`--report-dir DIR` writes `report.json` and `report.md`; `--print-environment` prints the current
environment in the manifest format.

### Scenario tests

`test_runner_scenarios.py` exercises the runner end to end with goldens rendered on the local machine
(so it does not depend on the committed goldens): exact PASS, exact FAIL, environment mismatch,
environment mismatch with identical frames, missing font, missing `swiftc`, nondeterministic renderer,
renderer crash and fixture integrity failure.

## Golden files

`captions/tests/fixtures/ep001/` holds `frames.json` (nine frame objects), `golden/*.png` and
`manifest.json` (SHA-256, dimensions, source frame, macOS/Swift versions, font requirements and
provenance).

- Goldens are **never updated automatically**: no test or script rewrites them.
- A golden may change only in a dedicated PR that explains the cause (OS, Swift or font change, or a
  deliberate renderer change), shows the mismatch report from this runner, and updates
  `manifest.json` in the same commit.
- No tolerance is applied. A different environment is handled by the NOT VERIFIED policy above, not by
  loosening the comparison.
- If a new environment should become the reference, that is a dedicated PR replacing the goldens
  and the manifest's `environment` together, with the mismatch report attached.
- The goldens prove only that **this reference renderer** is stable. No new renderer exists yet, so
  no claim of pixel equivalence for one can be made.

## Provenance and privacy

Licensing scope: [PROVENANCE-AND-LICENSING.md](PROVENANCE-AND-LICENSING.md).

The fixtures contain caption text and style parameters from EP001 only: no audio, video, local paths
or personal data. The PNGs carry only `sRGB` and `eXIf` (pixel dimensions) metadata besides the image
data. The original EP001 source files were read, never modified.
