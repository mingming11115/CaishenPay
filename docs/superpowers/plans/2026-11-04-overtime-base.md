# Independent Overtime Base Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Allow a separate monthly base for overtime while retaining ordinary salary and historical earnings.

**Architecture:** Add an optional overtime base to the existing Codable settings snapshot. Use a separate derived overtime rate in both engine consumers; expose it through the existing phone settings and record editor. Watch uses the shared model and engine.

**Tech Stack:** Swift 5, SwiftUI, Foundation Decimal, XCTest; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-11-04-overtime-base-design.md`

## Global Constraints

- Keep existing monthly workday conversion, historical snapshots and schema version 1.
- Missing overtime base follows monthly salary; zero is an explicit valid base.
- Preserve pre-existing Xcode project and scheme edits; reuse the current checkout.
- Implement in this session; leave changes available for review without committing or publishing.

## Review Focus

- Legacy JSON must preserve original earnings and remain writable.
- Separate bases must affect all overtime types and monthly estimates, never normal earnings.
- Invalid and overflowing amounts must be rejected before storing.
- Splitting and persistence must retain each record's original base after rule changes.
- Settings must restore the switch and custom amount, and switching back must follow later salary changes.

### Task 1: Model and calculation

**Files:** `Models.swift`, `PayEngine.swift`, new `OvertimeBaseTests.swift` under the existing WorkPayCore package.

**Interfaces:** Add `overtimeMonthlyBase: Decimal? = nil` as a trailing initializer argument and `overtimeHourlyRate: Decimal`. Keep `hourlyRate` for normal hourly records.

- [x] Write wire-format fixtures that exercise separate bases before the model supports them; assert literal normal, overtime and monthly amounts, persistence, splitting, legacy defaults and validation.
- [x] Run `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --package-path Packages/WorkPayCore --filter OvertimeBaseTests`; expect behavioral failures because the new key is ignored.
- [x] Add the optional base, rate derivation and validation; select the overtime rate in daily and monthly calculations.
- [x] Run the full package test command; expect zero failures.

### Task 2: Settings and record details

**Files:** `Apps/iOS/SettingsView.swift`, `Apps/iOS/RecordsView.swift`, `README.md`, `INTERFACES.md`.

**Interfaces:** Consume Task 1's optional base and overtime rate through the existing snapshot and sync paths.

- [x] Add the default-on follow-salary toggle, conditional numeric input, preview and save/load handling; show the correct base and rate for overtime records.
- [x] Update user and API documentation.
- [x] Build `CaishenPay` and `CaishenWatch` sequentially for their generic simulator destinations with signing disabled; expect exit 0. Inspect the settings screen in the simulator when available.
- [x] Review the complete diff and record verification results here.

## Verification results

- RED: 9 new tests executed; 8 failed with 16 expected assertions because the separate base was ignored. Legacy fallback passed.
- GREEN: full WorkPayCore suite, 53 tests, zero failures.
- Both generic simulator builds succeeded. Logs: `/private/tmp/caishen-overtime-ios-build.log`, `/private/tmp/caishen-overtime-watch-build.log`.
- iPhone 18 Pro / iOS 27.2: onboarding defaults to follow salary; salary 10,000 gives normal daily income 476.19 for 21 workdays. Custom base 5,000 gives overtime hourly rate 29.76. Saving and reopening settings restores the disabled switch and custom amount. Changing salary to 12,000 leaves custom overtime rate unchanged; enabling follow salary updates the preview to 71.43. Returned the draft to salary 10,000 / custom base 5,000.
- Independent read-only review found no actionable defects. Scope decision: both phone and watch must use the updated app to interpret the new field; compatibility preserves old data rather than adding new behavior to older binaries. Actual paired-device transport was not exercised; shared model/engine and both builds were verified.
- No commits or releases created; existing Xcode project/scheme changes were preserved.
