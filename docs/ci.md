# Continuous integration

One workflow, [`caption-regression`](../.github/workflows/caption-regression.yml), runs on every pull
request and on pushes to `main`, on GitHub-hosted `macos-latest`, with read-only repository permissions.

## What it does

1. Prints the environment (`sw_vers`, `swiftc --version`, the runner's environment fingerprint).
2. Runs all unit and scenario tests (`python3 -I -m unittest discover -s captions/tests -v`).
3. Runs the reference regression with `--keep-output` and `--report-dir`, keeps its log, appends the
   Markdown report to the job summary and maps the runner's exit code (see
   [regression-testing.md](regression-testing.md#exit-codes)):

| Exit | Job | Annotation |
|---|---|---|
| 0 | passes | none |
| 3 | **passes with a warning** | "Exact golden equivalence NOT VERIFIED": the environment differs from the goldens', frames differ, render integrity and the gross-defect screen passed. Not a pixel-equivalence pass |
| 2 | fails | "Unsupported environment" |
| 1, 64 and anything else | fails | "Regression failure" |

4. Uploads the rendered frames, `report.json`, `report.md` and the log as the artifact
   `caption-regression-<exit code>` (always, including on failure; `incomplete` if the step never ran).

## What hosted CI verifies, and what it cannot

- The committed goldens originate from **macOS 27.0.1, Swift 6.4** and the font versions recorded in
  `manifest.json`.
- GitHub-hosted `macos-latest` currently runs a **different environment** (macOS 26.6.2, Swift 6.3.3,
  different font versions).
- Hosted CI therefore validates fixture integrity, font verification, compilation, determinism, PNG
  structure, the unit and scenario tests and the cross-environment sanity screen.
- Exact equivalence to the committed goldens stays **NOT VERIFIED** whenever the output differs across
  environments. The green job with a warning is deliberate and is not a pixel-equivalence pass.
- Verifying the original goldens exactly requires a compatible environment (same macOS build,
  architecture, Swift and font versions). There, any difference fails.
- The scenario tests cover the matching-environment branch of the policy using goldens they render
  themselves, so the logic is exercised in CI even though the committed goldens are not compared exactly
  there.

## Known limitations

- Actions are pinned by tag (`checkout@v4`, `upload-artifact@v4`) and `macos-latest` floats. GitHub
  currently warns that these actions target Node 20.
- The Python interpreter exits with status 2 when the runner script path is wrong; the workflow would
  label that "Unsupported environment" (the job still fails).
- Exit code 64 cannot be provoked in the hosted job, only in the scenario tests.
