# 0001: Caption configuration foundation

Status: accepted for the first configuration increment. Issue
[#2](https://github.com/RaioViajante/framekit/issues/2). Recording these decisions in the same pull
request as the first configuration code was accepted as a one-time exception to #2's "no code" scope.

## Context

FrameKit has a frozen reference renderer, its goldens and a Python regression runner. To caption a new
video without the reference production, the caption look has to become data (a preset), the captions
themselves a separate document (the input), and both have to be validated before a renderer exists.
This record keeps only the decisions that shape that code. The approved constraints still hold: Swift and
CoreText first, the frozen reference untouched, exact regression kept.

## Decisions

**1. One Swift package at the repository root.** `Package.swift`, `Sources/FrameKitCaptions/` (library)
and `Tests/FrameKitCaptionsTests/`. Today the library holds only configuration; the rendering engine and
the `framekit` executable become targets of the same package
([#9](https://github.com/RaioViajante/framekit/issues/9),
[#10](https://github.com/RaioViajante/framekit/issues/10),
[#19](https://github.com/RaioViajante/framekit/issues/19)).
*Alternatives:* a package under `captions/` (rejected: the executable will be the whole toolkit's, and
the root is where SwiftPM tools look); a separate repository (rejected: presets, contract and renderer
have one source of truth).

**2. Toolchain.** `swift-tools-version: 6.0`, Swift 6 language mode, macOS 14 or later. Both the local
toolchain (Swift 6.4) and the hosted runner (Swift 6.3) satisfy it. The package does not touch the
regression runner's environment fingerprint; pixel results remain judged by that runner.
*Alternative:* pinning the latest Swift (rejected: the hosted runner lags the local machine).

**3. No runtime dependencies.** The package uses Foundation and CoreText only.
*Alternatives:* adopting packages as needed (rejected for now: every package is fetched, pinned and
audited for a few hundred lines of benefit, and an offline build stops working); vendoring code
(rejected: a second source to keep up to date). Development and CI tools that never ship in the package
are allowed when pinned: the JSON Schema checker of decision 4.
*Command line parsing:* the `framekit` executable parses its arguments by hand, without
`swift-argument-parser`. The first CLI has one command (`captions render`) with explicit path options,
`--help` and `--version` ([#19](https://github.com/RaioViajante/framekit/issues/19),
[#20](https://github.com/RaioViajante/framekit/issues/20)), which a small parser covers with exact,
tested error messages. `swift-argument-parser` (Apple's, well maintained, with generated help and shell
completion) would be the first package dependency, for a surface that small. Revisit when the CLI grows
nested subcommands or many options; the decision is recorded here and implemented in #19.

**4. Validation is a hand-written Swift validator over parsed JSON.** Documents are parsed into a
`JSONValue` tree and read by a small reader that reports every issue with a stable code and a JSON
Pointer, rejects unknown fields and never stops at the first error. The contract is the field tables
in [caption-configuration.md](../caption-configuration.md) together with this validator; a test fails
when the two diverge.
*Alternatives:* `Codable` straight into the models (rejected: it cannot report unknown fields, reports
one error at a time and has no pointers); a published JSON Schema with a runtime schema library
(rejected: a dependency for what a few hundred lines do); a JSON Schema file without a validator in the
tests (rejected: it would drift unchecked).
*JSON Schemas as published companions:* `captions/schemas/caption-preset.v1.schema.json` and
`caption-input.v1.schema.json` (draft 2020-12) describe the same structure for editors and other tools.
The Swift validator stays the runtime authority. Rules a schema cannot express (time order, references
between fields, Unicode rules, rules that need the preset) remain validator-only and are listed in
[caption-configuration.md](../caption-configuration.md#json-schemas). Tests keep the schemas, the
documentation and the validator in agreement; the schemas are checked with a pinned `check-jsonschema`
in development and CI only.
*`$id`:* each schema's `$id` is the raw GitHub URL of its file on `main`. The file name carries the
schema version, and a published `v1` file only receives changes that accept and reject exactly the same
documents; a new `schema_version` is a new file with a new `$id`.
*Alternatives for `$id`:* a custom domain or GitHub Pages URL (rejected: nothing hosts it); a URN
(rejected: not resolvable, so editors cannot fetch it); a URL pinned to a commit (rejected: a typo fix
would change the identifier).

**5. Every preset field is required.** A preset is complete and explicit; there are no defaults that
could change behind it. Only the input has optional fields (emphasis, explicit cue times, timing source).
Partial changes per video belong to the planned overrides
([#5](https://github.com/RaioViajante/framekit/issues/5),
[#6](https://github.com/RaioViajante/framekit/issues/6)).
*Alternatives:* defaults in the library for omitted fields (rejected: a library update could change how
an unchanged preset looks, and a reader of the file cannot see the effective value); a minimal preset that
inherits from a base preset (rejected for v1: inheritance between presets is what the overrides of #6 are
for, and two mechanisms would overlap).

**6. Presets are files selected by id.** `captions/presets/<preset_id>.json`, loaded by `PresetCatalog`
from a directory that is always passed in. Adding a preset is adding a file. No registry in code and no
plugin mechanism; behaviour the contract cannot express is a new `schema_version`.
*Alternatives:* a list of built-in presets in code (rejected: adding a look would need a code change and a
release); presets bundled as SwiftPM resources (rejected for now: a resource bundle must travel beside an
installed executable, which is a distribution question for
[#31](https://github.com/RaioViajante/framekit/issues/31)); a plugin interface for presets (rejected:
presets are data, and a new behaviour belongs in the contract where it is validated and documented).

**7. Effective values, exact floats.** A preset reproduces what the reference actually drew. Where the
reference generator and renderer disagree the renderer wins (outline alpha 0.92, not the generator's
unused 0.85). Colours keep the reference floats instead of hex approximations. The shadow offset uses
image coordinates (positive is down), so the reference look is `dy = -3`.
*Alternatives:* the values the reference generator declares (rejected: some are never read by the
renderer, so they describe a look that was not drawn); hex colours (rejected: the reference floats are
not multiples of 1/255, so the closest hex colour is a different colour); keeping the reference's
CoreGraphics shadow sign (rejected: every other offset in the contract is in image coordinates).
Verified during the review of [#37](https://github.com/RaioViajante/framekit/pull/37), with the reference
production's data read in place and not committed: from the preset alone, the documented timing and
emphasis reproduce every generic cue item of its frames with exact float equality.

**8. Fonts are a dependency, checked separately.** `required_fonts` lists exactly the fonts used.
Whether they are installed is checked against CoreText by exact PostScript name, apart from document
validation, because it depends on the machine. No substitution.
*Alternatives:* deriving the font list from the styles (rejected: the dependency would not be visible in
the file, and a typo in a style would silently add a font); a fallback font list (rejected for v1: no
visual equivalence between fonts is assumed, and a fallback would turn a missing font into a different
look without anyone noticing); failing document validation when a font is not installed (rejected: the
same preset would be valid on one machine and invalid on another).

**9. Reference-only behaviour stays out.** The reference production's `calm` and `shake` emphasis, its
hand-placed cue, its scene-based cue ends and its unused glow are not in the preset or the contract.
*Alternatives:* shipping them as extra emphasis styles or options (rejected: they were creative choices of
one production, the brief excludes them, and a general toolkit would then carry another project's
taste); dropping the frames that show them from the goldens (rejected: the frozen regression stays
untouched; the tests simply do not use those frames to trace the preset).

**10. Cue overrides first, overlaps after.** A cue's `start`/`end` in the input take precedence over the
boundaries derived from its words; cutting overlapping cues happens afterwards, and every resolved window
must be non-empty. The reference generator applied its per-cue end limits *after* the overlap step; with
the reference words this changes only one cue, which uses an emphasis style that is not in the preset.
*Alternatives:* limits applied after the overlap step, as in the reference (rejected: an explicit time
could then only shorten a cue, never extend it, and the cut would be computed from times the author had
replaced); overrides that also disable cutting (rejected: two cues could then be on screen at once in the
same place).

**11. Tests.** The package uses Swift Testing. The Python runner remains the harness for the frozen
reference and its goldens; the Swift tests read the reference frames only to trace the preset's values.
*Alternatives:* XCTest (rejected: Swift Testing ships with the same toolchains, gives parameterised tests
and exit tests, which let a test catch a crash in a child process, and is where Swift testing is going);
porting the Python runner to Swift (rejected: it guards the frozen reference and must stay exactly as
reviewed); testing the Swift library from Python (rejected: two languages for one module).

**12. Validated values stay valid.** `CaptionPreset` and `CaptionInput` are produced only by validation.
Outside the module their properties cannot be set, so a value always keeps the rules it was checked
against. Inside the module a value can be changed (per-video overrides will do this,
[#6](https://github.com/RaioViajante/framekit/issues/6)). The APIs that use an input with a preset,
`validate(against:)` and `cueWindows(with:)`, therefore check both again with the same validator, through
each value's JSON form, before using them. A changed value is reported, never trapped on, never used and
never passed silently: the input's errors keep their pointers into the input; a broken preset is one
`preset.invalid` issue whose message lists the preset's own errors, so input and preset pointers are not
mixed; `cueWindows(with:)` throws `InvalidCaptionPreset` or `InvalidCaptionInput` and returns windows
only when both values keep their rules and no window is empty.
*Alternatives:* fully public mutable models (rejected: a changed value crashed `cueWindows`); immutable
models with `let` (rejected: the overrides of #6 need to build changed values inside the module); a
second, hand-written invariant check (rejected: it would duplicate the validator's rules and drift);
re-checking only the input (rejected: a preset changed to a NaN lead-in or a negative fade-out produced
windows of NaN or with a negative fade-out without any issue); reporting the preset's errors as input
issues (rejected: their pointers point into another document).

## Module boundaries

| Module | Responsibility | Status |
|---|---|---|
| configuration (`FrameKitCaptions`) | documents, validation, preset selection, font check, cue windows | done |
| rendering engine | frames from a preset and an input | [#10](https://github.com/RaioViajante/framekit/issues/10), [#12](https://github.com/RaioViajante/framekit/issues/12), [#13](https://github.com/RaioViajante/framekit/issues/13) |
| `framekit` CLI | paths in, frames and report out | [#19](https://github.com/RaioViajante/framekit/issues/19), [#20](https://github.com/RaioViajante/framekit/issues/20) |

## Open questions

| Question | Resolved in |
|---|---|
| The episode document and per-video overrides | [#5](https://github.com/RaioViajante/framekit/issues/5), [#6](https://github.com/RaioViajante/framekit/issues/6) |
| A conformance corpus covering every error code | [#8](https://github.com/RaioViajante/framekit/issues/8) |
| Moving canvas size and frame rate, which describe the video rather than the look, into a generic `render-config` document; v1 presets keep them | [#5](https://github.com/RaioViajante/framekit/issues/5) |
| Detecting repeated keys in a JSON object (the parser keeps the last one) | [#7](https://github.com/RaioViajante/framekit/issues/7) |
| How an installed CLI finds the shipped presets | [#19](https://github.com/RaioViajante/framekit/issues/19), [#31](https://github.com/RaioViajante/framekit/issues/31) |
| The instant a frame samples (the reference uses the middle of the frame) | [#13](https://github.com/RaioViajante/framekit/issues/13) |
| Error reports that name the file, for the CLI | [#7](https://github.com/RaioViajante/framekit/issues/7), [#23](https://github.com/RaioViajante/framekit/issues/23) |
| Diagnostics (safe zones, collisions, contrast) in the preset | [#25](https://github.com/RaioViajante/framekit/issues/25), [#26](https://github.com/RaioViajante/framekit/issues/26), [#27](https://github.com/RaioViajante/framekit/issues/27) |
