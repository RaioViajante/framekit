# Development

## Requirements

Same as [getting-started.md](getting-started.md): macOS (the goldens were captured on arm64), Xcode
Command Line Tools with `swiftc` (captured with Apple Swift 6.4), Python 3 with the standard library
only (run it with `-I`), and the system fonts Avenir Next and Palatino.

## Running the tests

```sh
python3 -I -W error -m unittest discover -s captions/tests    # everything: unit + scenario + documentation links
python3 -I captions/tests/run_reference_regression.py         # the reference regression itself
```

Scenario tests need macOS and `swiftc` and are skipped elsewhere. Skipped is not passed: a CI run on an
unsupported machine says so (see [regression-testing.md](regression-testing.md)).

## Layout

```
captions/reference/                 frozen renderer: render_caps.swift (+ README with its known quirks)
captions/tests/
  run_reference_regression.py       the runner (policy, exit codes, reports)
  check_fonts.swift                 reports whether a PostScript font name resolves exactly
  pngcmp.py                         PNG reader and comparison, standard library only
  test_pngcmp.py                    PNG reader, malformed input, visible/premultiplied comparison
  test_font_verification.py         every font-verification outcome, with fake helpers
  test_runner_scenarios.py          the runner end to end
  test_docs_links.py                relative links, anchors and README commands
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
- **Documentation** uses relative links. `test_docs_links.py` fails when a link, anchor or README
  command target does not exist.
- **Commits** follow Conventional Commits and go through a pull request.
