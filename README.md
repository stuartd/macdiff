# MacDiff

A small, native macOS viewer for comparing two versions of text side by side. It is designed to work on its own or as ClipDiff’s external viewer. There are no merge controls, and source files are never modified.

## Run

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16 or later).

```sh
swift run MacDiff
swift run MacDiff '/path/to/original.txt' '/path/to/changed.txt'
```

For a normal application bundle:

```sh
./scripts/build-app.sh
open dist/MacDiff.app
```

The script builds a release app for the current Mac’s architecture and signs it for local use. Pass `debug` for a debug build. The bundle is intended for local development; it is not notarized for distribution.

## Use with ClipDiff

In ClipDiff, choose **Diff viewer → Choose Application…** and select `dist/MacDiff.app` (or its `Contents/MacOS/MacDiff` executable).

MacDiff accepts the original and changed paths as two separate positional arguments, matching ClipDiff’s custom-viewer launch contract. Each invocation opens its own comparison. Closing the window exits that process, allowing ClipDiff to clean up its temporary files. ClipDiff handles capturing the clipboard and supplying the two text files.

You can also launch a new instance yourself:

```sh
open -n dist/MacDiff.app --args '/path/to/original.txt' '/path/to/changed.txt'
```

Use `--` before paths beginning with a hyphen. `--help` prints usage.

## Comparing text

- **Open** a file on each side, or drop one file onto each header.
- **Paste** text into either side, or use **Edit** to enter a snippet. An explicitly empty input can be compared too.
- **Copy** copies the complete source text, without line numbers or display formatting.
- **Swap** reverses the two inputs; **Clear** starts again.
- Previous/next navigation jumps between groups of changed lines. The current group’s first line has an accent outline.
- **Ignore spacing** trims leading/trailing whitespace and collapses runs of whitespace within a line. Line breaks still matter.
- **Appearance** offers system, light, and dark modes, plus adjustable text size. Colours are subdued, and additions/removals also have `+`/`−` markers.

The panes scroll together and each occupy half the window. Long lines wrap, with both sides of each row kept at the same height so matching lines remain aligned. Tabs display as four spaces; copying preserves the original tabs.

### Shortcuts

| Action | Shortcut |
| --- | --- |
| Open original / changed | ⌘O / ⇧⌘O |
| Paste original / changed | ⇧⌘V / ⌥⌘V |
| Previous / next change | ⌘[ / ⌘] |
| Swap | ⌥⌘S |
| Larger / smaller text | ⌘+ / ⌘− |
| Default text size | ⌘0 |

## Comparison and input limits

Comparisons run away from the UI thread, and newer inputs cancel obsolete work. The engine uses linear working memory rather than a full quadratic LCS table. For especially difficult large inputs, a bounded search may show a larger replacement block instead of the smallest possible set of changes.

LF, CRLF, and CR line endings compare equivalently. A final line break appears as a final empty row, so adding or removing the final newline is still visible. Original text is retained for copying.

Files support strict UTF-8 (with or without a byte-order mark) and UTF-16 with a byte-order mark. Unsupported encodings, binary files, and oversized inputs produce an error without replacing the previous input. Each input is limited to 5 MiB, 100,000 lines, and 100,000 display columns per line to keep the viewer responsive.

Inputs stay in memory and are discarded when the app exits. MacDiff reads the clipboard only when you press Paste and writes to it only when you press Copy. Only appearance and text-size preferences are saved.

## Test

```sh
swift test
```

Tests cover comparison correctness and cancellation, large inputs, line endings, file decoding and limits, launch arguments, and asynchronous document state/navigation.
