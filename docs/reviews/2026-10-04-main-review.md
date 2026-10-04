# MacDiff code review — 4 October 2026

Repository: **stuartd/macdiff**  
Branch reviewed: **main**  
Reviewed commit: **3a1e4936648c808ef5727f9894a518501d982096**  
Scope: all Swift production and test files, package/build plugin, application plist, build/release scripts, and README. The binary icon was excluded.

## Assessment

The core is sensibly separated from the macOS UI. Diff alignment and inline highlighting have explicit work budgets; file loading is bounded; background results use generation checks; Git comparisons read immutable objects rather than the working tree. Existing tests cover many meaningful cases, including randomized alignment checks, Unicode selection, failed handoffs, and repository history.

This review found **three P2 defects and two P3 defects**. There are no confirmed P0/P1 findings. Address the source-preservation and Git handling defects first. Performance concerns below need macOS measurements before being treated as demonstrated regressions.

This is a review report only. No application code was changed.

## Findings

### R1 — P2: Preserve exact Unicode input when deciding whether text changed

**Locations:** [DiffDocument.swift:87–100](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/MacDiff/DiffDocument.swift#L87), [SelectableDiffView.swift:47–55](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/MacDiff/SelectableDiffView.swift#L47), and [DiffEngine.swift:55–75](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/DiffCore/DiffEngine.swift#L55).

**Trigger:** Enter composed `"\u{00E9}"` on one side, then replace that text with decomposed `"e\u{0301}"`. These look the same but have different Unicode scalars and UTF-8/UTF-16 sequences.

**Problem:** Swift String equality uses canonical equivalence. In a text input with no file URL, `updateText` treats the replacement as unchanged and returns without storing it. Copying therefore returns the previous representation, even though the editor accepted the new one. The view cache also uses String/derived row equality, so reloading canonically equivalent file contents can retain an older selection-to-source mapping. The diff engine interns lines by String keys, hiding normalization-only changes even with Ignore Spacing off.

**Impact:** Accepted edits can be discarded in memory and copied source can be stale. This does not modify source files on disk.

**Fix:** Use exact scalar/code-unit equality for input preservation and cache invalidation, or pass an explicit completed-comparison revision into the view. Decide and document the desired normalization semantics for diff matching separately; preserving the accepted source must not depend on that choice.

**Regression checks:** Compare `Array(text.utf8)`, rather than String equality, after replacing composed text with decomposed text. Reload equivalent-looking file contents and verify both Copy Text and selected-text copying preserve the newly loaded units.

**Evidence:** Source trace plus [Swift's documented string equality semantics](https://docs.swift.org/swift-book/LanguageGuide/StringsAndCharacters.html#String-and-Character-Equality). The application reproduction was not executed here.

### R2 — P2: File/directory replacements cannot display the affected file

**Location:** [GitRepository.swift:137–155](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/DiffCore/GitRepository.swift#L137).

**Trigger:** Commit a regular file named `item`; in the next commit, replace it with a directory containing `item/child`, using unrelated contents to avoid rename detection.

**Problem:** Git reports deletion of `item` and addition of `item/child`. When comparing deleted `item`, the target-side `ls-tree` lookup returns the new directory with mode `040000`. The regular-blob guard rejects it with the symbolic-link/submodule error. The reverse transition has the same problem on the baseline side.

**Impact:** An ordinary deletion/addition caused by reorganizing a repository is listed but cannot be reviewed, and the explanation identifies the wrong cause.

**Fix:** Respect the change status when constructing comparison sides: an added file has an absent baseline, and a deleted file has an absent target. Alternatively, explicitly distinguish directory entries from unsupported file types. Preserve existing rejection of actual symlinks/submodules.

**Regression checks:** Add both file-to-directory and directory-to-file fixture commits. Verify the removed file compares against empty text and the added file compares from empty text, while nested changes remain selectable.

**Evidence executed:** In a temporary repository, the production Git arguments returned:
```text
diff-tree: D\0item\0A\0item/child\0
ls-tree HEAD -- item: 040000 tree <object-id>\titem\0
ls-tree HEAD^ -- item/child: <empty>
```
This confirms the Git input that enters the rejecting guard. The Swift function itself was not run.

### R3 — P2: Cancelling a Git task does not interrupt a blocked child process

**Location:** [GitRepository.swift:183–198](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/DiffCore/GitRepository.swift#L183); callers cancel detached workers in DiffDocument and RepositoryCommitPicker.

**Trigger:** A history query takes a long time without producing stdout, or a Git read stalls on slow storage. The user changes the query or leaves repository mode.

**Problem:** Cancellation is checked before the command and after each blocking read, but nothing connects task cancellation to the running Process. If `read(upToCount:)` or `waitUntilExit()` is blocked, the task cannot reach its next check. The defer that terminates Git also cannot run until control returns.

**Impact:** Superseded queries can leave Git processes and worker threads running. Generation checks protect displayed state, but do not stop the work. Repeated searches can accumulate obsolete commands.

**Fix:** Introduce a process runner with cancellation-aware process lifetime management, synchronized startup/termination, asynchronous output handling, and bounded shutdown. Consider an operation deadline as well. Ensure cancellation while launching and cancellation after completion are both safe.

**Regression check:** Inject a test child that stays alive without stdout. Cancel after startup and assert prompt worker completion and process exit; repeat to verify resources do not accumulate.

**Evidence:** Static control-flow finding. No stalled-process Swift test or platform timing measurement was executed.

### R4 — P3: Merge review does not identify its first-parent baseline

**Locations:** [DiffDocument.swift:48–49](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/MacDiff/DiffDocument.swift#L48), [ContentView.swift:126–144](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/MacDiff/ContentView.swift#L126), [README.md:83](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/README.md#L83).

**Trigger:** Select a merge commit.

**Problem:** Git comparison deliberately selects `commit.parents.first`, but the pane labels and help text remain only “Before” and “After”. The README says the first-parent choice is explicitly labelled, and the UI does not fulfill that promise.

**Impact:** A user cannot identify the baseline from the comparison header and may misinterpret a merge's displayed changes.

**Fix:** Include the baseline hash and “first parent” for merges; distinguish the empty baseline for initial commits. Keep the target commit identifiable too.

**Regression check:** Assert labels for ordinary, root, and merge commits. The existing first-parent Git test verifies contents, not this presentation.

**Evidence:** Direct source/documentation mismatch; no UI execution required to establish the constant labels.

### R5 — P3: About links to the wrong repository

**Location:** [AboutView.swift:37–39](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/MacDiff/AboutView.swift#L37).

The Repository row's label and URL both point to `stuartd/MacClipboardDiff`. In MacDiff, that sends users to a different application's source and issue tracker.

**Fix:** Change both to `stuartd/macdiff` and `https://github.com/stuartd/macdiff`.

**Verification:** Inspect the About panel and open its link.

## Performance and maintainability observations

These are recommendations or measurement gaps, not additional confirmed defects.

- **Full text layout runs synchronously on the UI thread.** In [SelectableDiffView.swift:202–228](https://github.com/stuartd/macdiff/blob/3a1e4936648c808ef5727f9894a518501d982096/Sources/MacDiff/SelectableDiffView.swift#L202), each width change resets paragraph attributes, lays out both full documents, measures every row, applies one paragraph style per row, and forces layout again. Visible-row drawing is efficient, but it does not bound this layout work. Measure initial display, live resize, and font changes at the 100,000-line limit and with long wrapped lines. The 10,000-line test checks correctness without a time/memory threshold. Depending on measurements, coalesce resize work, cache measurements, or move toward visible-region layout.
- **The repository tree is rebuilt in the view body.** PathNode.tree repeatedly splits paths and recursively groups them; fileCount recursively traverses descendants. Large change lists can make UI updates expensive. Cache a tree per snapshot/filter and store subtree counts if profiling shows this matters.
- **Unused comparison work remains.** longestLineCharacterCount scans both sides of every row, is published, and has tests, but has no production UI consumer now that the view wraps lines. GitComparison.isIdentical is calculated but discarded by DiffDocument. Remove unused state/work or use it intentionally for metadata-only change reporting.
- **Input validation runs on the main actor for pasted/edited text.** The byte bound limits worst-case size, but a grapheme scan of a multi-megabyte paste still runs before comparison scheduling. Measure this separately from background diff time.
- **No checked-in CI workflow was present.** The release script runs tests locally, which is useful; automated macOS build/test coverage on PRs would also exercise the AppKit and document tests that are conditionally compiled out on other platforms.
- **TextKit-specific validation remains.** Exercise accepted form-feed and Unicode paragraph-separator content, VoiceOver navigation, appearance changes, and repeated ClipDiff handoffs while an input editor is open. These paths were inspected but not verified in a macOS session.

## Security and release observations

Git is invoked with argument arrays, literal pathspecs, no external diff/textconv in change listing, and inherited GIT_* variables removed. Blob content is read by object ID. Those are useful protections against filename interpretation and accidental repository-context leakage. No confirmed shell-injection finding emerged from the reviewed call sites.

The release script requires a clean checkout, checks source stability after building, signs with hardened runtime, waits for acceptance, staples the app, and rechecks the extracted final archive. This review did not execute signing, notarization, Gatekeeper validation, or the universal build. Git stderr is redirected to a temporary file; reading only its first 16 KiB later does not limit how large that file can grow while a process runs.

## Validation record

| Check | Result |
| --- | --- |
| Inspect all production Swift, tests, package/plugin, plist, scripts, README | Completed at the pinned commit |
| Repository-specific AGENTS.md | None in the reviewed repository tree |
| Reproduce Git file/directory transition output | Completed in an isolated temporary repository |
| bash -n on all three shell scripts | Passed |
| Verify Swift canonical equality against official language documentation | Completed |
| swift test / Swift build | Not run: Swift is absent from this environment |
| macOS/AppKit UI tests and performance measurements | Not run: this environment is Linux |
| Signing/notarization/release packaging | Not run: requires macOS and signing credentials |

The existing test suite was read, not reported as passing. No source files were changed, and temporary Git fixtures were removed after use.
