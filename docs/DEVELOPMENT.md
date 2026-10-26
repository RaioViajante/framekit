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

### Exit-code policy

| Code | RESULT | Meaning |
|---|---|---|
| 0 | `PASS` | The visual regression ran and every frame matched |
| 1 | `FAIL` | It ran and something differs, or fixtures disagree with the manifest |
| 2 | `UNSUPPORTED` | The environment cannot run it (not macOS, no `swiftc`, fonts missing). **Nothing was compared; this is not a pass** |

CI treats every non-zero code as a failure. The runner also prints a note when the macOS or Swift
version differs from the one recorded in the manifest; a mismatch is still reported as `FAIL`
because it can only be judged by a person.

## Golden files

`captions/tests/fixtures/ep001/` holds `frames.json` (nine frame objects), `golden/*.png` and
`manifest.json` (SHA-256, dimensions, source frame, macOS/Swift versions, font requirements and
provenance).

- Goldens are **never updated automatically**: no test or script rewrites them.
- A golden may change only in a dedicated PR that explains the cause (OS, Swift or font change, or a
  deliberate renderer change), shows the mismatch report from this runner, and updates
  `manifest.json` in the same commit.
- A tolerance (for example a maximum channel difference of 1/255) is not applied. If rasterization
  differences are justified one day, the decision, the affected pixels and their distribution must be
  recorded in that PR and in the manifest.
- The goldens prove only that **this reference renderer** is stable. No new renderer exists yet, so
  no claim of pixel equivalence for one can be made.

## Provenance and privacy

The fixtures contain caption text and style parameters from EP001 only: no audio, video, local paths
or personal data. The PNGs carry only `sRGB` and `eXIf` (pixel dimensions) metadata besides the image
data. The original EP001 source files were read, never modified.
