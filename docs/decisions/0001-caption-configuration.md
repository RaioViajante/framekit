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

**3. No dependencies.** Foundation and CoreText only. Whether the CLI uses `swift-argument-parser` is
decided in [#19](https://github.com/RaioViajante/framekit/issues/19).

**4. Validation is a hand-written Swift validator over parsed JSON.** Documents are parsed into a
`JSONValue` tree and read by a small reader that reports every issue with a stable code and a JSON
Pointer, rejects unknown fields and never stops at the first error. The contract is the field tables
in [caption-configuration.md](../caption-configuration.md) together with this validator; a test fails
when the two diverge.
*Alternatives:* `Codable` straight into the models (rejected: it cannot report unknown fields, reports
one error at a time and has no pointers); a published JSON Schema with a runtime schema library
(rejected: a dependency for what a few hundred lines do); a JSON Schema file without a validator in the
tests (rejected: it would drift unchecked).
*Approved follow-up:* machine-readable JSON Schemas (draft 2020-12) for the preset and input documents
are published in a separate pull request, kept consistent with this validator by automated tests, before
[#3](https://github.com/RaioViajante/framekit/issues/3) is closed. The Swift validator stays the runtime
authority; rules a schema cannot express (time order, references between fields, NFC, rules that need
the preset) remain validator-only and are listed as such.

**5. Every preset field is required.** A preset is complete and explicit; there are no defaults that
could change behind it. Only the input has optional fields (emphasis, explicit cue times, timing source).
Partial changes per video belong to the planned overrides
([#5](https://github.com/RaioViajante/framekit/issues/5),
[#6](https://github.com/RaioViajante/framekit/issues/6)).

**6. Presets are files selected by id.** `captions/presets/<preset_id>.json`, loaded by `PresetCatalog`
from a directory that is always passed in. Adding a preset is adding a file. No registry in code and no
plugin mechanism; behaviour the contract cannot express is a new `schema_version`.

**7. Effective values, exact floats.** A preset reproduces what the reference actually drew. Where the
reference generator and renderer disagree the renderer wins (outline alpha 0.92, not the generator's
unused 0.85). Colours keep the reference floats instead of hex approximations. The shadow offset uses
image coordinates (positive is down), so the reference look is `dy = -3`.

**8. Fonts are a dependency, checked separately.** `required_fonts` lists exactly the fonts used.
Whether they are installed is checked against CoreText by exact PostScript name, apart from document
validation, because it depends on the machine. No substitution.

**9. Reference-only behaviour stays out.** The reference production's `calm` and `shake` emphasis, its
hand-placed cue, its scene-based cue ends and its unused glow are not in the preset or the contract.

**10. Cue overrides first, overlaps after.** A cue's `start`/`end` in the input take precedence over the
boundaries derived from its words; cutting overlapping cues happens afterwards, and every resolved window
must be non-empty. The reference generator applied its per-cue end limits *after* the overlap step; with
the reference words this changes only one cue, which uses an emphasis style that is not in the preset.

**11. Tests.** The package uses Swift Testing. The Python runner remains the harness for the frozen
reference and its goldens; the Swift tests read the reference frames only to trace the preset's values.

## Module boundaries

| Module | Responsibility | Status |
|---|---|---|
| configuration (`FrameKitCaptions`) | documents, validation, preset selection, font check | this increment |
| rendering engine | frames from a preset and an input | [#10](https://github.com/RaioViajante/framekit/issues/10), [#12](https://github.com/RaioViajante/framekit/issues/12), [#13](https://github.com/RaioViajante/framekit/issues/13) |
| `framekit` CLI | paths in, frames and report out | [#19](https://github.com/RaioViajante/framekit/issues/19), [#20](https://github.com/RaioViajante/framekit/issues/20) |

## Open questions

| Question | Resolved in |
|---|---|
| The episode document and per-video overrides | [#5](https://github.com/RaioViajante/framekit/issues/5), [#6](https://github.com/RaioViajante/framekit/issues/6) |
| Publishing the JSON Schemas and their parity tests (decided, follow-up pull request) | [#3](https://github.com/RaioViajante/framekit/issues/3), [#8](https://github.com/RaioViajante/framekit/issues/8) |
| Whether canvas size and frame rate, which describe the video rather than the look, move to the episode document | [#5](https://github.com/RaioViajante/framekit/issues/5) |
| Detecting repeated keys in a JSON object (the parser keeps the last one) | [#7](https://github.com/RaioViajante/framekit/issues/7) |
| How an installed CLI finds the shipped presets | [#19](https://github.com/RaioViajante/framekit/issues/19), [#31](https://github.com/RaioViajante/framekit/issues/31) |
| The instant a frame samples (the reference uses the middle of the frame) and how explicit cue times interact with cutting overlaps | [#13](https://github.com/RaioViajante/framekit/issues/13) |
| Error reports that name the file, for the CLI | [#7](https://github.com/RaioViajante/framekit/issues/7), [#23](https://github.com/RaioViajante/framekit/issues/23) |
| Diagnostics (safe zones, collisions, contrast) in the preset | [#25](https://github.com/RaioViajante/framekit/issues/25), [#26](https://github.com/RaioViajante/framekit/issues/26), [#27](https://github.com/RaioViajante/framekit/issues/27) |
