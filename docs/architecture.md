# Architecture

FrameKit is at an early stage. This page describes what exists and the boundaries that were decided for
what comes next. Anything marked *planned* is not implemented.

## What exists

```
frames.json ──► render_caps (Swift, CoreText/CoreGraphics) ──► 1080×1916 RGBA PNG per frame
                       │
                       └── frozen: captions/reference/render_caps.swift

                  run_reference_regression.py
   fixtures ──► verify fonts ► verify fixtures ► build ► render ×2 ► structure + determinism ► compare
   (frames.json,                                                                            │
    golden PNGs,                                                          EXACT_GOLDEN_EQUIVALENCE
    manifest.json)                                                        RENDER_INTEGRITY
                                                                          CROSS_ENV_VISUAL_SANITY
```

- **Reference renderer** (`captions/reference/`): a Swift program that reads a frames file and writes
  one transparent PNG per frame. It is frozen exactly as it was used by the source production. Its
  input contract and quirks: [caption-rendering.md](caption-rendering.md).
- **Regression runner** (`captions/tests/run_reference_regression.py`): renders nine frames and judges
  them against golden PNGs, reporting three separate verdicts. Policy and exit codes:
  [regression-testing.md](regression-testing.md).
- **PNG tooling** (`captions/tests/pngcmp.py`): a standard-library PNG reader and comparison, so the
  tests have no dependencies.
- **Fixtures** (`captions/tests/fixtures/ep001/`): the frames, golden images and a manifest recording
  hashes, dimensions, environment, fonts and provenance.
- **CI** (`.github/workflows/caption-regression.yml`): runs the tests and the runner on macOS and keeps a
  difference of environment visible. See [ci.md](ci.md).
- **Caption configuration** (`Sources/FrameKitCaptions/`, Swift package at the root): the versioned
  preset and caption input documents, their validation, preset selection by id, the font dependency check
  and the first preset, `captions/presets/kinetic-minimal.json`. Contract:
  [caption-configuration.md](caption-configuration.md).
- **Rendering engine** (`CaptionRenderer` in the same library): cue windows, a resolved description of
  each frame, and drawing with the same CoreText and CoreGraphics calls as the frozen renderer, into
  transparent RGBA PNG frames. It is checked against the frozen renderer and the goldens. Library only,
  no command yet: [caption-rendering.md](caption-rendering.md#the-rendering-engine).

```
captions/presets/<id>.json ─┐
                            ├─► FrameKitCaptions: validate, check fonts ─► cue windows ─► CaptionFrame ─► PNG per frame
caption input (.json) ──────┘                                              (timing)       (fades, emphasis)  (CoreText)
```

## Decisions that shape what comes next

The decisions behind the Swift package, the validation approach and the module boundaries, with their
alternatives and open questions: [decision record 0001](decisions/0001-caption-configuration.md).

- **Rendering stack:** Swift with CoreText. No cross-platform renderer in the first version.
- **Verification before features:** a new renderer is compared with the frozen baseline first; equality
  is exact, and a result obtained on a different environment is never reported as equivalence.
- **Presets are data:** caption appearance is a versioned JSON preset, the captions a separate input
  document, and paths are always explicit (see [caption-configuration.md](caption-configuration.md)).
  Creative choices such as story, scenes, duration, sound and pacing stay with whoever uses the toolkit.
- **One source of truth:** presets, schemas and rendering code live in this repository.
- **Licensing boundary:** code and documentation are MIT; test fixtures and artwork are not. See
  [licensing-and-provenance.md](licensing-and-provenance.md).

## What does not exist yet

The episode document with per-video overrides, a caption CLI and a release. The
[roadmap in the README](../README.md#roadmap) lists the order of work.
