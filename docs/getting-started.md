# Getting started

FrameKit currently consists of a frozen reference caption renderer, the tests that guard it, the caption
configuration contract (presets and caption input, with validation), the rendering engine, and a first
command, `framekit captions render` ([render captions](#render-captions)).

## Prerequisites

- macOS. The renderer uses CoreText, so the visual checks do not run elsewhere.
- Xcode Command Line Tools, which provide `swiftc`. Check with `swiftc --version`. The Swift package
  tests use Swift Testing, which comes with Xcode; they are run with Swift 6.3.3 and 6.4, and 6.3.3 is
  the oldest known to work ([development](development.md)).
- Python 3. Only the standard library is used.
- The fonts Avenir Next (Medium, DemiBold) and Palatino Italic, which ship with macOS. They are not
  redistributed here. The runner verifies them before it renders anything.

## Clone and run

```sh
git clone https://github.com/RaioViajante/framekit.git
cd framekit
python3 -I -m unittest discover -s captions/tests
python3 -I captions/tests/run_reference_regression.py
swift test
```

The first command runs the unit and scenario tests (about a minute on macOS; the scenarios are skipped
where `swiftc` or macOS is missing). The second renders nine reference frames twice in a temporary
directory and compares them with the committed goldens. It never writes inside the repository. The third
runs the Swift package tests: the preset and caption input contracts and the `kinetic-minimal` preset
([caption-configuration.md](caption-configuration.md)).

## Reading the result

The runner ends with three separate lines and a `RESULT`:

```
EXACT_GOLDEN_EQUIVALENCE: VERIFIED
RENDER_INTEGRITY: OK
CROSS_ENV_VISUAL_SANITY: NOT APPLICABLE (frames are byte-identical)
RESULT: PASS - 9 frames rendered twice, deterministic, byte-identical to the goldens
```

That is the output on the machine the goldens were captured on. On a different macOS, Swift or font
version the frames may differ by a few pixels; the runner then reports `NOT VERIFIED` (exit code 3) and
says so explicitly instead of passing. The exit codes are `0` pass, `1` fail, `2` unsupported
environment, `3` not verified and `64` usage error. Everything else about the results, including why a
different environment can never produce a pass it has not earned:
[regression-testing.md](regression-testing.md).

## Useful options

```sh
python3 -I captions/tests/run_reference_regression.py --report-dir out/report   # report.json + report.md
python3 -I captions/tests/run_reference_regression.py --keep-output out/frames  # keep the rendered PNGs
python3 -I captions/tests/run_reference_regression.py --print-environment       # fingerprint of this machine
```

`--keep-output` requires that the directory does not exist yet.

## Render captions

```sh
swift build -c release
.build/release/framekit captions render --preset captions/presets/kinetic-minimal.json \
  --input captions/examples/overlapping-cues.input.json --out frames
```

`frames/` then holds one transparent PNG per video frame, `0000.png` to `0106.png`. Write your own caption
input (the [input contract](caption-configuration.md#input-contract)) with your words and their times,
and render it the same way. Options, output rules and exit statuses: [cli.md](cli.md).

## Next

[architecture.md](architecture.md) shows how the pieces fit, [development.md](development.md) explains the
test layout and how to change things safely.
