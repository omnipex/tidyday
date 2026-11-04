import Foundation
import Security

// 雲端／自架模型：OpenAI、Claude、Gemini、OpenRouter、Ollama
// 預設仍是 Mac 本地模型；選了雲端引擎，貼上的內容才會送到該服務

enum Engine: String, CaseIterable, Identifiable {
    case apple, openai, anthropic, gemini, openrouter, ollama

    static let storageKey = "engine"

    var id: String { rawValue }

    /// 品牌名稱；Mac 本地模型的名稱要跟著介面語言，放在 Strings
    var brand: String? {
        switch self {
        case .apple: return nil
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        case .gemini: return "Gemini"
        case .openrouter: return "OpenRouter"
        case .ollama: return "Ollama"
        }
    }

    var needsKey: Bool { [.openai, .anthropic, .gemini, .openrouter].contains(self) }
    var hasBaseURL: Bool { self == .openai || self == .ollama }

    var defaultBaseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .ollama: return "http://localhost:11434"
        default: return ""
        }
    }

    var defaultModel: String { self == .anthropic ? "claude-opus-5-5" : "" }

    var modelPlaceholder: String {
        switch self {
        case .apple: return ""
        case .openai: return "gpt-5-mini"
        case .anthropic: return "claude-opus-5-5"
        case .gemini: return "gemini-2.5-flash"
        case .openrouter: return "openai/gpt-5-mini"
        case .ollama: return "qwen3:8b"
        }
    }

    static var current: Engine {
        Engine(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .apple
    }
}

struct CloudConfig {
    var engine: Engine
    var model: String
    var baseURL: String
    var apiKey: String

    static func modelKey(_ e: Engine) -> String { "model.\(e.rawValue)" }
    static func baseURLKey(_ e: Engine) -> String { "baseURL.\(e.rawValue)" }

    static func load(_ e: Engine) -> CloudConfig {
        let d = UserDefaults.standard
        let model = d.string(forKey: modelKey(e)).flatMap { $0.isEmpty ? nil : $0 } ?? e.defaultModel
        let base = d.string(forKey: baseURLKey(e)).flatMap { $0.isEmpty ? nil : $0 } ?? e.defaultBaseURL
        return CloudConfig(engine: e, model: model, baseURL: base, apiKey: Keychain.get(e.rawValue) ?? "")
    }

    var base: String {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// 內容會不會離開這台電腦（Ollama 指到 localhost 才算本機）
    var isOnDevice: Bool {
        if engine == .apple { return true }
        guard engine == .ollama, let host = URL(string: base)?.host else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(host)
    }
}

enum CloudError: LocalizedError {
    case missingKey, missingModel, refusal
    case http(Int, String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: return "API key missing"
        case .missingModel: return "model missing"
        case .refusal: return "the model declined this request"
        case .http(let code, let msg): return "HTTP \(code): \(msg.prefix(200))"
        case .badResponse(let msg): return "unexpected response: \(msg.prefix(200))"
        }
    }
}

enum CloudClient {
    /// Claude 這幾個模型建議開啟伺服器端 fallback（被安全分類器拒絕時自動換模型重跑）
    private static let claudeFallbackModels: Set<String> = ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    /// 要求 JSON 輸出；先用各家的結構化輸出參數，被拒（400）就拿掉額外參數、只靠指示再試一次
    static func json(_ c: CloudConfig, system: String, prompt: String, schema: [String: Any]) async throws -> Data {
        let sys = system + "\n\nRespond with JSON only, matching this JSON Schema:\n" + schemaString(schema)
        do {
            return try extractJSON(try await complete(c, system: sys, prompt: prompt, schema: schema, strict: true))
        } catch CloudError.http(400, _) {
            return try extractJSON(try await complete(c, system: sys, prompt: prompt, schema: nil, strict: false))
        }
    }

    static func text(_ c: CloudConfig, system: String, prompt: String) async throws -> String {
        do {
            return stripThinking(try await complete(c, system: system, prompt: prompt, schema: nil, strict: true))
        } catch CloudError.http(400, _) {
            return stripThinking(try await complete(c, system: system, prompt: prompt, schema: nil, strict: false))
        }
    }

    /// strict=false 時只送最基本的欄位，給不支援 effort／fallbacks／think 等參數的模型
    private static func complete(_ c: CloudConfig, system: String, prompt: String,
                                 schema: [String: Any]?, strict: Bool) async throws -> String {
        let model = c.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = c.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw CloudError.missingModel }
        if c.engine.needsKey && key.isEmpty { throw CloudError.missingKey }

        let messages: [[String: Any]] = [["role": "system", "content": system], ["role": "user", "content": prompt]]
        var headers: [String: String] = [:]
        var body: [String: Any]
        let url: String

        switch c.engine {
        case .apple:
            throw CloudError.badResponse("apple engine is not a cloud engine")

        case .openai, .openrouter:
            url = (c.engine == .openai ? c.base : "https://openrouter.ai/api/v1") + "/chat/completions"
            headers["Authorization"] = "Bearer \(key)"
            if c.engine == .openrouter { headers["X-Title"] = "TidyDay" }
            body = ["model": model, "messages": messages]
            if let schema {
                body["response_format"] = ["type": "json_schema",
                                           "json_schema": ["name": "result", "strict": true, "schema": schema]]
            }

        case .anthropic:
            url = "https://api.anthropic.com/v1/messages"
            headers["x-api-key"] = key
            headers["anthropic-version"] = "2026-10-21"
            body = ["model": model, "max_tokens": 16000, "system": system,
                    "messages": [["role": "user", "content": prompt]]]
            if strict {
                // 分類／摘要這種短任務用 low effort 就夠
                var output: [String: Any] = ["effort": "low"]
                if let schema { output["format"] = ["type": "json_schema", "schema": schema] }
                body["output_config"] = output
                if claudeFallbackModels.contains(model) {
                    headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
                    body["fallbacks"] = "default"
                }
            }

        case .gemini:
            let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            url = "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent"
            headers["x-goog-api-key"] = key
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": prompt]]]]]
            if let schema {
                body["generationConfig"] = ["responseMimeType": "application/json", "responseJsonSchema": schema]
            }

        case .ollama:
            url = c.base + "/api/chat"
            body = ["model": model, "stream": false, "messages": messages]
            if strict { body["think"] = false }
            if let schema { body["format"] = schema }
        }

        let data = try await send(url, method: "POST", headers: headers, body: body)
        return try extractText(c.engine, data)
    }

    private static func extractText(_ engine: Engine, _ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudError.badResponse(String(data: data, encoding: .utf8) ?? "")
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        switch engine {
        case .openai, .openrouter:
            let message = ((json["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
            if let refusal = message?["refusal"] as? String, !refusal.isEmpty { throw CloudError.refusal }
            guard let text = message?["content"] as? String else { throw CloudError.badResponse(raw) }
            return text
        case .anthropic:
            if json["stop_reason"] as? String == "refusal" { throw CloudError.refusal }
            let blocks = json["content"] as? [[String: Any]] ?? []
            guard let text = blocks.first(where: { $0["type"] as? String == "text" })?["text"] as? String else {
                throw CloudError.badResponse(raw)
            }
            return text
        case .gemini:
            let parts = (((json["candidates"] as? [[String: Any]])?.first?["content"]) as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
            guard !text.isEmpty else { throw CloudError.badResponse(raw) }
            return text
        case .ollama:
            guard let text = (json["message"] as? [String: Any])?["content"] as? String else { throw CloudError.badResponse(raw) }
            return text
        case .apple:
            throw CloudError.badResponse(raw)
        }
    }

    // MARK: - 模型清單

    static func listModels(_ c: CloudConfig) async throws -> [String] {
        let key = c.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.engine.needsKey && key.isEmpty { throw CloudError.missingKey }
        func ids(_ data: Data, list: String, field: String) -> [String] {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (json?[list] as? [[String: Any]] ?? []).compactMap { $0[field] as? String }
        }
        switch c.engine {
        case .apple:
            return []
        case .openai:
            let data = try await send(c.base + "/models", headers: ["Authorization": "Bearer \(key)"])
            return ids(data, list: "data", field: "id").sorted()
        case .openrouter:
            let data = try await send("https://openrouter.ai/api/v1/models", headers: ["Authorization": "Bearer \(key)"])
            return ids(data, list: "data", field: "id").sorted()
        case .anthropic:
            let data = try await send("https://api.anthropic.com/v1/models?limit=100",
                                      headers: ["x-api-key": key, "anthropic-version": "2026-10-21"])
            return ids(data, list: "data", field: "id")
        case .gemini:
            let data = try await send("https://generativelanguage.googleapis.com/v1beta/models?pageSize=200",
                                      headers: ["x-goog-api-key": key])
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (json?["models"] as? [[String: Any]] ?? [])
                .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
        case .ollama:
            let data = try await send(c.base + "/api/tags")
            return ids(data, list: "models", field: "name").sorted()
        }
    }

    // MARK: - HTTP 與解析

    private static func send(_ urlString: String, method: String = "GET",
                             headers: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CloudError.badResponse("bad URL: \(urlString)") }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = method
        headers.forEach { req.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CloudError.http(status, errorMessage(data)) }
        return data
    }

    /// 各家錯誤格式不同：{error:{message}}、{error:"..."}、或純文字
    private static func errorMessage(_ data: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let e = json?["error"] as? [String: Any], let m = e["message"] as? String { return m }
        if let m = json?["error"] as? String { return m }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func schemaString(_ schema: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    /// 思考型模型（qwen3、deepseek 等）可能把推理寫在 <think> 裡
    static func stripThinking(_ text: String) -> String {
        text.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 去掉 ``` 圍欄與前後雜訊，取第一個 { 到最後一個 }
    static func extractJSON(_ text: String) throws -> Data {
        let t = stripThinking(text)
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"), start < end else {
            throw CloudError.badResponse(t)
        }
        return Data(t[start...end].utf8)
    }
}

/// API key 存在 macOS 鑰匙圈，不寫進設定檔
enum Keychain {
    private static let service = "io.github.omnipex.tidyday"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(v.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
