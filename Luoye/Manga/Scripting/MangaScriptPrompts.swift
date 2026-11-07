import SwiftUI

@MainActor @Observable
final class MangaScriptPrompts {
    static let shared = MangaScriptPrompts()
    struct Prompt: Identifiable {
        let id = UUID()
        let title: String
        let content: String
        let kind: String
        let options: [String]
        let url: URL?
        let reply: @Sendable (String) -> Void
    }
    var current: Prompt?
    var notice: String?
    private var waiting: [Prompt] = []

    func receive(_ raw: String, reply: @escaping @Sendable (String) -> Void) {
        let message = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        let kind = message["function"] as? String ?? ""
        if kind == "showMessage" {
            notice = message["message"] as? String
            let value = notice
            Task { try? await Task.sleep(for: .seconds(4)); if notice == value { notice = nil } }
            reply("{\"value\":null}")
            return
        }
        let prompt = Prompt(title: message["title"] as? String ?? "漫画源提示", content: message["content"] as? String ?? "", kind: kind,
                            options: message["options"] as? [String] ?? [], url: (message["url"] as? String).flatMap(URL.init(string:)), reply: reply)
        if current == nil { current = prompt } else { waiting.append(prompt) }
    }
    func complete(_ id: UUID, value: Any?) {
        guard let prompt = current, prompt.id == id else { return }
        let data = try? JSONSerialization.data(withJSONObject: ["value":value ?? NSNull()])
        prompt.reply(data.map { String(decoding: $0, as: UTF8.self) } ?? "{\"value\":null}")
        current = nil
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            Task { try? await Task.sleep(for: .milliseconds(300)); current = next }
        }
    }
}

struct MangaScriptPromptHost: ViewModifier {
    @State private var prompts = MangaScriptPrompts.shared
    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let notice = prompts.notice {
                    Text(notice).font(.serif(13)).padding(14)
                        .background(Color.paper, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(radius: 6).padding(.top, 8)
                }
            }
            .sheet(item: Binding(get: { prompts.current }, set: { value in
                if value == nil, let current = prompts.current { prompts.complete(current.id, value: nil) }
            })) { prompt in MangaScriptPromptView(prompt: prompt) }
    }
}

private struct MangaScriptPromptView: View {
    let prompt: MangaScriptPrompts.Prompt
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                if !prompt.content.isEmpty { Text(prompt.content).font(.serif(14)) }
                if prompt.kind == "showInputDialog" {
                    TextField("请输入", text: $text).textInputAutocapitalization(.never)
                    Button("确定") { finish(text) }
                } else if prompt.kind == "launchUrl" {
                    if let url = prompt.url, ["https","http"].contains(url.scheme ?? "") {
                        Text(url.host ?? "网页")
                        NavigationLink("在落叶内打开") { MangaSourcePageView(url: url) }
                        Button("完成") { finish(nil) }
                    }
                } else {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, title in
                        Button(title) { finish(index) }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Color.paper)
            .navigationTitle(prompt.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { finish(nil) } } }
        }
    }
    private func finish(_ value: Any?) { MangaScriptPrompts.shared.complete(prompt.id, value: value) }
}
