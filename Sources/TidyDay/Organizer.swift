import Foundation
import FoundationModels

// 本地模型（Apple Foundation Models）負責把貼上的文字拆成已完成／待辦／筆記

@Generable
enum GenKind {
    case done
    case todo
    case note
}

@Generable
struct GenItem {
    @Guide(description: "done = already finished by the user; todo = not done yet, planned, or requested by others; note = information, ideas, decisions, data")
    var kind: GenKind
    @Guide(description: "One concise sentence in the output language required by the instructions; keep proper nouns, numbers, names and dates")
    var text: String
}

@Generable
struct GenResult {
    var items: [GenItem]
}

@Generable
struct GenCompleted {
    @Guide(description: "Numbers of existing to-dos that the new content clearly says are finished; empty if none or unsure")
    var numbers: [Int]
}

struct ParsedItem {
    var kind: Kind
    var text: String
}

struct ParseOutput {
    var items: [ParsedItem] = []
    /// 對應傳入 openTodos 的索引（從 0 開始）
    var completedTodoIndexes: Set<Int> = []
}

enum Organizer {
    static let chunkLimit = 1200
    static let todoLimit = 20

    // 繁中 prompt 是 11/4 用實際樣本調過的版本；其他語言用英文指示並指定輸出語言
    static func parseInstructions(_ lang: AppLanguage) -> String {
        switch lang.resolved {
        case .zhHant:
            return """
            你是個人工作日誌助理。使用者會貼上任意文字（聊天紀錄、會議筆記、隨手寫的話、信件、系統訊息）。
            把內容拆成條列項目並分類：
            - done：使用者已經做完的事（已經、完成、修好、寄出、開完會、上線）
            - todo：還沒做、之後要做、別人交代的事（要、記得、明天、待處理、TODO、請你）
            - note：資訊、想法、決策、會議結論、數據、參考資料，不屬於前兩類
            規則：
            - 每一句有實質內容的話都要列成一項，不可以漏掉；數據、指標、決策、結論都列成 note
            - 每項一句繁體中文，精簡但保留專有名詞、數字、人名、日期
            - 同一件事從被提出、答應、到完成，只列一項最終狀態（例：別人請託→我說好→我說修好了，只列一項 done）
            - 「我」指使用者；只是答應或說之後會做，算 todo，不算 done
            - 寒暄、客套、無意義內容不用列；不要捏造原文沒有的內容
            """
        default:
            return """
            You are a personal work-log assistant. The user pastes any text (chat logs, meeting notes, quick thoughts, emails, system messages), possibly in any language.
            Split it into list items and classify each one:
            - done: things the user has already finished (finished, fixed, sent, shipped, had the meeting)
            - todo: things not done yet, planned, or requested by others (need to, remember, tomorrow, TODO, please)
            - note: information, ideas, decisions, meeting conclusions, metrics, data, references that are neither of the above
            Rules:
            - Every sentence with real content must become an item; never drop one. Metrics, numbers, decisions and conclusions are notes
            - Write every item as one concise sentence in \(lang.promptLanguage), keeping proper nouns, numbers, names and dates
            - If one thing goes from requested, to promised, to finished, list only one item with its final state
            - "I" means the user; merely promising or planning to do something is todo, not done
            - Skip greetings, small talk and meaningless content; never invent anything not in the text
            """
        }
    }

    static func completionInstructions(_ lang: AppLanguage) -> String {
        switch lang.resolved {
        case .zhHant:
            return """
            你負責比對待辦清單。判斷使用者貼上的新內容，是否明確表示某些既有待辦已經做完。
            只有新內容清楚說已完成（寄出了、做完了、修好了、已上線）才算；只是提到、正在做、打算做都不算。
            """
        default:
            return """
            You compare a to-do list against new content. Decide whether the new content clearly says some existing to-dos are finished.
            Count it only when the content clearly says it is done (sent, finished, fixed, shipped); merely mentioning, working on, or planning it does not count.
            """
        }
    }

    static func summaryInstructions(_ lang: AppLanguage) -> String {
        switch lang.resolved {
        case .zhHant:
            return """
            你是個人工作日誌助理。根據使用者今天的已完成事項、待辦、筆記，寫 2 到 4 句繁體中文的工作日報摘要：
            今天主要做了什麼、還有什麼沒完成。只根據提供的內容，不要捏造，不要給建議、提醒或客套話。
            """
        default:
            return """
            You are a personal work-log assistant. From the user's finished items, to-dos and notes for the day, write a 2 to 4 sentence work summary in \(lang.promptLanguage):
            what was mainly done today and what is still open. Use only the provided content; do not invent anything, and do not add advice, reminders or pleasantries.
            """
        }
    }

    /// 限制輸出長度：小模型偶爾會陷入重複輸出，直到超過 context 上限
    static let options = GenerationOptions(maximumResponseTokens: 1000)

    /// 失敗時換新 session 重試一次（模型輸出有隨機性，重試通常就會過）
    private static func withRetry<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { return try await body() }
    }

    /// 雲端模型的 context 大很多，切段可以放寬
    static let cloudChunkLimit = 8000

    static let parseSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "items": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "kind": ["type": "string", "enum": ["done", "todo", "note"]],
                        "text": ["type": "string"],
                    ],
                    "required": ["kind", "text"],
                    "additionalProperties": false,
                ],
            ]
        ],
        "required": ["items"],
        "additionalProperties": false,
    ]

    static let completedSchema: [String: Any] = [
        "type": "object",
        "properties": ["numbers": ["type": "array", "items": ["type": "integer"]]],
        "required": ["numbers"],
        "additionalProperties": false,
    ]

    private struct CloudItems: Decodable {
        struct Item: Decodable { var kind: String; var text: String }
        var items: [Item]
    }

    private struct CloudCompleted: Decodable { var numbers: [Int] }

    /// nil 表示可以用；否則回傳給使用者看的原因
    static func unavailableReason(_ s: Strings, engine: Engine = .current) -> String? {
        if engine != .apple {
            let c = CloudConfig.load(engine)
            if engine.needsKey && c.apiKey.isEmpty { return s.missingKey(engine.brand ?? "") }
            if c.model.trimmingCharacters(in: .whitespaces).isEmpty { return s.missingModel }
            return nil
        }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return s.modelNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return s.modelNotEnabled
        case .unavailable(.modelNotReady): return s.modelNotReady
        case .unavailable: return s.modelUnavailable
        }
    }

    static func parse(_ text: String, openTodos: [String], lang: AppLanguage, engine: Engine = .current) async throws -> ParseOutput {
        let cloud = engine == .apple ? nil : CloudConfig.load(engine)
        let todos = Array(openTodos.prefix(todoLimit))
        var output = ParseOutput()
        for chunk in chunks(of: text, limit: cloud == nil ? chunkLimit : cloudChunkLimit) {
            var chunkItems = try await extractItems(chunk, lang: lang, cloud: cloud)
            // 小模型偶爾會整行漏掉（實測英文最後一行常被略過）：對不上任何項目的實質內容行，原文補成筆記
            for line in chunk.components(separatedBy: .newlines) {
                let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isSubstantial(l), !chunkItems.contains(where: { similarity(l, $0.text) >= 0.3 }) else { continue }
                chunkItems.append(ParsedItem(kind: .note, text: l))
            }
            output.items += chunkItems
            if !todos.isEmpty {
                output.completedTodoIndexes.formUnion(try await completedTodos(in: chunk, todos: todos, lang: lang, cloud: cloud))
            }
        }
        // 模型常把既有待辦重抄一次，或把剛完成的待辦再列成 done：跟既有待辦太像的就丟掉
        output.items.removeAll { item in
            todos.contains { similarity($0, item.text) >= 0.5 }
        }
        return output
    }

    private static func extractItems(_ chunk: String, lang: AppLanguage, cloud: CloudConfig?) async throws -> [ParsedItem] {
        let prompt = lang.resolved == .zhHant ? "新內容：\n<<<\n\(chunk)\n>>>" : "New content:\n<<<\n\(chunk)\n>>>"
        let raw: [(Kind, String)]
        if let cloud {
            let data = try await CloudClient.json(cloud, system: parseInstructions(lang), prompt: prompt, schema: parseSchema)
            raw = try JSONDecoder().decode(CloudItems.self, from: data).items
                .map { (Kind(rawValue: $0.kind.lowercased()) ?? .note, $0.text) }
        } else {
            let response = try await withRetry {
                try await LanguageModelSession(instructions: parseInstructions(lang))
                    .respond(to: prompt, generating: GenResult.self, options: options)
            }
            raw = response.content.items.map { (Kind($0.kind), $0.text) }
        }
        return raw.compactMap { kind, text in
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : ParsedItem(kind: kind, text: t)
        }
    }

    private static func completedTodos(in chunk: String, todos: [String], lang: AppLanguage, cloud: CloudConfig?) async throws -> Set<Int> {
        let numbered = todos.enumerated()
            .map { "\($0.offset + 1). \(String($0.element.prefix(40)))" }
            .joined(separator: "\n")
        let prompt = lang.resolved == .zhHant
            ? "既有待辦：\n\(numbered)\n\n新內容：\n<<<\n\(chunk)\n>>>"
            : "Existing to-dos:\n\(numbered)\n\nNew content:\n<<<\n\(chunk)\n>>>"
        let numbers: [Int]
        if let cloud {
            let data = try await CloudClient.json(cloud, system: completionInstructions(lang), prompt: prompt, schema: completedSchema)
            numbers = try JSONDecoder().decode(CloudCompleted.self, from: data).numbers
        } else {
            numbers = try await withRetry {
                try await LanguageModelSession(instructions: completionInstructions(lang))
                    .respond(to: prompt, generating: GenCompleted.self, options: options)
            }.content.numbers
        }
        return Set(numbers.filter { $0 >= 1 && $0 <= todos.count }.map { $0 - 1 })
    }

    /// 夠長才算實質內容：中日韓文 8 個字以上，其他語言 4 個字以上
    static func isSubstantial(_ line: String) -> Bool {
        let cjk = line.filter { c in c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) } }.count
        if cjk > 0 { return cjk >= 8 }
        return line.split { !$0.isLetter && !$0.isNumber }.count >= 4
    }

    /// 重疊率（以較短的一方為分母）：中日韓文用字元 bigram（不需要斷詞），其他語言用單字
    static func similarity(_ a: String, _ b: String) -> Double {
        func isCJK(_ c: Character) -> Bool {
            c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
        }
        func tokens(_ s: String) -> Set<String> {
            let lower = s.lowercased()
            if lower.contains(where: isCJK) {
                let chars = Array(lower.filter { !$0.isWhitespace && !$0.isPunctuation })
                guard chars.count > 1 else { return Set(chars.map(String.init)) }
                return Set((0..<chars.count - 1).map { String(chars[$0...$0 + 1]) })
            }
            let words = lower.split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }
            return Set(words)
        }
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    static func summarize(done: [String], todo: [String], notes: [String], lang: AppLanguage, engine: Engine = .current) async throws -> String {
        let s = lang.strings
        func list(_ items: [String]) -> String {
            items.isEmpty ? s.none : items.prefix(30).map { "- \($0)" }.joined(separator: "\n")
        }
        let prompt = """
        \(s.done):
        \(list(done))

        \(s.todo):
        \(list(todo))

        \(s.note):
        \(list(notes))
        """
        if engine != .apple {
            return try await CloudClient.text(CloudConfig.load(engine), system: summaryInstructions(lang), prompt: prompt)
        }
        let session = LanguageModelSession(instructions: summaryInstructions(lang))
        let response = try await session.respond(options: options) { prompt }
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本地模型的 context 很小，長文依行切段
    private static func chunks(of text: String, limit chunkLimit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: .newlines) {
            if current.count + line.count > chunkLimit, !current.isEmpty {
                result.append(current)
                current = ""
            }
            // 單行超長就硬切
            var rest = Substring(line)
            while rest.count > chunkLimit {
                result.append(String(rest.prefix(chunkLimit)))
                rest = rest.dropFirst(chunkLimit)
            }
            current += (current.isEmpty ? "" : "\n") + rest
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result
    }
}

extension Kind {
    init(_ g: GenKind) {
        switch g {
        case .done: self = .done
        case .todo: self = .todo
        case .note: self = .note
        }
    }
}
