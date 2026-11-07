#if DEBUG
import SwiftUI
import UIKit

struct ReaderIdleVerificationStatus: View {
    let id: String
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            Text(UIApplication.shared.isIdleTimerDisabled ? "awake" : "normal")
                .font(.system(size: 8)).accessibilityIdentifier(id)
        }.allowsHitTesting(false)
    }
}

@MainActor enum ReaderWakeVerification {
    static func run() {
        var checks: [[String: Any]] = []
        func check(_ value: Bool, _ title: String) { checks.append(["passed": value, "title": title]) }
        var states: [Bool] = []
        let manager = ReaderWakeLockManager(apply: { states.append($0) })
        let a = UUID(), b = UUID()
        manager.set(false, owner: a)
        check(states.isEmpty, "a manual reader does not write the idle-timer state")
        manager.set(true, owner: a)
        check(states == [true], "first automatic reader requests awake")
        manager.set(true, owner: a)
        check(states == [true], "repeated appear/update does not duplicate a request")
        manager.set(true, owner: b)
        manager.set(false, owner: a)
        check(states == [true], "closing an old reader keeps its replacement awake")
        manager.set(false, owner: a)
        manager.set(false, owner: UUID())
        check(states == [true], "duplicate or unknown teardown cannot release another reader")
        manager.set(false, owner: b)
        check(states == [true, false], "final reader stop restores normal idle behavior")
        manager.set(true, owner: b)
        manager.set(false, owner: b)
        check(states == [true, false, true, false], "a returning foreground reader can acquire and release again")
        let owner = UUID()
        ReaderWakeLockManager.shared.set(true, owner: owner)
        check(UIApplication.shared.isIdleTimerDisabled, "real UIApplication idle timer is disabled")
        ReaderWakeLockManager.shared.set(false, owner: owner)
        check(!UIApplication.shared.isIdleTimerDisabled, "real UIApplication idle timer is restored")
        let report: [String: Any] = ["success": checks.allSatisfy { $0["passed"] as? Bool == true }, "checks": checks]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: FileManager.default.temporaryDirectory.appending(path: "LuoyeReaderWakeVerification.json"), options: .atomic) }
    }
}
#endif
