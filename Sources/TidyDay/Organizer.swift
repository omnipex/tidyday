import Foundation
import FoundationModels
import NaturalLanguage

// 本地模型（Apple Foundation Models）負責把貼上的文字拆成已完成／待辦／筆記

@Generable
enum GenKind {
    case done
    case todo
    case note
}

struct ParsedItem {
    var kind: Kind
    var text: String
    /// 這一項對應的原文那一行：模型改寫時常把「今天」「明天」拿掉，時間改從原文抓
    var source: String?
}

struct ParseOutput {
    var items: [ParsedItem] = []
    /// 對應傳入 openTodos 的索引（從 0 開始）
    var completedTodoIndexes: Set<Int> = []
    /// ReAct 每一步的紀錄（評估用）
    var trace: [String] = []
}

enum Organizer {
    static let chunkLimit = 1200

    // 11/7 依 eval/ 的 112 個案例重寫：重點是「看時態，不看動詞」、一句多件事要拆開、雜訊不要捏造
    static func parseInstructions(_ lang: AppLanguage) -> String {
        switch lang.resolved {
        case .zhHant, .zhHans:
            return """
            你是個人工作日誌助理。把使用者貼上的內容（聊天紀錄、會議筆記、隨手寫的話）拆成項目，每一項只有「一件事」。
            拆分：
            - 一句話裡有好幾件事（用逗號、「還要」「但」「順便」「然後」連接）就拆成好幾項，例如「X 做完了，明天要 Y」是兩項
            - 條件或時間點不是另一件事：「X 之後記得 Y」只有一項（Y）
            - 聊天紀錄裡，同一件事從被請託、答應到做完只列一項，用最後的狀態；別人交辦、我回「收到」「好」，那件事是 todo
            分類時先看時態，不要只看動詞：
            - done：原文表示已經發生（了、已經、剛、終於、搞定、（完成））
            - todo：還沒發生（要、得、需要、記得、…前、明天、下週、待會、還沒、答應、說好），或別人請我做的事
            - 「完成、寄出、上線、合併」本身不代表做完：「週五前完成 X」「把 X 寄出去」「X 之後要 Y」都是 todo
            - note：資訊、數據、決策、結論、別人回報的狀況、想法；數字、比例、金額的變化（降到、成長、增加）是 note，不是 done
            其他：
            - 每項一句\(lang.resolved == .zhHans ? "簡體中文" : "繁體中文")，保留專有名詞、數字、人名；時間詞（明天、週五前、晚上、3 點）照原樣保留
            - 原文裡的英文詞（budget、PR、deploy、bug）照原樣保留，不要翻成中文
            - 「我」指使用者
            - 寒暄、道謝、「哈哈」「好喔」不用列；整段都沒有實質內容就回傳空的 items；不要捏造原文沒有的內容
            """
        default:
            return """
            You are a personal work-log assistant. Split what the user pastes (chat logs, meeting notes, quick thoughts) into items, each item exactly one thing.
            Splitting:
            - If one sentence holds several things (joined by commas, "but", "and also", "then"), split them: "did X, will do Y tomorrow" is two items
            - A condition or point in time is not a separate thing: "after X, remember to Y" is one item (Y)
            - In chat logs, one thing that goes from requested to promised to finished is one item with its final state; if someone asks and the user replies "got it" or "ok", it is a todo
            Classify by tense, not by the verb:
            - done: the text says it already happened (finished, fixed, sent, already, just, past tense)
            - todo: it has not happened yet (need to, will, by Friday, tomorrow, remember, haven't, promised), or someone asked the user to do it
            - "send", "finish", "ship" alone do not mean done: "send X by Friday" and "finish X this month" are todo
            - note: information, data, decisions, conclusions, status reported by others, ideas; changes in numbers, rates or amounts (dropped to, grew by) are notes, not done
            Other rules:
            - Write each item as one concise sentence in \(lang.promptLanguage), keeping names, numbers and time words (tomorrow, by Friday, tonight, 3 pm) as written
            - Keep words from other languages exactly as written; do not translate them
            - "I" means the user
            - Skip greetings, thanks and small talk; if there is no real content, return empty items; never invent anything not in the text
            """
        }
    }

    /// ReAct 第二步：時態有矛盾時，只針對那一句再確認一次
    static func checkInstructions(_ lang: AppLanguage) -> String {
        switch lang.resolved {
        case .zhHant, .zhHans:
            return """
            你判斷一句話描述的事，在使用者寫下時是否已經做完。看時態，不要只看動詞。
            - done：已經發生（了、已經、剛、終於、搞定）
            - todo：還沒發生（要、得、記得、…前、明天、還沒、答應、說好），或別人請使用者做的事。「把 X 寄出去」「週五前完成 X」是 todo
            - note：只是資訊或別人的狀況
            """
        default:
            return """
            You decide whether the thing a sentence describes had already happened when the user wrote it. Judge by tense, not by the verb.
            - done: it already happened (finished, fixed, sent, already, past tense)
            - todo: it has not happened yet (need to, will, by Friday, tomorrow, remember, haven't, promised), or someone asked the user to do it. "Send X" and "finish X by Friday" are todo
            - note: just information or someone else's status
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
    static func withRetry<T>(_ body: () async throws -> T) async throws -> T {
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
                        "quote": ["type": "string", "description": "Exact words copied from the content"],
                        "evidence": ["type": "string", "description": "happened: / not yet: / info: plus the deciding words"],
                        "kind": ["type": "string", "enum": ["done", "todo", "note"]],
                        "text": ["type": "string"],
                    ],
                    "required": ["quote", "evidence", "kind", "text"],
                    "additionalProperties": false,
                ],
            ]
        ],
        "required": ["items"],
        "additionalProperties": false,
    ]

    static let checkSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "reasoning": ["type": "string"],
            "kind": ["type": "string", "enum": ["done", "todo", "note"]],
        ],
        "required": ["reasoning", "kind"],
        "additionalProperties": false,
    ]

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

    /// 輸出語言跟著貼上的內容：有假名→日文；有漢字→中文（繁簡交給系統判斷）；其他用系統偵測，判斷不出來才用介面語言。
    /// 實測：介面是英文時貼繁中，模型會輸出簡體；中英夾雜時系統偵測常誤判（例：判成印尼文），所以先看文字種類
    static func contentLanguage(_ text: String, fallback: AppLanguage) -> AppLanguage {
        let scalars = text.unicodeScalars
        if scalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { return .ja }
        if scalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.traditionalChinese, .simplifiedChinese]
            r.processString(text)
            return r.dominantLanguage == .simplifiedChinese ? .zhHans : .zhHant
        }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.dominantLanguage == .english ? .en : fallback
    }

    static func parse(_ text: String, openTodos: [String], lang uiLang: AppLanguage, engine: Engine = .current) async throws -> ParseOutput {
        let lang = contentLanguage(text, fallback: uiLang)
        let cloud = engine == .apple ? nil : CloudConfig.load(engine)
        let todos = openTodos
        var output = ParseOutput()
        var parser = ReActParser(lang: lang, cloud: cloud)
        for chunk in chunks(of: text, limit: cloud == nil ? chunkLimit : cloudChunkLimit) {
            var chunkItems = try await parser.parse(chunk)
            // 繁中偶爾還是會混出簡體字：用系統的簡轉繁再保險一次
            if lang.resolved == .zhHant {
                for i in chunkItems.indices {
                    chunkItems[i].text = chunkItems[i].text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? chunkItems[i].text
                }
            }
            // 時間改從原文那一行抓：對應到最像的原文行（模型改寫時常把「今天」「明天」拿掉）
            let lines = chunk.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            for i in chunkItems.indices {
                let key = (chunkItems[i].source ?? "") + chunkItems[i].text
                chunkItems[i].source = lines.count == 1 ? lines[0]
                    : lines.max { similarity($0, key) < similarity($1, key) }.flatMap { similarity($0, key) >= 0.3 ? $0 : nil }
            }
            output.items += chunkItems
        }
        output.trace = parser.trace
        // 勾掉既有待辦：每個 done 項目只對應最像的那一個待辦，重疊率夠高才算。
        // 原本讓模型挑編號，實測本地模型幾乎一律回答第 1 項（只貼新待辦也會勾掉別的待辦），所以改用文字比對。
        // 11/5 實測：真的做完的重疊率 0.50–0.67，誤判例子 ≤ 0.20
        var matchedDone = Set<Int>()
        for (i, item) in output.items.enumerated() where item.kind == .done {
            let scores = todos.map { similarity($0, item.text) }
            if let best = scores.indices.max(by: { scores[$0] < scores[$1] }), scores[best] >= 0.4 {
                output.completedTodoIndexes.insert(best)
                matchedDone.insert(i)
            }
        }
        // 已經拿去勾待辦的 done 項目不再重複新增；模型也常把既有待辦重抄一次：跟既有待辦太像的就丟掉
        output.items = output.items.enumerated().filter { i, item in
            !matchedDone.contains(i) && !todos.contains { similarity($0, item.text) >= 0.5 }
        }.map(\.element)
        return output
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
