import SwiftUI
import UniformTypeIdentifiers

struct MangaReadingBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        _ = try MangaReadingSnapshot.decode(data)
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct MangaDataSettingsView: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(MangaSyncService.self) private var sync
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var exporting = false
    @State private var importing = false
    @State private var document: MangaReadingBackup?
    @State private var notice: String?
    var body: some View {
        LuoyeSettingsPage(title: "备份与同步") {
            LuoyeSettingsSection(title: "阅读备份") {
                Text("备份在线收藏、稍后阅读、历史与阅读进度。")
                    .font(.serif(12)).foregroundStyle(.secondary)
                LuoyeSettingsAction(title: "导出阅读备份", icon: "square.and.arrow.up") {
                    do { document = MangaReadingBackup(data: try JSONEncoder().encode(library.readingSnapshot())); exporting = true }
                    catch { notice = error.localizedDescription }
                }
                LuoyeSettingsAction(title: "合并阅读备份", icon: "square.and.arrow.down") { importing = true }
            }
            LuoyeSettingsSection(title: "WebDAV", footnote: "同步收藏、历史和阅读进度，漫画文件保存在本机。") {
                TextField("HTTPS 目录地址", text: $server).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).luoyeSettingsInput()
                TextField("用户名", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().luoyeSettingsInput()
                SecureField("密码／应用密码", text: $password).luoyeSettingsInput()
                LuoyeSettingsAction(title: "保存连接配置", icon: "checkmark", prominent: true) {
                    do { try sync.saveConfiguration(server: server, username: username, password: password); password = ""; notice = nil }
                    catch { notice = error.localizedDescription }
                }.disabled(sync.busy)
                LuoyeSettingsAction(title: "测试连接", icon: "network") { Task { await sync.testConnection() } }.disabled(sync.busy || !sync.configured)
                LuoyeSettingsAction(title: "立即同步阅读数据", icon: "arrow.triangle.2.circlepath") { Task { await sync.synchronize() } }.disabled(sync.busy || !sync.configured)
                Toggle("自动同步阅读数据", isOn: Binding(get: { sync.autoSync }, set: { sync.autoSync = $0 }))
                    .disabled(!sync.configured)
                if let date = sync.lastSync { Text("上次同步：" + date.formatted(date: .abbreviated, time: .shortened)).font(.serif(11)).foregroundStyle(.secondary) }
                if sync.busy { ProgressView() }
                if let message = sync.message { LuoyeNotice(message: message) }
            }
            if let notice { LuoyeNotice(message: notice) }
        }
        .task { server = sync.server; username = sync.username }
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Luoye-Manga-Reading") { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let snapshot = try MangaReadingSnapshot.decode(Data(contentsOf: url))
                try library.mergeReadingSnapshot(snapshot)
                notice = "阅读备份已合并"
            } catch { notice = error.localizedDescription }
        }
    }
}
