import Foundation
import JavaScriptCore
import SwiftSoup
import CryptoKit
import CommonCrypto

/// All JavaScript and DOM objects stay on one serial queue, separate from UI work.
final class MangaScriptRuntime: @unchecked Sendable {
    enum RuntimeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
    private let queue = DispatchQueue(label: "app.luoye.manga.script", qos: .userInitiated)
    private var context: JSContext!
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    let identifier = UUID()
    let scriptFingerprint: String
    private var images: [Int: MangaScriptBitmap] = [:]
    private var imageSequence = 0
    private var documents: [Int: Document] = [:]
    private var nodes: [Int: [Int: Node]] = [:]
    private var nodeSequence = 0
    private var state: [String: Any] = [:]
    private var savedStateData: Data?
    private var cookies: [HTTPCookie] = []
    private let storageKey: String
    private let stateURL: URL
    private let resourcesDirectory: URL?
    private let script: String
    private let session: URLSession
    private let redirectDelegate = MangaSourceRedirectDelegate()
    private let uiHandler: (@Sendable (String, @escaping @Sendable (String) -> Void) -> Void)?
    private var uiWaitCount = 0
    private var initialized = false
    private var exception: String?

    init(script: String, storageKey: String, resourcesDirectory: URL? = nil, uiHandler: (@Sendable (String, @escaping @Sendable (String) -> Void) -> Void)? = nil) {
        self.uiHandler = uiHandler
        self.resourcesDirectory = resourcesDirectory
        self.storageKey = storageKey
        self.script = script
        scriptFingerprint = SHA256.hash(data: Data(script.utf8)).map { String(format: "%02x", $0) }.joined()
        let key = SHA256.hash(data: Data(storageKey.utf8)).map { String(format: "%02x", $0) }.joined()
        stateURL = MangaLibrary.directory.appending(path: "source-\(key).json")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config, delegate: redirectDelegate, delegateQueue: nil)
    }

    func call(_ path: String, arguments: [Any] = []) async throws -> Data {
        let args = try JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed])
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.initialize()
                    let id = UUID().uuidString
                    self.pending[id] = continuation
                    self.context.objectForKeyedSubscript("__invokeNativeSource")?.call(withArguments: [id, path, String(decoding: args, as: UTF8.self)])
                    self.queue.asyncAfter(deadline: .now() + 45) {
                        self.expire(id)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func metadata() async throws -> Data { try await call("__metadata") }

    func importCookies(_ values: [HTTPCookie]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    values.forEach { self.storeCookie($0) }
                    try self.saveState()
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func expire(_ id: String) {
        if uiWaitCount > 0 { queue.asyncAfter(deadline: .now() + 45) { self.expire(id) }; return }
        pending.removeValue(forKey: id)?.resume(throwing: RuntimeError.message("漫画源响应超时"))
    }

    private func initialize() throws {
        guard !initialized else { return }
        exception = nil
        context = JSContext()
        context.exceptionHandler = { [weak self] _, value in self?.exception = value?.toString() }
        if FileManager.default.fileExists(atPath: stateURL.path), let saved = try JSONSerialization.jsonObject(with: MangaSecrets.loadFile(stateURL, namespace: storageKey)) as? [String: Any] {
            state = saved
            cookies = (saved["__cookies"] as? [[String: Any]] ?? []).compactMap { value in
                guard let name = value["name"] as? String, let text = value["value"] as? String, let domain = value["domain"] as? String else { return nil }
                var properties: [HTTPCookiePropertyKey: Any] = [.name:name,.value:text,.domain:domain,.path:value["path"] as? String ?? "/",.secure:(value["secure"] as? Bool ?? false) ? "TRUE" : "FALSE"]
                if let expires = value["expires"] as? Double { properties[.expires] = Date(timeIntervalSince1970: expires) }
                return HTTPCookie(properties: properties)
            }
        }
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let raw = try Data(contentsOf: stateURL)
            if !raw.starts(with: Data("MGS1".utf8)) { try saveState() }
            else { savedStateData = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) }
        }
        let sync: @convention(block) (String) -> String = { [weak self] input in
            guard let self else { return "{\"error\":\"Runtime closed\"}" }
            do { return Self.response(try self.handle(Self.object(input))) }
            catch { return Self.failure(error.localizedDescription) }
        }
        let async: @convention(block) (String, String) -> Void = { [weak self] input, id in
            guard let self else { return }
            self.handleAsync(input, id: id)
        }
        let finish: @convention(block) (String, String) -> Void = { [weak self] id, response in
            guard let self, let continuation = self.pending.removeValue(forKey: id) else { return }
            do {
                let object = try Self.object(response)
                if let error = object["error"] as? String { throw RuntimeError.message(error) }
                continuation.resume(returning: try JSONSerialization.data(withJSONObject: object["value"] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys]))
            } catch { continuation.resume(throwing: error) }
        }
        context.setObject(sync, forKeyedSubscript: "__nativeSync" as NSString)
        context.setObject(async, forKeyedSubscript: "__nativeAsync" as NSString)
        context.setObject(finish, forKeyedSubscript: "__nativeFinish" as NSString)
        context.setObject("1.6.3", forKeyedSubscript: "appVersion" as NSString)
        for name in ["MangaBridge", "VeneraAPI"] {
            guard let url = resourcesDirectory?.appending(path: name + ".js") ?? Bundle.main.url(forResource: name, withExtension: "js") else { throw RuntimeError.message("缺少漫画源运行组件") }
            context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
            if let exception { throw RuntimeError.message(exception) }
        }
        let pattern = #"class\s+([A-Za-z_$][A-Za-z0-9_$]*)\s+extends\s+ComicSource"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)), let range = Range(match.range(at: 1), in: script) else {
            throw RuntimeError.message("脚本中没有 ComicSource 定义")
        }
        context.evaluateScript(script + "\n globalThis.__source = new \(script[range])(); ComicSource.sources[__source.key] = __source; globalThis.__source.__metadata = () => ({name:__source.name,key:__source.key,version:__source.version,logged:__source.isLogged,url:__source.url,settings:__source.settings||{},searchOptions:__source.search?.optionList||[],explore:(__source.explore||[]).map((p,i)=>({title:p.title,type:p.type,index:i})),search:!!__source.search,account:!!__source.account,accountModes:{password:typeof __source.account?.login==='function',webURL:__source.account?.loginWithWebview?.url,cookieFields:__source.account?.loginWithCookies?.fields},sendComments:typeof __source.comic?.sendComment==='function',sendChapterComments:typeof __source.comic?.sendChapterComment==='function',rating:typeof __source.comic?.starRating==='function',comments:typeof __source.comic?.loadComments==='function',chapterComments:typeof __source.comic?.loadChapterComments==='function',favorites:!!__source.favorites,favoriteModes:{create:typeof __source.favorites?.addFolder==='function',delete:typeof __source.favorites?.deleteFolder==='function'}});")
        if let exception { throw RuntimeError.message(exception) }
        if let adapter = resourcesDirectory?.appending(path: "MangaSourceAdapter.js") ?? Bundle.main.url(forResource: "MangaSourceAdapter", withExtension: "js") {
            context.evaluateScript(try String(contentsOf: adapter, encoding: .utf8))
            if let exception { throw RuntimeError.message(exception) }
        }
        initialized = true
    }

    private func handleAsync(_ input: String, id: String) {
        do {
            let message = try Self.object(input)
            if message["method"] as? String == "UI" {
                guard let uiHandler else { throw RuntimeError.message("此操作需要用户界面") }
                uiWaitCount += 1
                uiHandler(input) { response in
                    self.queue.async { self.uiWaitCount -= 1; self.reply(id, response: response) }
                }
                return
            }
            if message["method"] as? String == "delay" {
                let delay = min(60_000, max(0, message["time"] as? Double ?? 0)) / 1000
                queue.asyncAfter(deadline: .now() + delay) { self.reply(id, response: Self.response(NSNull())) }
                return
            }
            guard let raw = message["url"] as? String, let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw RuntimeError.message("漫画源请求地址无效")
            }
            var request = URLRequest(url: url)
            request.httpMethod = message["http_method"] as? String ?? "GET"
            for (key, value) in message["headers"] as? [String: Any] ?? [:] { request.setValue(String(describing: value), forHTTPHeaderField: key) }
            let matched = cookies.filter { cookie in
                let host = url.host ?? ""
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path) && (!cookie.isSecure || url.scheme == "https") && (cookie.expiresDate ?? .distantFuture) > Date()
            }
            if request.value(forHTTPHeaderField: "Cookie") == nil && !matched.isEmpty {
                request.setValue(HTTPCookie.requestHeaderFields(with: matched)["Cookie"], forHTTPHeaderField: "Cookie")
            }
            if let text = message["data"] as? String { request.httpBody = Data(text.utf8) }
            else if let bytes = Self.bytes(message["data"]) { request.httpBody = bytes }
            else if let data = message["data"], !(data is NSNull) { request.httpBody = try JSONSerialization.data(withJSONObject: data) }
            let binary = message["bytes"] as? Bool ?? false
            session.dataTask(with: request) { [weak self] data, response, error in
                guard let self else { return }
                self.queue.async {
                    if let error { self.reply(id, response: Self.failure(error.localizedDescription)); return }
                    guard let http = response as? HTTPURLResponse, let data else { self.reply(id, response: Self.failure("漫画源未返回数据")); return }
                    var headers: [String: String] = [:]
                    http.allHeaderFields.forEach { headers[String(describing: $0.key).lowercased()] = String(describing: $0.value) }
                    for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: http.url ?? url) { self.storeCookie(cookie) }
                    do { try self.saveState() } catch { self.reply(id, response: Self.failure(error.localizedDescription)); return }
                    let body: Any = binary ? Self.binary(data) : (String(data: data, encoding: .utf8) ?? TextDecoding.decode(data) ?? "")
                    self.reply(id, response: Self.response(["status":http.statusCode,"headers":headers,"body":body]))
                }
            }.resume()
        } catch { reply(id, response: Self.failure(error.localizedDescription)) }
    }

    private func reply(_ id: String, response: String) {
        context.objectForKeyedSubscript("__nativeReply")?.call(withArguments: [id, response])
    }

    func processImage(_ data: Data, key: String) async throws -> Data {
        let response = try await call("__processImageResponse", arguments: [key, Self.binary(data)])
        let result = try JSONSerialization.jsonObject(with: response, options: [.fragmentsAllowed])
        guard let bytes = Self.bytes(result) else { throw RuntimeError.message("漫画源图片处理结果无效") }
        return bytes
    }

    private func image(_ message: [String: Any]) throws -> Any {
        func number(_ key: String) -> Int { (message[key] as? NSNumber)?.intValue ?? 0 }
        let key = number("key")
        switch message["function"] as? String {
        case "decode":
            guard let bytes = Self.bytes(message["data"]) else { throw RuntimeError.message("图片数据无效") }
            imageSequence += 1; images[imageSequence] = try MangaScriptBitmap(data: bytes); return imageSequence
        case "encode":
            guard let bitmap = images[key] else { throw RuntimeError.message("图片对象不存在") }
            let data = try bitmap.png(); images.removeAll(); return Self.binary(data)
        case "dispose": images.removeAll(); return NSNull()
        case "emptyImage": imageSequence += 1; images[imageSequence] = try MangaScriptBitmap(width: number("width"), height: number("height")); return imageSequence
        case "getWidth": return images[key]?.width ?? 0
        case "getHeight": return images[key]?.height ?? 0
        case "copyRange":
            guard let result = try images[key]?.cropped(x: number("x"), y: number("y"), width: number("width"), height: number("height")) else { return NSNull() }
            imageSequence += 1; images[imageSequence] = result; return imageSequence
        case "copyAndRotate90":
            guard let result = try images[key]?.rotated() else { return NSNull() }
            imageSequence += 1; images[imageSequence] = result; return imageSequence
        case "fillImageAt", "fillImageRangeAt":
            guard let source = images[number("image")] else { throw RuntimeError.message("图片对象不存在") }
            images[key]?.fill(source, x: number("x"), y: number("y"), srcX: number("srcX"), srcY: number("srcY"), width: message["width"] as? Int, height: message["height"] as? Int)
            return NSNull()
        default: throw RuntimeError.message("图片处理接口无效")
        }
    }

    private func handle(_ message: [String: Any]) throws -> Any {
        let method = message["method"] as? String ?? ""
        switch method {
        case "image": return try image(message)
        case "html": return try html(message)
        case "convert": return try convert(message)
        case "uuid": return UUID().uuidString
        case "getLocale": return "zh_CN"
        case "getPlatform": return "ios"
        case "load_data": return state[message["data_key"] as? String ?? ""] ?? NSNull()
        case "save_data": state[message["data_key"] as? String ?? ""] = message["data"] ?? NSNull(); try saveState(); return NSNull()
        case "delete_data": state.removeValue(forKey: message["data_key"] as? String ?? ""); try saveState(); return NSNull()
        case "load_setting":
            let key = message["setting_key"] as? String ?? ""
            if let value = (state["__settings"] as? [String: Any])?[key] { return value }
            let value = context.evaluateScript("globalThis.__source?.settings?.[\(Self.quoted(key))]?.default ?? null")
            return value?.toObject() ?? NSNull()
        case "save_setting":
            var settings = state["__settings"] as? [String: Any] ?? [:]
            settings[message["setting_key"] as? String ?? ""] = message["value"] ?? NSNull()
            state["__settings"] = settings; try saveState(); return NSNull()
        case "setLogged": state["__logged"] = message["value"] ?? false; try saveState(); return NSNull()
        case "isLogged": return state["__logged"] as? Bool ?? false
        case "log": return NSNull()
        case "random":
            let min = message["min"] as? Double ?? 0, max = message["max"] as? Double ?? 1
            let value = Double.random(in: min...Swift.max(min, max))
            return message["type"] as? String == "int" ? floor(value) : value
        case "cookie": return try cookie(message)
        case "compute":
            let function = message["function"] as? String ?? ""
            return context.evaluateScript("(\(function))")?.call(withArguments: message["args"] as? [Any] ?? [])?.toObject() ?? NSNull()
        default: throw RuntimeError.message("暂未实现漫画源 API：\(method)")
        }
    }

    private func storeCookie(_ cookie: HTTPCookie) {
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
        cookies.append(cookie)
    }
    private func cookie(_ message: [String: Any]) throws -> Any {
        guard let raw = message["url"] as? String, let url = URL(string: raw), let host = url.host else { return [] }
        switch message["function"] as? String {
        case "set":
            for value in message["cookies"] as? [[String: Any]] ?? [] {
                if let cookie = HTTPCookie(properties: [.name:value["name"] ?? "",.value:value["value"] ?? "",.domain:value["domain"] ?? host,.path:value["path"] ?? "/"]) { storeCookie(cookie) }
            }
        case "delete": cookies.removeAll { host == $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || host.hasSuffix($0.domain) }
        default:
            return cookies.filter { host == $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) || host.hasSuffix("." + $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) }.map { ["name":$0.name,"value":$0.value,"domain":$0.domain,"path":$0.path] }
        }
        try saveState(); return NSNull()
    }
    private func saveState() throws {
        state["__cookies"] = cookies.map { cookie -> [String: Any] in
            var value: [String: Any] = ["name":cookie.name,"value":cookie.value,"domain":cookie.domain,"path":cookie.path,"secure":cookie.isSecure]
            if let expires = cookie.expiresDate { value["expires"] = expires.timeIntervalSince1970 }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        guard data != savedStateData else { return }
        try MangaSecrets.saveFile(data, to: stateURL, namespace: storageKey)
        savedStateData = data
    }
    private static func object(_ string: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any] ?? [:]
    }
    private static func quoted(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]), encoding: .utf8)!
    }
    private static func response(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["value":value], options: [.sortedKeys]) else { return "{\"value\":null}" }
        return String(decoding: data, as: UTF8.self)
    }
    private static func failure(_ message: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["error":message]), as: UTF8.self)
    }
    private static func bytes(_ value: Any?) -> Data? {
        if let dictionary = value as? [String: Any], let bytes = dictionary["__bytes"] as? [UInt8] { return Data(bytes) }
        return nil
    }
    private static func binary(_ data: Data) -> [String: Any] { ["__bytes":Array(data)] }

    private func register(_ node: Node?, document: Int) -> Any {
        guard let node else { return NSNull() }
        nodeSequence += 1
        nodes[document, default: [:]][nodeSequence] = node
        return nodeSequence
    }
    private func html(_ message: [String: Any]) throws -> Any {
        let function = message["function"] as? String ?? ""
        let key = message["key"] as? Int ?? 0
        let docID = message["doc"] as? Int ?? key
        if function == "parse" {
            documents[key] = try SwiftSoup.parse(message["data"] as? String ?? "")
            nodes[key] = [:]
            return NSNull()
        }
        if function == "dispose" { documents[key] = nil; nodes[key] = nil; return NSNull() }
        guard let document = documents[docID] else { throw RuntimeError.message("网页解析对象已释放") }
        let node = nodes[docID]?[key]
        let element = node as? Element
        let query = message["query"] as? String ?? ""
        switch function {
        case "querySelector": return register(try document.select(query).first(), document: docID)
        case "querySelectorAll": return try document.select(query).array().map { register($0, document: docID) }
        case "getElementById": return register(try document.getElementById(message["id"] as? String ?? ""), document: docID)
        case "getText": return try element?.text() ?? ""
        case "getAttributes": return Dictionary(uniqueKeysWithValues: (element?.getAttributes()?.asList() ?? []).map { ($0.getKey(), $0.getValue()) })
        case "dom_querySelector": return register(try element?.select(query).first(), document: docID)
        case "dom_querySelectorAll": return try element?.select(query).array().map { register($0, document: docID) } ?? []
        case "getChildren": return element?.children().array().map { register($0, document: docID) } ?? []
        case "getNodes": return node?.getChildNodes().map { register($0, document: docID) } ?? []
        case "getInnerHTML": return try element?.html() ?? ""
        case "getParent": return register(node?.parent(), document: docID)
        case "getClassNames": return try Array(element?.classNames() ?? [])
        case "getId": return element?.id() ?? ""
        case "getLocalName": return element?.tagName() ?? ""
        case "getPreviousSibling": return register(try element?.previousElementSibling(), document: docID)
        case "getNextSibling": return register(try element?.nextElementSibling(), document: docID)
        case "node_text":
            if let text = node as? TextNode { return text.getWholeText() }
            return try element?.text() ?? ""
        case "node_type":
            if node is TextNode { return "text" }
            if node is Comment { return "comment" }
            if node is Document { return "document" }
            return element == nil ? "unknown" : "element"
        case "node_toElement", "node_to_element": return register(element, document: docID)
        default: throw RuntimeError.message("不支持的网页查询：\(function)")
        }
    }

    private func convert(_ message: [String: Any]) throws -> Any {
        let type = message["type"] as? String ?? ""
        let encoding = message["isEncode"] as? Bool ?? false
        let data = Self.bytes(message["value"]) ?? Data()
        switch type {
        case "utf8", "gbk":
            let codec: String.Encoding = type == "utf8" ? .utf8 : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            if encoding {
                guard let text = message["value"] as? String, let value = text.data(using: codec) else { throw RuntimeError.message("文字编码失败") }
                return Self.binary(value)
            }
            guard let text = String(data: data, encoding: codec) else { throw RuntimeError.message("文字解码失败") }
            return text
        case "base64":
            if encoding { return data.base64EncodedString() }
            guard let value = Data(base64Encoded: message["value"] as? String ?? "", options: .ignoreUnknownCharacters) else { throw RuntimeError.message("Base64 数据无效") }
            return Self.binary(value)
        case "md5": return Self.binary(Data(Insecure.MD5.hash(data: data)))
        case "sha1": return Self.binary(Data(Insecure.SHA1.hash(data: data)))
        case "sha256": return Self.binary(Data(SHA256.hash(data: data)))
        case "sha512": return Self.binary(Data(SHA512.hash(data: data)))
        case "hmac":
            let key = Self.bytes(message["key"]) ?? Data()
            let hash = message["hash"] as? String ?? "sha256"
            let algorithms: [String: (CCHmacAlgorithm, Int)] = ["md5":(CCHmacAlgorithm(kCCHmacAlgMD5),16),"sha1":(CCHmacAlgorithm(kCCHmacAlgSHA1),20),"sha256":(CCHmacAlgorithm(kCCHmacAlgSHA256),32),"sha512":(CCHmacAlgorithm(kCCHmacAlgSHA512),64)]
            guard let (algorithm, size) = algorithms[hash] else { throw RuntimeError.message("未知 HMAC 算法") }
            var output = [UInt8](repeating: 0, count: size)
            key.withUnsafeBytes { k in data.withUnsafeBytes { d in CCHmac(algorithm, k.baseAddress, key.count, d.baseAddress, data.count, &output) } }
            if message["isString"] as? Bool == true { return output.map { String(format: "%02x", $0) }.joined() }
            return Self.binary(Data(output))
        case "aes-ecb", "aes-cbc", "aes-cfb", "aes-ofb":
            let key = Self.bytes(message["key"]) ?? Data()
            guard [16,24,32].contains(key.count) else { throw RuntimeError.message("AES 密钥长度无效") }
            let iv = Self.bytes(message["iv"]) ?? Data(repeating: 0, count: 16)
            guard iv.count == 16 else { throw RuntimeError.message("AES 向量长度无效") }
            let mode: CCMode = type == "aes-ecb" ? CCMode(kCCModeECB) : type == "aes-cbc" ? CCMode(kCCModeCBC) : type == "aes-ofb" ? CCMode(kCCModeOFB) : CCMode((message["blockSize"] as? Int == 8) ? kCCModeCFB8 : kCCModeCFB)
            if (type == "aes-ecb" || type == "aes-cbc") && data.count % 16 != 0 { throw RuntimeError.message("AES 数据长度不是块大小的整数倍") }
            var cryptor: CCCryptorRef?
            let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
                CCCryptorCreateWithMode(CCOperation(encoding ? kCCEncrypt : kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(0), &cryptor)
            } }
            guard status == kCCSuccess, let cryptor else { throw RuntimeError.message("AES 初始化失败") }
            defer { CCCryptorRelease(cryptor) }
            var output = Data(count: data.count + 16)
            let capacity = output.count
            var moved = 0
            let result = output.withUnsafeMutableBytes { out in data.withUnsafeBytes { input in CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, capacity, &moved) } }
            guard result == kCCSuccess else { throw RuntimeError.message("AES 处理失败") }
            output.count = moved
            return Self.binary(output)
        default: throw RuntimeError.message("暂未实现编码算法：\(type)")
        }
    }
}
