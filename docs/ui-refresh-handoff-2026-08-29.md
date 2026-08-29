# UI refresh handoff — 2026-08-29

> **Historical snapshot / superseded.** This file preserves the state before the 0.2.0 closeout. The UI work was later committed in `26da9aa`, the window-title reversal in `ccc3431`, and the current reliability-v2 status is recorded in `docs/handoff-2026-08-30-reliability-v2-closeout.md`.

## Safe stopping point

- Current branch: `codex/record-to-text-reliability-v2`.
- The worktree was already dirty before this UI work and still contains many unrelated changes. Do not reset or revert them.
- No commit, push, release, or `/Applications` replacement was performed in this run.
- `scripts/run-checks.sh` passed after the UI changes: 25 Python tests, 70 Swift executable self-tests, 10 mock pipeline scenarios, Swift builds, App bundle build, and `git diff --check`.
- Full XCTest is still unavailable in the current Command Line Tools environment (`no such module 'XCTest'`).

## Completed in this run

### Cloud segment safety and recovery

- Explicit Google safety-policy blocks are isolated to the affected segment instead of stopping all later segments.
- Later segments continue, and the final transcript marks the missing segment and time range.
- Completed cloud segments are preserved in a checkpoint.
- A completed-with-gaps job can show `重送未完成片段`; completed segments are reused and only unfinished segments are submitted again.
- Non-safety failures such as authentication, quota, HTTP 503, and unknown `OTHER` blocks remain fail-closed.

### Progress and activity feedback

- Cloud progress is presented as completed segments divided by total segments.
- A segment fills its share only after it finishes or is explicitly recorded as a safety gap.
- Post-processing keeps the bar full instead of visually going backward.
- The separate breathing dot was removed.
- The completed portion of the progress bar now uses a subtle blue-to-cyan breathing gradient; its width never changes with the animation.
- At 0%, a small starting highlight indicates that work is active without claiming segment progress.
- Reduce Motion changes the breathing effect to a static gradient.

### Main-window UI items 1, 2, and 3

- The large standalone terminology card was removed from the top-level stack.
- Transcription settings now appear as a one-line summary inside the intake card and can expand to edit the project glossary, temporary terms, and prompt preview.
- The summary remains above file intake because settings are captured into the job Snapshot when files are added.
- The intake/drop zone is now the main visual area after the title.
- Active job cards use a restrained accent tint, accent border, and a thin leading status line; inactive cards use a quieter border.
- The duplicated `開始轉文字` button was removed from the intake card. The queue header is the only primary start action.

## Not completed or not verified

- Final visual verification of the newest layout is not complete.
- macOS has multiple App copies with the same bundle identifier (`com.specifique.record-to-text`). Computer Use repeatedly reopened a stale-looking UI even after the new `dist` build was launched.
- The current `dist/record-to-text.app` executable is newly built and has a different SHA-256 from both `/Applications/record-to-text.app` and `/Applications/record-to-text 2.app`, but the exact process-to-bundle mapping was not resolved before stopping.
- The newest collapsed transcription-settings row has not been visually confirmed in the running App.
- The active-card tint and leading line have not been visually confirmed with a real active job.
- Narrow-window layout, dark mode, High Contrast, and Reduce Motion have not been visually reviewed.
- No real Google API transcription was run after these changes.
- No installer, signed release, notarization, or production deployment was performed.

## Follow-up 2026-08-29 (Grok)

- Confirmed stale-bundle problem: `dist`, `/Applications/record-to-text.app`, and `/Applications/record-to-text 2.app` previously had three different SHA-256 hashes; two copies were running at once.
- Window title was temporarily changed to include marketing version and build. This was later reversed by `ccc3431`; the current title is the plain product name `record-to-text`.
- Quit extra copies, launched the rebuilt `dist` App, visually confirmed collapsed main window: `轉錄設定` disclosure (not the old standalone `專有名詞` card), drop zone is the main intake, queue has no duplicate start button in the intake card.
- Replaced `/Applications/record-to-text.app` so it matches `dist` (`eb982766…`). Left `/Applications/record-to-text 2.app` untouched.
- Still not visually reviewed: expanded 轉錄設定, a real active cloud job tint/leading line, narrow window, dark mode, High Contrast, Reduce Motion, or a live Google API run.
- At this snapshot there was still no commit or push; the UI work was subsequently committed and pushed in `26da9aa` and `ccc3431`.

## Follow-up 2026-08-29/30 (0.2.0)

- `/Applications/record-to-text.app` and `dist/record-to-text.app` were confirmed as 0.2.0 (1) with matching executable hashes at the time of installation review.
- The installed 0.2.0 UI was visually checked in dark mode with both collapsed and expanded `轉錄設定` states.
- The window is intentionally constrained to a 760-point minimum width; that minimum-width layout showed no obvious clipping in the reviewed state.
- The window title is the plain `record-to-text`; version/build remain available in Settings and copied debug information.
- Still unverified: a real active cloud job card/progress transition, High Contrast, Reduce Motion, and a live Google API regression.

## Suggested next steps

1. Run a real multi-segment cloud job and verify the active card, current-segment estimate, 90% cap, and completed-segment transition.
2. Review High Contrast and Reduce Motion without changing the production progress contract.
3. Keep using exact bundle paths when multiple copies share `com.specifique.record-to-text`; do not re-add version text to the window title as an identification workaround.
