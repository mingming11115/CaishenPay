# Watch attendance implementation plan

> Execute inline with test-driven-development and verification-before-completion.

**Goal:** The watch offers the same one-day attendance action as the iPhone.

**Architecture:** Reuse `PayStore.markToday`, the existing daily attendance engine,
durable watch outbox and phone acknowledgement protocol. Keep record correction,
settings and ledger editing on iPhone. Add a bordered `今日上班` action above overtime.

**Tech stack:** SwiftUI, WorkPayCore, WatchConnectivity; watchOS 10 / iOS 17.

**Scope:** Work in the existing checkout to include the user's current salary rules;
preserve unrelated local edits. No data migration, uninstall, commits or branch changes.

## Task 1: Enable watch attendance

- [x] Run `python3 Scripts/test_watch_attendance.py`; reproduce the phone-only rejection.
- [x] Permit creation in `Apps/Shared/PayStore.swift`, retaining the watch edit restriction.
- [x] Add the daily attendance button in `Apps/Watch/CaishenWatchApp.swift`, disabled when recorded.
- [x] Update README and the shared store contract to describe watch attendance.
- [x] Pass the watch store regression checks and the complete WorkPayCore suite.
- [x] Build watch and phone targets; verify the watch UI.
- [x] Overwrite-install the signed watch build and verify it in the watch application list.

## Review focus

Duplicate taps cannot create another attendance record. Offline records survive disk
reload and incoming phone snapshots until exact acknowledgement. Attendance must not
interrupt overtime. An unconfigured watch cannot record attendance. Historical record
and salary edits remain restricted to the phone.

## Verification evidence

- Regression reproduced before the fix: watch store rejected daily attendance with
  `请在 iPhone 记录正常出勤`.
- After the fix: 7 watch store checks passed; all 53 WorkPayCore tests passed.
- Signed arm64_32 watch build and combined phone/watch simulator builds exited 0.
- 40mm watch simulator screenshot shows `今日上班` beneath attendance status, with
  checkmark and disabled appearance after an attendance record is present.
- Independent review found no actionable issues in the scoped implementation.
- After the user reconnected the paired iPhone, the signed arm64_32 update was
  installed on watch `00008301-0892F4D93610202E`. The installation reached 100%,
  exited 0, and the post-install lookup returned `com.caishen.jixin.watchkitapp`
  version 1.0.0 (build 1). No uninstall or data clearing was performed.
