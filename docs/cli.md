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

Options take their value as the next argument or after `=` (`--frames=0..47`). A value that starts with
`-` must be joined with `=`, as in `--out=-x` (or written as a path, `--out ./-x`): given as the next
argument it is taken for a missing value followed by another option, which is a usage error. Each option
may be given once, in any order. Paths are used exactly as given (relative to the current directory); nothing is looked up
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
- **At most 1,000,000 frames per run,** whatever their numbers (`2000000..2000999` is fine). An hour at
  240 fps is 864,000 frames, and a million 1080×1916 frames are tens of gigabytes of PNG and hours of
  rendering, so a larger request is almost always a mistake: a range with a digit too many, or a cue time
  in the wrong unit. A larger `--frames` is a usage error (64); captions that would need more frames by
  default are an invalid document (65). Render a longer video in parts with `--frames`. There is no check
  of free disk space.

### Output

`--out DIR` is never overwritten:

- `DIR` must either not exist, in which case it is created (its parent must exist; no other directory is
  created), or be an **empty** directory. Hidden files count: a directory holding only `.DS_Store` is not
  empty. Anything else (a non-empty directory, a file, a missing parent) is refused with status 73,
  before anything is written. To render again, choose a new directory or empty the old one.
- Nothing is written outside `DIR`.
- Frames are rendered into a hidden folder `DIR/.framekit-partial-<id>/` and moved into `DIR` only when
  every frame of the range has been rendered.
- If framekit stops with an error, or is interrupted by Ctrl-C (SIGINT), SIGTERM or SIGHUP, it undoes
  what it did: it removes the frames it wrote and moved, its hidden folder, and `DIR` if this run created
  it. No success line is printed and the exit status is not 0.
- It never removes what it did not write. Every file and folder framekit creates is identified by its
  device and inode, checked again just before removal: a file another process put in `DIR` during the
  run, or put in place of one of framekit's frames, stays, and a folder is only removed when it is empty.
  If `DIR` was created by this run but now holds such files, it stays too, and the message lists what was
  left in place. (Between that check and the removal there is a moment of a few microseconds in which
  another process could still swap the file; a render shares its output directory with nobody in normal
  use.)

### Interruptions and their limits

Ctrl-C, SIGTERM and SIGHUP are caught: framekit finishes the frame it is drawing, cleans up as above and
exits with 128 + the signal number (130, 143, 129). Two things cannot be handled:

- **SIGKILL** (`kill -9`, or the system ending the process) stops framekit at once. Killed while rendering,
  it leaves the hidden folder (and `DIR`, if it created it) but no frame in `DIR` itself. Killed while
  finished frames are being moved into place, a short final step, it also leaves the frames moved so far
  in `DIR`. Either way the hidden folder is still there: its presence means the render did not finish.
  Delete `DIR` (or empty it) and render again.
- **Power loss or a system crash.** framekit does not force its files to disk (no `fsync`), so after
  one, recently written frames can be missing, empty or truncated even if the render had finished. Render
  again after such an event.

### Standard output and error

The success line goes to standard output; diagnostics go to standard error. If a stream is closed, or
whatever reads it has exited (`framekit … | head -0`), the text is lost and framekit carries on: it never
aborts because of it. The exit status then reports the work, not the message: a render that wrote every
frame exits 0 even if its success line could not be written, and an error keeps its status even if its
message could not be. Help and version are different, because the text is the result: if it cannot be
written, the status is 74.

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
| 0 | done: every frame written; or help or version printed |
| 64 | usage error: unknown command or option, missing or repeated option, malformed `--frames` |
| 65 | a document has errors, alone or together (including a cue so late that its frames cannot be numbered) |
| 66 | a file given with `--preset` or `--input` cannot be read |
| 69 | a font of the preset is not installed |
| 70 | rendering failed after every check passed |
| 73 | `--out` refused: not empty, a file, or its parent does not exist |
| 74 | writing the frames failed (for example, the disk is full); or help or version could not be written |
| 129, 130, 143 | interrupted by SIGHUP, SIGINT (Ctrl-C) or SIGTERM, after cleaning up |

A run that ends with any of these statuses other than 0 has removed every frame it wrote (if the system
refused a removal, the message names the file). A process ended
by SIGKILL has no exit status of its own; see [its limits](#interruptions-and-their-limits).

## What is not there yet

| Missing | Issue |
|---|---|
| a JSON report of what a render did | [#23](https://github.com/RaioViajante/framekit/issues/23) |
| refusing characters the font does not have (they come out as wrong glyphs); declared font substitutes | [#22](https://github.com/RaioViajante/framekit/issues/22) |
| writing only frames with captions, plus one empty frame | [#21](https://github.com/RaioViajante/framekit/issues/21) |
| an episode document with per-video overrides | [#5](https://github.com/RaioViajante/framekit/issues/5), [#16](https://github.com/RaioViajante/framekit/issues/16) |
| selecting a shipped preset by id instead of by path; an installer | [#31](https://github.com/RaioViajante/framekit/issues/31) |
| a free-disk-space check; a time limit for a very long word | — |

FrameKit does not transcribe or align audio: the words and their times in the caption input come from
elsewhere.
