import SwiftUI
import UIKit

/// Each visible automatic reader owns its own request; closing one cannot release another.
@MainActor final class ReaderWakeLockManager {
    static let shared = ReaderWakeLockManager()
    private var owners: Set<UUID> = []
    private let apply: (Bool) -> Void

    init(apply: ((Bool) -> Void)? = nil) {
        self.apply = apply ?? { UIApplication.shared.isIdleTimerDisabled = $0 }
    }
    func set(_ enabled: Bool, owner: UUID) {
        let wasEnabled = !owners.isEmpty
        if enabled { owners.insert(owner) } else { owners.remove(owner) }
        let isEnabled = !owners.isEmpty
        if isEnabled != wasEnabled { apply(isEnabled) }
    }
}

struct ReaderWakeLock: ViewModifier {
    let enabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { synchronize() }
            .onChange(of: enabled) { synchronize() }
            .onChange(of: scenePhase) { synchronize() }
            .onDisappear { ReaderWakeLockManager.shared.set(false, owner: owner) }
    }
    private func synchronize() {
        ReaderWakeLockManager.shared.set(enabled && scenePhase == .active, owner: owner)
    }
}
