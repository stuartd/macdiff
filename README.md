# MacDiff

A small, native macOS viewer for comparing two versions of text side by side and browsing commits in a Git repository. It is designed to work on its own or as ClipDiff’s external viewer. There are no merge controls, and source files are never modified.

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

**MacDiff → About MacDiff** shows the short Git commit hash and build date and time (UTC). A Swift package build plugin generates these constants before compilation, so `swift build`, `swift run`, Xcode package builds, and CI builds all include them without relying on the app packaging script. The values travel with the executable. The hash comes from the checked-out commit, with `GITHUB_SHA` as a fallback for source archives in GitHub Actions; without either, it shows “Unavailable”. The timestamp records this build invocation, not the commit date or launch time.

To install the built app, quit MacDiff, then copy `dist/MacDiff.app` into `/Applications` using Finder, replacing the previous copy if present. Select the installed app in ClipDiff so future comparisons use that copy.

The build converts `icon/icon.png` into the macOS app icon, including standard and Retina sizes. To update the icon, replace that square PNG (at least 1024 × 1024 pixels) and rebuild the app bundle.

## Signed and notarized releases

Local builds use ad hoc signing. To distribute a download, install a **Developer ID Application** certificate and its private key in Keychain, and save notarization credentials once:

```sh
xcrun notarytool store-credentials "ClipDiff-Notary" \
  --apple-id "YOUR_APPLE_ACCOUNT_EMAIL" --team-id "ZQ5KWSZ72K"
```

Enter an Apple-generated app-specific password when prompted. An existing profile for the same Apple team can be reused; do not put passwords or private keys in the repository.

From a clean, committed checkout, run:

```sh
SIGNING_IDENTITY="Developer ID Application: Stuart Dunkeld (ZQ5KWSZ72K)" \
NOTARY_PROFILE="ClipDiff-Notary" ./scripts/release.sh
```

The script runs tests, builds a universal Intel/Apple Silicon release in fresh scratch directories, signs with hardened runtime and a secure timestamp, and waits for Apple's notarization result. Only an `Accepted` result proceeds to stapling and Gatekeeper verification. It then creates a new ZIP, extracts that ZIP, and verifies its signature, ticket, and Gatekeeper acceptance again.

Verified ZIPs, SHA-256 checksums, and Apple's submission result are saved in `dist/releases/`, named with the version from `Resources/Info.plist` and the source commit. Existing release ZIPs are never overwritten. On failure, the script retains its working directory and diagnostics under `dist/`; on success, temporary files are removed. It does not publish to GitHub or replace your installed app.

Notarization needs network access and may take several minutes. If the 30-minute wait expires, inspect the retained submission ID with `xcrun notarytool info ID --keychain-profile "ClipDiff-Notary"` before deciding whether to retry. If Apple rejects a submission, retrieve details with `xcrun notarytool log ID --keychain-profile "ClipDiff-Notary"`.

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

- **Last commit** is selected by default. The panes compare the latest commit with its parent, using committed contents on both sides.
- Open the commit picker to browse earlier commits. Search by commit message or a short/full hash; use **Load more commits** to browse further back. Message searches cover the current HEAD’s history, including commit bodies. A hash can also locate another commit available in the repository.
- The sidebar lists files changed by the selected commit. Switch between a flat list and a directory tree, or filter by path.
- Added files compare against empty text; deleted files have an empty right side. Renames compare against the original path. Initial commits compare with an empty base.
- Merge commits compare with their **first parent**, explicitly labelled in the review.
- **Refresh** (⌘R) picks up a new or amended commit when **Last commit** is selected. An explicitly selected historical commit stays pinned. Refresh retains the selected file when it is still present.
- Repositories with no commits and commits with no file changes have distinct empty states. Missing parents (for example in shallow clones) report Git’s error.
- Binary files, unsupported encodings, oversized files, symbolic links, and submodules show an explanation instead of a text diff. Renames and permission changes may have no text differences.

Repository review is read-only and commits-only. Staged, unstaged, and untracked files do not affect either pane. MacDiff does not stage, commit, discard changes, check out branches, or update Git’s index. Linked Git worktrees and detached HEAD are supported.

## Comparing text

- Use **File → Open Original… / Open Changed…**, the toolbar’s folder menu, or the **…** menu in each pane header to open files. You can also drop one file onto each text pane or header. Dropping onto a pane loads that side, including before a comparison starts and in the blank space below short files.
- Use the **Edit** menu or a pane’s **…** menu to **Paste** text into either side or **Edit** a snippet. An explicitly empty input can be compared too.
- **Copy Text** in each pane’s **…** menu (or the **Edit** menu) copies the complete source text, without line numbers or display formatting. Repository headers have a copy icon.
- Drag to select any range of text within either diff pane, across lines and wrapped rows. Shift-click and keyboard selection work too; **⌘A** selects that side and **⌘C** copies the selection. Copied selections preserve source tabs and line endings, without line numbers, change markers, or alignment gaps.
- **Comparison → Swap Inputs** reverses the two inputs; **File → New** (⌘N) clears both inputs and starts a fresh comparison.
- Previous/next navigation jumps between groups of changed lines. The current group’s first line has an accent outline.
- Modified lines use stronger red/green shading on the changed text within each line. Matching text keeps the subtle line background, and **Ignore spacing** also applies to these highlights.
- **Ignore Spacing**, in the **Comparison** menu or the toolbar’s comparison options, trims leading/trailing whitespace and collapses runs of whitespace within a line. Line breaks still matter.
- **View → Appearance** offers system, light, and dark modes; the **View** menu also has text-size controls for comparisons, input previews, and the text editor (15-point default). Sidebar and status text use a separate readable interface size. Colours are subdued, and additions/removals also have `+`/`−` markers.

The panes scroll together and each occupy half the window. Long lines wrap, with both sides of each row kept at the same height so matching lines remain aligned. Tabs use four-column stops; copying preserves the original tabs.

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
