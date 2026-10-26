# Development

## Requirements

Same as [getting-started.md](getting-started.md): macOS (the goldens were captured on arm64), Xcode
Command Line Tools with `swiftc` (captured with Apple Swift 6.4), Python 3 with the standard library
only (run it with `-I`), and the system fonts Avenir Next and Palatino.

## Running the tests

```sh
python3 -I -W error -m unittest discover -s captions/tests    # everything: unit + scenario + documentation links
python3 -I captions/tests/run_reference_regression.py         # the reference regression itself
swift test                                                    # Swift package: caption configuration
```

The Swift package declares Swift tools 6.0, but its tests need more: exit tests
(`#expect(processExitsWith:)`) arrived in Swift 6.2, and the tests also record warning-severity issues.
They are run with Swift 6.4 (locally) and 6.3.3 (hosted CI); older toolchains are not tested, so 6.3.3
is the oldest known to work. `.build/` is ignored by Git.

The JSON Schema checks need `check-jsonschema` at the pinned version; without it they are skipped, which
is not a pass. With `FRAMEKIT_REQUIRE_SCHEMA_CHECKER=1`, as in CI, a missing checker fails instead:

```sh
python3 -m venv .venv && .venv/bin/pip install -r captions/schemas/requirements-dev.txt
FRAMEKIT_CHECK_JSONSCHEMA=.venv/bin/check-jsonschema python3 -I -W error -m unittest discover -s captions/tests
```

Scenario tests need macOS and `swiftc` and are skipped elsewhere. Skipped is not passed: a CI run on an
unsupported machine says so (see [regression-testing.md](regression-testing.md)).

## Layout

```
Package.swift                       Swift package (decisions: docs/decisions/0001-caption-configuration.md)
Sources/FrameKitCaptions/           preset and input documents, validation, preset selection, font check,
                                    rendering engine (CaptionRenderer, CaptionFrame)
Tests/FrameKitCaptionsTests/        contract, kinetic-minimal traceability, engine and reference-frame,
                                    hygiene and documentation tests
captions/presets/                   caption presets, one <preset_id>.json each
captions/schemas/                   JSON Schemas (v1), shared conformance cases, pinned checker version
captions/examples/                  caption input examples
captions/reference/                 frozen renderer: render_caps.swift (+ README with its known quirks)
captions/tests/
  run_reference_regression.py       the runner (policy, exit codes, reports)
  check_fonts.swift                 reports whether a PostScript font name resolves exactly
  pngcmp.py                         PNG reader and comparison, standard library only
  test_pngcmp.py                    PNG reader, malformed input, visible/premultiplied comparison
  test_font_verification.py         every font-verification outcome, with fake helpers
  test_runner_scenarios.py          the runner end to end
  test_docs_links.py                relative links, anchors and README commands
  test_schemas.py                   JSON Schemas: metaschema, shipped documents, shared-case verdicts
  fixtures/ep001/                   frames.json, golden/*.png, manifest.json, NOTICE.md
```

## What the scenario tests cover

`test_runner_scenarios.py` runs the runner end to end with goldens rendered on the local machine, so
it does not depend on the committed goldens or on the OS version:

- exact PASS; exact FAIL; environment mismatch with the measured 27-pixel variation (NOT VERIFIED,
  sanity PASSED); environment mismatch with identical frames;
- wrong dimensions; blank caption; displaced content (1, 6 and 200 px); blank caption on a matching
  environment;
- goldens with wrong format, wrong size, truncated or garbage content; golden changed without the
  manifest;
- invisible RGB under alpha 0 (exact FAIL, or NOT VERIFIED with sanity PASSED on a different
  environment);
- missing font; empty required-font list; missing `swiftc`; compile failure; renderer crash;
  nondeterministic renderer;
- test-hook opt-in; `--keep-output` handling.

`test_font_verification.py` uses fake helper programs so that crashes, timeouts, empty or malformed
output and contradictory statuses are exercised without a real font failure.

## The test hook

`--renderer-src FILE` lets a scenario test run the runner against a modified renderer source. It is
refused (usage error 64) unless `FRAMEKIT_CAPTION_TEST_HOOK=1` is set. When active, the output says
`TEST HOOK` and the equivalence line reads `NOT APPLICABLE (TEST HOOK…)`; it can never be `VERIFIED`.

## Changing things safely

- **The frozen renderer** (`captions/reference/render_caps.swift`) is not edited. Any change would
  invalidate the goldens and is a dedicated PR.
- **The goldens** are never rewritten by a test or script. Re-baselining on a new environment is a
  dedicated PR that replaces the goldens and the manifest's `environment` together, with the runner's
  report attached (see [regression-testing.md](regression-testing.md#golden-files)).
- **The sanity threshold** (`SANITY_MAX_INK_DIFF_FRACTION`) is not tuned to make a run pass. Its
  calibration is documented in [regression-testing.md](regression-testing.md#cross-environment-visual-sanity).
- **The caption contract** (preset and input fields, error codes) is documented in
  [caption-configuration.md](caption-configuration.md); the Swift tests fail when the tables and the
  code diverge. A new field is a new `schema_version`.
- **Documentation** uses relative links. `test_docs_links.py` fails when a link, anchor or README
  command target does not exist.
- **Commits** follow Conventional Commits and go through a pull request.
