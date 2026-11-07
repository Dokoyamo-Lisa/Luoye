import SwiftUI

/// The same paper surface, margins and typography as the main settings page.
struct LuoyeSettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) { content }
                .luoyeContentMargins(top: 20, maximumWidth: 820)
        }
        .font(.serif(14)).foregroundStyle(Color.ink).tint(Color.accent)
        .background(Color.paper).scrollDismissesKeyboard(.interactively)
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { Text(title).font(.serif(17, medium: true)).foregroundStyle(Color.ink) } }
    }
}

struct LuoyeSettingsSection<Content: View>: View {
    let title: String
    var detail = ""
    var footnote = ""
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LuoyeSectionHeader(title: title, trailing: detail)
            LuoyePanel {
                VStack(alignment: .leading, spacing: 18) { content }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(17)
            }
            if !footnote.isEmpty {
                Text(footnote).font(.serif(12)).foregroundStyle(.secondary).lineSpacing(3).padding(.horizontal, 3)
            }
        }
    }
}

struct LuoyeSettingsAction: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let icon: String
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).frame(maxWidth: .infinity, minHeight: 44) }
            .buttonStyle(LuoyeActionStyle(prominent: prominent)).opacity(isEnabled ? 1 : 0.4)
    }
}

extension View {
    func luoyeSettingsInput() -> some View {
        self.font(.serif(14)).textFieldStyle(.plain)
            .padding(.horizontal, 13).frame(minHeight: 48)
            .background(Color.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
