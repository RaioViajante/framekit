# Getting started

FrameKit's first feature renders kinetic captions with the `kinetic-minimal` preset into transparent PNG
frames, from the terminal: `framekit captions render` ([render captions](#render-captions)). Around it are
the caption configuration contract (presets and caption input, with validation), the rendering engine, and
a frozen reference renderer with the tests that guard it.

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

1. **Build** the command: `swift build -c release`. The binary is `.build/release/framekit`.
2. **Choose a preset.** `captions/presets/kinetic-minimal.json` is the one that ships; it is passed by
   path.
3. **Write a caption input:** your words with their start and end in seconds, grouped into cues
   ([input contract](caption-configuration.md#input-contract)). Start from a copy of an example in
   `captions/examples/`. FrameKit does not transcribe or align speech: the times come from an external
   alignment tool or are set by hand.
4. **Render** into a directory that does not exist yet (or is empty):

   ```sh
   .build/release/framekit captions render --preset captions/presets/kinetic-minimal.json \
     --input captions/examples/overlapping-cues.input.json --out frames
   ```

   `frames/` then holds one transparent 1080 × 1916 RGBA PNG per video frame, `0000.png` to `0106.png`.
5. **Lay them over the video.** PNG `N` is frame `N` of the video, counted from its first frame, at the
   preset's frame rate (`canvas.fps`, 24 for `kinetic-minimal`; for another rate, use a preset with that
   `fps`). Import the folder as an image sequence at that rate and start it where the video starts: the
   input's times are seconds from the start of the video, and frame `N` shows the instant
   `(N + 0.5) / fps`. By default the sequence ends with the last caption; to cover the whole video, give
   its frame range, such as `--frames 0..254` for a video of 255 frames.

Options, output rules and exit statuses: [cli.md](cli.md).

## Next

[architecture.md](architecture.md) shows how the pieces fit, [development.md](development.md) explains the
test layout and how to change things safely.
