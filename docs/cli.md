# The `framekit` command

Status: **first version, `0.1.0-dev`.** One command, `framekit captions render`, which renders the
captions of a caption input with a preset into transparent PNG frames. There is no release or installer
yet: build it from this repository. No report file, no episode document and no font substitution yet
(see [what is not there yet](#what-is-not-there-yet)).

## Build and run

```sh
swift build -c release
.build/release/framekit --help
```

The binary is `.build/release/framekit`; copy it anywhere on your `PATH` if you like. It needs macOS 14
or later and the fonts of the preset (for `kinetic-minimal`: `AvenirNext-Medium` and `Palatino-Italic`,
which ship with macOS).

## `framekit captions render`

```
framekit captions render --preset FILE --input FILE --out DIR [--frames A..B]
```

| Option | Meaning |
|---|---|
| `--preset FILE` | caption preset, such as `captions/presets/kinetic-minimal.json` ([preset contract](caption-configuration.md#preset-contract)) |
| `--input FILE` | caption input: the words with their times, and the cues ([input contract](caption-configuration.md#input-contract)) |
| `--out DIR` | where the frames go; see [output](#output) |
| `--frames A..B` | only frames `A` to `B`, both included; optional |
| `-h`, `--help` | the command's help |

Options take their value as the next argument or after `=` (`--frames=0..47`). Each may be given once,
in any order. Paths are used exactly as given (relative to the current directory); nothing is looked up
anywhere else, and the preset's file name does not have to match its `preset_id`.

Example, with the sample input in this repository:

```sh
.build/release/framekit captions render \
  --preset captions/presets/kinetic-minimal.json \
  --input captions/examples/overlapping-cues.input.json \
  --out frames
```

```
framekit: rendered 107 frame(s), frames 0..106, 1080×1916 at 24 fps, into …/frames
```

A quick preview of one second, frames 24 to 47:

```sh
.build/release/framekit captions render --preset captions/presets/kinetic-minimal.json \
  --input captions/examples/overlapping-cues.input.json --out preview --frames 24..47
```

### Frames

Frame `i` shows the instant `(i + 0.5) / fps` of the video, the middle of the frame, with `fps` from the
preset's `canvas`. Each frame is one PNG: `canvas.width` × `canvas.height` px, 8-bit RGBA, transparent
where there is no caption, named after its index with at least four digits (`0000.png`, `0001.png`, …,
`12345.png`), as the [rendering engine](caption-rendering.md#the-rendering-engine) names them. Every frame
of the range is written, also those that show nothing, so the sequence has no gaps and can be laid over
the video from its first frame.

- **Default range:** frame 0 up to the last frame whose instant falls inside a cue's visible window
  (that last one may be fully transparent, at the very end of a fade-out). An input whose cues all end
  before the middle of frame 0 renders no frame.
- **`--frames A..B`:** `A` and `B` are frame numbers written with the digits 0 to 9, `A ≤ B`; both are
  included. They may go past the last caption, which gives transparent frames, for example to cover the
  rest of a video. Anything else (`7..5`, `5`, `-1..3`, `1...3`, `+1..3`) is a usage error, reported before
  anything is read or written.

### Output

`--out DIR` is never overwritten:

- `DIR` must either not exist, in which case it is created (its parent must exist; no other directory is
  created), or be an **empty** directory. Hidden files count: a directory holding only `.DS_Store` is not
  empty. Anything else (a non-empty directory, a file, a missing parent) is refused with status 73,
  before anything is written. To render again, choose a new directory or empty the old one.
- Nothing is written outside `DIR`.
- Frames are rendered into a hidden folder `DIR/.framekit-partial-<id>/` and moved into `DIR` only when
  every frame of the range has been rendered. If rendering or writing fails, the frames and the hidden
  folder are removed, and so is `DIR` if this run created it: `DIR` is left as it was.
- If the process is killed (for example with `kill -9`), only the hidden folder can remain; `DIR` never
  holds frames from an unfinished render, except if it is killed in the short moment when finished frames
  are moved into place. Delete the hidden folder (and `DIR`) and render again.

### Checks before rendering

In this order, and all before `DIR` is touched:

1. the command line (status 64);
2. both files can be read (66);
3. the preset and the input are each valid, and the input fits the preset (line count, emphasis styles,
   cue windows) (65). Every issue is printed, not only the first;
4. every font in the preset's `required_fonts` is installed under exactly that PostScript name (69).
   A missing font is never replaced by another one.

Each issue is printed on standard error as `FILE: SEVERITY CODE at POINTER: MESSAGE`, with the stable
[error code](caption-configuration.md#error-codes) and a JSON Pointer into that file:

```
my.input.json: warning word.unused at /words/3: word "d" is not in any cue and will not be shown
my.input.json: error cue.too_many_lines at /cues/0/lines: cue "c1" has 3 lines; preset "kinetic-minimal" allows 2
framekit: stopped: the caption input does not fit preset "kinetic-minimal"; nothing was written
```

Warnings do not stop rendering. On success, one line goes to standard output; diagnostics always go to
standard error.

## Other commands

| Command | Does |
|---|---|
| `framekit --help`, `framekit -h` | lists the commands |
| `framekit --version` | prints `framekit 0.1.0-dev` |
| `framekit captions --help` | lists the caption commands |
| `framekit captions render --help` | the options above, and the exit statuses |

`framekit` or `framekit captions` without a command prints the help on standard error with status 64.

## Exit status

From [sysexits(3)](https://man.freebsd.org/cgi/man.cgi?query=sysexits); distinct from the
[regression runner's](regression-testing.md#exit-codes).

| Status | Meaning |
|---|---|
| 0 | done; or help or version printed |
| 64 | usage error: unknown command or option, missing or repeated option, malformed `--frames` |
| 65 | a document has errors, alone or together (including a cue so late that its frames cannot be numbered) |
| 66 | a file given with `--preset` or `--input` cannot be read |
| 69 | a font of the preset is not installed |
| 70 | rendering failed after every check passed |
| 73 | `--out` refused: not empty, a file, or its parent does not exist |
| 74 | writing the frames failed (for example, the disk is full) |

A run that does not end with status 0 has left no frame behind.

## What is not there yet

| Missing | Issue |
|---|---|
| a JSON report of what a render did | [#23](https://github.com/RaioViajante/framekit/issues/23) |
| refusing characters the font does not have (they come out as wrong glyphs); declared font substitutes | [#22](https://github.com/RaioViajante/framekit/issues/22) |
| writing only frames with captions, plus one empty frame | [#21](https://github.com/RaioViajante/framekit/issues/21) |
| an episode document with per-video overrides | [#5](https://github.com/RaioViajante/framekit/issues/5), [#16](https://github.com/RaioViajante/framekit/issues/16) |
| selecting a shipped preset by id instead of by path; an installer | [#31](https://github.com/RaioViajante/framekit/issues/31) |
| limits on huge inputs (a very long word or a very late cue takes as long as it takes) | — |

FrameKit does not transcribe or align audio: the words and their times in the caption input come from
elsewhere.
