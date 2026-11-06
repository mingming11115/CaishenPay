#!/usr/bin/env python3
"""Exercise the real PayStore watch branches on macOS with isolated disk state.

Only the platform conditions and storage path are adapted; WatchConnectivity is
replaced at its transport boundary so offline snapshots and acknowledgements can
be delivered deterministically without touching a paired device or real records.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ENV = {**os.environ, "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}

HARNESS = r'''
import Foundation
import WorkPayCore

@MainActor
final class ConnectivityService {
    static var latest: ConnectivityService?
    var onReceive: ((PaySyncPacket) -> Void)?
    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    init() { Self.latest = self }
    func activate() {}
    func send(_ packet: PaySyncPacket) {}
}

struct DiskFixture: Codable {
    var version = 1
    var deviceID = "watch-test"
    var data: PayData
    var pendingEntries: [WorkEntry] = []
    var receivedWatchEntries: [WorkEntry] = []
    var phoneRevision: Int64 = 0
    var phoneDeviceID: String?
    var phoneData: PayData?
    var lastSync: Date?
}

struct TestFailure: Error { let message: String }

@main
struct WatchAttendanceCheck {
    @MainActor
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(message: message) }
    }

    @MainActor
    static func main() throws {
        let now = Date()
        let rule = PaySettings(effectiveFrom: now.addingTimeInterval(-172800), monthlyBase: 22000)
        var original = PayData()
        original.settings = [rule]
        original.hasCompletedSetup = true
        let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAISHENPAY_TEST_STORE"]!)
        try JSONEncoder().encode(DiskFixture(data: original)).write(to: file)
        let store = PayStore()
        let link = ConnectivityService.latest!

        // Restoring the phone-only guard must fail here, before any UI assertions.
        store.markToday(at: now)
        try require(store.errorMessage == nil, "Watch must record today's attendance; got: \(store.errorMessage ?? "none")")
        try require(store.data.entries.count == 1, "One tap must create one attendance record")
        let attendance = store.data.entries[0]
        try require(attendance.isAttendance && attendance.end == attendance.start, "Attendance must not start a timer")
        try require(attendance.deviceID == "watch-test", "Attendance must retain watch ownership")
        try require(store.attendanceStatusToday == .recorded, "Attendance status must update immediately")
        try require(store.activeEntry == nil && store.pendingCount == 1, "Offline attendance must be queued without a running timer")
        try require(store.summary(on: now, now: now).regularCents > 0, "A completed day must earn normal pay immediately")
        print("PASS watch records a day without starting a timer")

        store.markToday(at: now)
        try require(store.errorMessage != nil, "A repeat tap must reject duplicate attendance")
        try require(store.data.entries == [attendance] && store.pendingCount == 1, "A repeat tap must not add income or pending entries")
        print("PASS duplicate attendance is rejected")

        let restored = PayStore()
        try require(restored.data.entries == [attendance] && restored.pendingCount == 1, "Offline attendance must survive process restart")
        print("PASS offline attendance survives disk reload")

        link.onReceive?(PaySyncPacket(source: .phone, deviceID: "phone-test", revision: 1,
                                     data: original, entries: [], acknowledged: []))
        try require(store.data.entries == [attendance] && store.pendingCount == 1, "An unacknowledged phone snapshot must preserve watch attendance")
        var phone = original
        phone.entries = [attendance]
        link.onReceive?(PaySyncPacket(source: .phone, deviceID: "phone-test", revision: 2,
                                     data: phone, entries: [], acknowledged: [attendance]))
        try require(store.data.entries == [attendance] && store.pendingCount == 0, "Exact phone acknowledgement must clear the outbox without duplicating attendance")
        print("PASS phone snapshot and acknowledgement preserve one attendance record")

        store.saveAttendance(on: now, replacing: attendance)
        try require(store.errorMessage != nil && store.data.entries == [attendance], "Watch must continue to reject historical record edits")
        store.saveSettings(PaySettings(effectiveFrom: now, monthlyBase: 99999))
        try require(store.errorMessage != nil && store.data.settings == [rule], "Watch must continue to reject salary setting edits")
        print("PASS phone-only editing restrictions remain enforced")

        try JSONEncoder().encode(DiskFixture(data: original)).write(to: file)
        let overtimeStore = PayStore()
        overtimeStore.begin(.weekday, at: now.addingTimeInterval(-60))
        let running = overtimeStore.activeEntry
        try require(running != nil, "Fixture must have a running overtime timer")
        overtimeStore.markToday(at: now)
        try require(overtimeStore.errorMessage == nil, "Attendance must be recordable during overtime")
        try require(overtimeStore.activeEntry == running, "Attendance must not stop or replace an overtime timer")
        try require(overtimeStore.pendingCount == 2 && overtimeStore.data.entries.filter(\.isAttendance).count == 1,
                    "Attendance and overtime must each remain queued")
        print("PASS attendance preserves ongoing overtime")

        try JSONEncoder().encode(DiskFixture(data: PayData())).write(to: file)
        let unconfigured = PayStore()
        unconfigured.markToday(at: now)
        try require(unconfigured.errorMessage != nil && unconfigured.data.entries.isEmpty,
                    "Watch must require synced salary settings before attendance")
        print("PASS setup is required before attendance")
    }
}
'''


def main():
    with tempfile.TemporaryDirectory(prefix="caishenpay-watch-attendance-") as directory:
        scratch = Path(directory)
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=ENV, text=True).strip()
        platform = ["-sdk", sdk, "-target", "arm64-apple-macosx26.0", "-module-cache-path", str(scratch / "cache")]
        core = ROOT / "Packages/WorkPayCore/Sources/WorkPayCore"
        subprocess.run([
            "xcrun", "swiftc", *platform, "-swift-version", "5", "-module-name", "WorkPayCore",
            "-emit-library", "-emit-module", "-emit-module-path", str(scratch / "WorkPayCore.swiftmodule"),
            "-o", str(scratch / "libWorkPayCore.dylib"), *map(str, sorted(core.glob("*.swift"))),
        ], env=ENV, check=True)
        source = (ROOT / "Apps/Shared/PayStore.swift").read_text()
        location = '''let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CaishenPay", isDirectory: true)'''
        assert source.count(location) == 1
        source = source.replace(location,
            'let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CAISHENPAY_TEST_STORE"]!).deletingLastPathComponent()')
        source = source.replace("#if os(watchOS)", "#if true").replace("#if os(iOS)", "#if false")
        (scratch / "PayStore.swift").write_text(source)
        connectivity = (ROOT / "Apps/Shared/ConnectivityService.swift").read_text()
        packet = connectivity[connectivity.index("struct PaySyncPacket:"):connectivity.index("\n@MainActor")]
        (scratch / "Harness.swift").write_text("import Foundation\nimport WorkPayCore\n" + packet + HARNESS)
        executable = scratch / "watch-attendance-tests"
        subprocess.run([
            "xcrun", "swiftc", *platform, "-swift-version", "5", "-parse-as-library", "-I", directory,
            "-L", directory, "-lWorkPayCore", "-Xlinker", "-rpath", "-Xlinker", directory,
            str(scratch / "PayStore.swift"), str(scratch / "Harness.swift"), "-o", str(executable),
        ], env=ENV, check=True)
        subprocess.run([str(executable)], env={**ENV, "CAISHENPAY_TEST_STORE": str(scratch / "pay-state-v1.json")}, check=True)


if __name__ == "__main__":
    main()
