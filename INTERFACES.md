# Shared API contract

All types below are public in module `WorkPayCore`; Codable/Equatable/Sendable where applicable. Agents may add helpers, but preserve this API or coordinate changes first. Public models need public memberwise initializers with sensible defaults for ID and modifiedAt.

```swift
enum WorkKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case regular, weekday, weekend, holiday
  var id: String { get }; var title: String { get }
}
struct PaySettings: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var effectiveFrom: Date
  var monthlyBase: Decimal
  var paidDays: Decimal // default 21.75, >0
  var dailyHours: Decimal // default 8, >0
  var weekdayMultiplier: Decimal // 1.5
  var weekendMultiplier: Decimal // 2
  var holidayMultiplier: Decimal // 3
  var startMinute: Int // 540
  var endMinute: Int // 1080; <= start means overnight
  var breakStartMinute: Int // 720
  var breakEndMinute: Int // 780; equal means no unpaid break
  var timeZoneID: String // Asia/Shanghai default
  var modifiedAt: Date
  var hourlyRate: Decimal { get }
  func multiplier(for kind: WorkKind) -> Decimal
  func validate() throws
}
struct WorkEntry: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var start: Date
  var end: Date? // nil: active, dates must be ordered
  var kind: WorkKind
  var settings: PaySettings // immutable historical snapshot except intentional record edits
  var deviceID: String
  var modifiedAt: Date
  var deletedAt: Date?
  var needsTypeReview: Bool // midnight-split overtime may need day-type confirmation
  var regularShiftAnchor: Date? // default nil; original regular shift's scheduled start, preserved by split pieces
}
struct SalaryPayment: Codable, Equatable, Identifiable, Sendable {
  var id: UUID; var amountCents: Int64; var paidAt: Date; var note: String
}
struct SalaryMonth: Codable, Equatable, Identifiable, Sendable {
  var id: String // yyyy-MM
  var expectedCents: Int64
  var payments: [SalaryPayment]
  var note: String
  var modifiedAt: Date
  var receivedCents: Int64 { get }
  var outstandingCents: Int64 { get }
  var overpaidCents: Int64 { get }
}
struct PayData: Codable, Equatable, Sendable {
  var schemaVersion: Int // 1
  var settings: [PaySettings]
  var entries: [WorkEntry]
  var salaryMonths: [SalaryMonth]
  var hasCompletedSetup: Bool
  init() // empty, no real financial sample data
}
struct DaySummary: Equatable, Sendable {
  var regularSeconds: TimeInterval
  var overtimeSeconds: TimeInterval
  var regularCents: Int64
  var overtimeCents: Int64
  var totalSeconds: TimeInterval { get }
  var totalCents: Int64 { get }
}
enum PayEngine {
  static func cents(_ amount: Decimal) -> Int64
  static func amount(cents: Int64) -> Decimal
  static func settings(on date: Date, in rules: [PaySettings]) -> PaySettings?
  static func summary(on day: Date, asOf now: Date, entries: [WorkEntry], calendar: Calendar) -> DaySummary
  static func validate(_ entry: WorkEntry, among entries: [WorkEntry], asOf now: Date) throws
  static func splitAtMidnight(_ entry: WorkEntry, calendar: Calendar) -> [WorkEntry]
  static func mergedEntries(local: [WorkEntry], incoming: [WorkEntry]) -> [WorkEntry]
  static func conflictingIDs(in entries: [WorkEntry], asOf now: Date) -> Set<UUID>
  static func monthlyEstimate(on date: Date, settings: [PaySettings], entries: [WorkEntry], asOf now: Date, calendar: Calendar) -> Int64
}
```

`summary` excludes deleted records and all conflicting record IDs; counts regular time only inside each snapshotted shift, excluding unpaid break; clips every interval to the requested day and `now`. Overtime is continuous except separately recorded breaks (pause creates a new entry). An ongoing entry survives process exit because `start` and `end` drive computation. Splitting preserves historical snapshots; first piece keeps original ID, later pieces receive stable IDs if possible and `needsTypeReview` for overtime. Sync ignores older modifiedAt; tie resolution deterministic and deletions win ties. Store validates finite/capped amounts and reasonable record dates before accepting mutations.

Regular records belong to one original shift, including its overnight continuation. A forgotten running timer never starts earning the next day's normal pay. `regularShiftAnchor` is optional for compatibility with older JSON; nil infers the original shift from `start`, while midnight splitting stamps the same scheduled-start anchor on every regular piece. Intentional manual changes to a record's start or kind should clear its anchor so the corrected interval can select its intended shift while retaining the historical `settings` snapshot.

## Shared app store (module-local, not package)

The store/sync agent owns `@MainActor final class PayStore: ObservableObject` in `Apps/Shared/`:

```swift
@Published private(set) var data: PayData
@Published var errorMessage: String?
@Published private(set) var syncStatus: String
@Published private(set) var lastSync: Date?
var activeEntry: WorkEntry? { get }
var currentSettings: PaySettings? { get }
var conflictIDs: Set<UUID> { get }
var deviceID: String { get }
init(demo: Bool = false)
func summary(on date: Date, now: Date = Date()) -> DaySummary
func begin(_ kind: WorkKind, at date: Date = Date())
func stop(at date: Date = Date())
func saveSettings(_ settings: PaySettings) // errors to errorMessage, finishes existing record before rule change if needed
func saveEntry(_ entry: WorkEntry)
func deleteEntry(_ id: UUID)
func saveMonth(_ month: SalaryMonth)
func month(_ id: String) -> SalaryMonth? // saved only
func estimatedMonth(_ date: Date) -> Int64
func refreshSync()
```

iPhone UI may use `onChange`-safe success checks via `errorMessage == nil`; store methods clear old errors before action and set descriptive Chinese errors on failure. It must not silently overwrite corrupted storage or lose unsent Watch edits. Watch has no settings or ledger editing. Shared theme is owned by the main agent and provides `enum PayTheme` with `static let ink, muted, cinnabar: Color`, `static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font`; `JiangnanArtwork(height: CGFloat)` for a cropped native Image; both app targets bundle `jiangnan-reference.jpg`.
