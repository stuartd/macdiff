# MacDiff

A small, native macOS viewer for comparing two versions of text side by side and reviewing working changes in a Git repository. It is designed to work on its own or as ClipDiff’s external viewer. There are no merge controls, and source files are never modified.

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

To install the built app, quit MacDiff, then copy `dist/MacDiff.app` into `/Applications` using Finder, replacing the previous copy if present. Select the installed app in ClipDiff so future comparisons use that copy.

The build converts `icon/icon.png` into the macOS app icon, including standard and Retina sizes. To update the icon, replace that square PNG (at least 1024 × 1024 pixels) and rebuild the app bundle.

## Use with ClipDiff

In ClipDiff, choose **Diff viewer → Choose Application…** and select `dist/MacDiff.app` (or its `Contents/MacOS/MacDiff` executable).

ClipDiff sends the original and changed files to MacDiff through macOS. Each comparison replaces the contents of the existing window and brings it to the front; MacDiff launches only if needed. Closing the window exits MacDiff and allows ClipDiff to clean up its temporary comparison files. Update both apps to use this handoff.

To reuse the same window from the command line:

```sh
open -a "/Applications/MacDiff.app" "/path/to/original.txt" "/path/to/changed.txt"
```

Direct executable launches still accept two positional paths.

You can also launch a new instance yourself:

```sh
open -n dist/MacDiff.app --args '/path/to/original.txt' '/path/to/changed.txt'
```

Use `--` before paths beginning with a hyphen. `--help` prints usage.

## Reviewing a Git repository

Choose **Open → Open Repository…** from the folder menu in the window toolbar, or **File → Open Repository…** (⌥⌘O), then select your project folder. Git must be available at `/usr/bin/git` (provided by Apple’s command-line developer tools).

- The sidebar lists changed files, including staged, unstaged, and untracked files. Ignored files are excluded. Switch between a flat list and a directory tree, or filter by path.
- Select a file to compare **Last commit on your branch → Working tree**. This combines staged and unstaged edits; it is not a preview of just the next commit. The sidebar footer describes the selected file’s staging status.
- Use **Compare against** above the review to choose another local branch, even before selecting a file. The sidebar keeps the same working-change files and your selection; differences elsewhere between the branches are outside this review. Files matching the chosen branch stay listed as **Identical to [branch]**, with their contents available to inspect. Matching requires identical bytes, file presence, and executable permissions; ignoring spacing does not affect this label.
- Other branch baselines compare the file’s current path on that branch with its working-tree path. A missing path is an empty side. The default last-commit baseline retains staged-rename handling. Branch tips are captured when the repository is opened or refreshed; changing the baseline never checks out a branch.
- Added and untracked files compare against empty text; deleted files have an empty working-tree side. Staged renames compare against the original path. A repository without a first commit uses an empty base.
- Press **Refresh** (⌘R) after editing files or changing Git state elsewhere. Refresh preserves the selected file when it is still listed and updates the chosen branch baseline. If that branch has been deleted, a notice explains the return to the default baseline.
- Binary files, unsupported encodings, oversized files, symbolic links, submodules, and unresolved conflicts show an explanation instead of a text diff. A rename, permission change, or staged edit reversed in the working tree can have no text differences.
- **New** (⌘N) returns to a regular two-input comparison. ClipDiff comparisons also replace the repository view.

Choose **Last commit** in the review switch above the file list to inspect the current branch’s latest commit, including after you have committed and pushed. The header shows the commit’s short SHA and subject; the panes compare its parent with the committed version. Both sides come from Git, so staged, unstaged, and untracked files do not affect this review. Switch back to **Working changes** to return to your chosen branch baseline.

- Initial commits compare with an empty base. Repositories with no commits and commits with no file changes have distinct empty states.
- Merge commits compare with their **first parent**, explicitly labelled in the review. This shows what the merge brought into that parent’s branch.
- Added, deleted, renamed, and permission-only changes stay in the file list. Binary files and other unsupported inputs keep the same explanatory handling as working changes.
- **Refresh** (⌘R) picks up a new or amended last commit and retains the selected file when it is still present. If a parent is unavailable, such as in a shallow clone, the comparison reports Git’s error.

Repository review is read-only: MacDiff does not stage, commit, discard changes, or update Git’s index. Whole-branch comparisons and browsing older commits are not included yet. Linked Git worktrees and detached HEAD are supported.

## Comparing text

- Use **File → Open Original… / Open Changed…**, the toolbar’s folder menu, or the **…** menu in each pane header to open files. You can also drop one file onto each text pane or header. Dropping onto a pane loads that side, including before a comparison starts and in the blank space below short files.
- Use the **Edit** menu or a pane’s **…** menu to **Paste** text into either side or **Edit** a snippet. An explicitly empty input can be compared too.
- **Copy Text** in each pane’s **…** menu (or the **Edit** menu) copies the complete source text, without line numbers or display formatting. Repository headers have a copy icon.
- **Comparison → Swap Inputs** reverses the two inputs; **File → New** (⌘N) clears both inputs and starts a fresh comparison.
- Previous/next navigation jumps between groups of changed lines. The current group’s first line has an accent outline.
- Modified lines use stronger red/green shading on the changed text within each line. Matching text keeps the subtle line background, and **Ignore spacing** also applies to these highlights.
- **Ignore Spacing**, in the **Comparison** menu or the toolbar’s comparison options, trims leading/trailing whitespace and collapses runs of whitespace within a line. Line breaks still matter.
- **View → Appearance** offers system, light, and dark modes; the **View** menu also has text-size controls for comparisons, input previews, and the text editor (15-point default). Sidebar and status text use a separate readable interface size. Colours are subdued, and additions/removals also have `+`/`−` markers.

The panes scroll together and each occupy half the window. Long lines wrap, with both sides of each row kept at the same height so matching lines remain aligned. Tabs display as four spaces; copying preserves the original tabs.

When both files have the same name, the headers include enough parent folders to distinguish their paths. Hover over either label to see the full path.

### Shortcuts

| Action | Shortcut |
| --- | --- |
| New comparison | ⌘N |
| Open original / changed | ⌘O / ⇧⌘O |
| Paste original / changed | ⇧⌘V / ⌥⌘V |
| Previous / next change | ⌘[ / ⌘] |
| Swap | ⌥⌘S |
| Larger / smaller text | ⌘+ / ⌘− |
| Default text size | ⌘0 |

## Comparison and input limits

Comparisons run away from the UI thread, and newer inputs cancel obsolete work. The engine uses linear working memory rather than a full quadratic LCS table. For especially difficult large inputs, a bounded search may show a larger replacement block instead of the smallest possible set of changes.

Within-line highlighting also has a bounded work budget. Difficult spans may receive broader highlights; very long lines or comparisons that exhaust this budget retain whole-line shading.

LF, CRLF, and CR line endings compare equivalently. A final line break appears as a final empty row, so adding or removing the final newline is still visible. Original text is retained for copying.

Files support strict UTF-8 (with or without a byte-order mark) and UTF-16 with a byte-order mark. Unsupported encodings, binary files, and oversized inputs produce an error without replacing the previous input. Each input is limited to 5 MiB, 100,000 lines, and 100,000 display columns per line to keep the viewer responsive.

Inputs stay in memory and are discarded when the app exits. MacDiff reads the clipboard only when you press Paste and writes to it only when you press Copy. Only appearance, text-size, and repository list/tree preferences are saved.

## Test

```sh
swift test
```

Tests cover comparison correctness and cancellation, large inputs, line endings, file decoding and limits, launch arguments, asynchronous document state/navigation, and repository review against temporary Git repositories (including renames, unusual paths, worktrees, and unchanged index contents).
