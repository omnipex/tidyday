import Foundation
import FoundationModels

// 解析流程（ReAct：推理 → 行動 → 觀察，有矛盾才再問一次）
//
// 1. 推理：模型輸出每一項時，先引用原文（quote）、寫出時態依據（evidence），最後才決定分類。
//    Apple 的模型照欄位順序生成，所以「先寫依據再分類」就是先想再答。
// 2. 觀察：用程式工具檢查每一項
//    - 時態：判成 done 卻只有「要／…前／記得」等未完成的字，或判成 todo 卻只有「了／已經」→ 重新確認
//    - 多意圖：一項的原文裡同時有「已完成」和「未完成」的子句 → 拆開
//    - 覆蓋：原文有子句沒有任何一項對應到 → 單獨再解析那一句
//    - 捏造：項目跟原文幾乎沒有重疊（例：「早安」被寫成「明天要準備簡報」）→ 丟掉
// 3. 行動：針對有問題的那一句再問模型一次（確認時態、拆開、補解析），沒問題的不多花時間
//
// 11/7 基準線（舊的單次 prompt）：112 案例 84.2%，多意圖 67.6%；主要錯在把「週五前把預算寄出去」當成 done、
// 一句多件事沒拆開、「早安」被捏造成待辦。測試在 eval/。

// 欄位順序就是生成順序：先引用原文、寫出決定時態的字，再分類，最後才改寫。
// 11/7 實測：用自由文字寫長理由時，小模型偶爾會在最後一個欄位寫出一長串 JSON 碎片和自言自語，所以理由改成幾個字的 cue；
// 試過用 .pattern(.{1,N}) 限制長度，但中文生成會慢到單一案例跑 4 分鐘以上，所以改由 Aspect.sanitize 截斷
@Generable
struct GenItem {
    @Guide(description: "The exact words copied from the content that this item comes from")
    var quote: String
    @Guide(description: "The few words that decide whether it already happened, e.g. 了, 已經, 要, 週五前, finished, need to; empty if none")
    var cue: String
    @Guide(description: "done = already happened; todo = not happened yet, planned, promised, or requested; note = information, data, decisions")
    var kind: GenKind
    @Guide(description: "One concise sentence in the output language; keep names, numbers and time words")
    var text: String
}

@Generable
struct GenResult {
    var items: [GenItem]
}

@Generable
struct GenCheck {
    @Guide(description: "The deciding words and whether they mean it already happened")
    var reasoning: String
    var kind: GenKind
}

struct ReActParser {
    let lang: AppLanguage
    let cloud: CloudConfig?
    /// 每一步的紀錄（評估時印出來看模型怎麼想）
    var trace: [String] = []
    /// 每段內容最多額外再問幾次，避免長文太慢
    static let maxFollowUps = 6

    struct Unit {
        var kind: Kind
        var text: String
        var quote: String
        var evidence: String

        /// 這一項是否涵蓋了兩個以上的子句（也就是把好幾件事塞成一項）
        func spans(_ clauses: [String]) -> Bool {
            clauses.filter { Organizer.similarity($0, text) >= 0.5 || Organizer.similarity($0, quote) >= 0.5 }.count >= 2
        }
    }

    // MARK: - 主流程

    mutating func parse(_ chunk: String) async throws -> [ParsedItem] {
        // 整段都是寒暄（早安、謝謝、哈哈）就不交給模型：實測小模型會捏造「需要處理早安的訊息」
        if Aspect.isNoise(chunk) {
            trace.append("⓪ 整段是寒暄，略過")
            return []
        }
        // 1. 推理＋擷取
        var units = try await extract(chunk, hint: nil)
        trace.append("① 擷取 \(units.count) 項：" + units.map { "\($0.kind.rawValue):\($0.text)〔\($0.evidence)〕" }.joined(separator: " | "))
        // 模型在描述自己（「無新內容可記錄」「內容尚未列出」）不是使用者的事
        units.removeAll { u in
            let meta = Aspect.isMeta(u.text)
            if meta { trace.append("② 丟掉後設說明：\(u.text)") }
            return meta
        }
        var followUps = 0

        // 2a. 捏造：跟原文幾乎沒有重疊的丟掉
        units.removeAll { u in
            let invented = Organizer.similarity(u.text, chunk) < 0.3 && Organizer.similarity(u.quote, chunk) < 0.3
            if invented { trace.append("② 丟掉捏造：\(u.text)") }
            return invented
        }
        // 2b. 雜訊：原文去掉寒暄後沒剩東西
        units.removeAll { u in
            let noise = Aspect.isNoise(u.quote.isEmpty ? u.text : u.quote)
            if noise { trace.append("② 丟掉寒暄：\(u.quote)") }
            return noise
        }

        // 2c. 多意圖：一項涵蓋好幾個子句，且子句的時態不同、或用「順便／還要／然後」連接 → 程式依子句拆開，
        //     編號列在一起「一次」問完（實測請模型自己拆不可靠；一句一句問又太慢）
        var i = 0
        while i < units.count, followUps < Self.maxFollowUps {
            let u = units[i]
            let source = Aspect.bestLine(for: u, in: chunk)
            let clauses = Aspect.clauses(source).filter(Aspect.isContentful)
            let tenses = Set(clauses.compactMap { Aspect.tense($0, lang: lang) })
            // 不管模型有沒有另外輸出其中一小句，都整句拆開重來（重複的交給最後的去重）
            // 也包含「做完了＋決策」（「今天開完週會，決定延後上線」）：決策子句沒有時態詞，但仍是另一件事
            let hasDecision = clauses.contains(where: Aspect.isDecision)
            if clauses.count > 1, u.spans(clauses), tenses.count > 1 || Aspect.hasConnector(source) || (hasDecision && !tenses.isEmpty) {
                followUps += 1
                let parts = try await extract(clauses.joined(separator: "\n"), hint: .lines)
                    .filter { !Aspect.isNoise($0.quote) && !Aspect.isMeta($0.text) && !Self.echoesHint($0.text) }
                trace.append("③ 拆開「\(source)」→ " + parts.map { "\($0.kind.rawValue):\($0.text)" }.joined(separator: " | "))
                if parts.count > 1 {
                    units.replaceSubrange(i...i, with: parts)
                    i += parts.count
                    continue
                }
            }
            i += 1
        }

        // 2d. 時態矛盾 → 再確認
        for j in units.indices where followUps < Self.maxFollowUps {
            let u = units[j]
            let q = u.quote.isEmpty ? u.text : u.quote
            let tense = Aspect.tense(q, lang: lang)
            // done／todo 跟時態線索相反；或 note 卻帶「已經／了」（「會議室已經訂好了」）、「順便／還要」（「順便通知 Amy」）
            let conflict = (u.kind == .done && tense == .notYet) || (u.kind == .todo && tense == .happened)
                || (u.kind == .note && !Aspect.hasNumber(q) && (tense != nil || Aspect.hasConnector(q)))
            guard conflict else { continue }
            followUps += 1
            let checked = try await check(u)
            trace.append("④ 確認「\(u.quote)」：\(u.kind.rawValue) → \(checked.kind.rawValue)〔\(checked.reasoning)〕")
            units[j].kind = checked.kind
        }

        // 2d'. 規則修正（eval 中穩定重現、模型再問也改不過來的兩種）
        //      數據變化（「當機率降到 0.4%」）是筆記，不是 done；決策（「會議結論：上線延到下個月」）是筆記，除非寫明我要做
        for j in units.indices where units[j].kind != .note {
            let q = units[j].quote.isEmpty ? units[j].text : units[j].quote
            // 模型的引用常把「會議結論：」這種前綴拿掉，所以也看原文那一行（只有這一項就是整行時）
            let line = Aspect.bestLine(for: units[j], in: chunk)
            let lineIsThisItem = Aspect.clauses(line).count == 1
            if (units[j].kind == .done && Aspect.isMetricChange(q)) || Aspect.isDecision(q) || (lineIsThisItem && Aspect.isDecision(line)) {
                trace.append("④' 規則改成 note：\(q)")
                units[j].kind = .note
            }
        }

        // 2e. 覆蓋：有實質內容、卻沒有任何一項對應到的子句 → 全部編號列在一起，一次補解析
        let covered = { (c: String, us: [Unit]) in
            us.contains { Organizer.similarity(c, $0.quote) >= 0.5 || Organizer.similarity(c, $0.text) >= 0.4 }
        }
        let missed = Aspect.clauses(chunk).filter { Aspect.isContentful($0) && !Aspect.isNoise($0) && !covered($0, units) }
        if !missed.isEmpty, followUps < Self.maxFollowUps {
            followUps += 1
            let extra = try await extract(missed.joined(separator: "\n"), hint: .lines)
                .filter { e in !Aspect.isNoise(e.quote.isEmpty ? e.text : e.quote) && !Aspect.isMeta(e.text) && !Self.echoesHint(e.text)
                    && missed.contains { Organizer.similarity(e.text, $0) >= 0.3 } }
            trace.append("⑤ 補解析「\(missed.joined(separator: " / "))」→ " + (extra.isEmpty ? "（無）" : extra.map { "\($0.kind.rawValue):\($0.text)" }.joined(separator: " | ")))
            units += extra
        }

        // 2f. 去重：補解析或模型重複輸出，同一件事出現兩次（「年度考核」＋「年度考核還沒完成」）→ 留先出現的
        var kept: [Unit] = []
        for u in units {
            if let dup = kept.first(where: { Organizer.similarity($0.text, u.text) >= 0.6 || (!u.quote.isEmpty && Organizer.similarity($0.quote, u.quote) >= 0.8) }) {
                trace.append("⑥ 去重：\(u.text)（同 \(dup.text)）")
                continue
            }
            kept.append(u)
        }
        return kept.map { ParsedItem(kind: $0.kind, text: $0.text, source: $0.quote.isEmpty ? nil : $0.quote) }
    }

    // MARK: - 行動：呼叫模型

    enum Hint { case split, single, lines }

    static let linesHintZh = "每一行各自是一件事，逐行列出，不要合併；寒暄或沒有實質內容的行就略過。"
    static let linesHintEn = "Each line is its own thing. List them line by line without merging; skip lines that are small talk."
    /// 模型偶爾把提示句本身當成內容（「每一行在週會中都應被視為獨立項目」）
    static func echoesHint(_ s: String) -> Bool {
        Organizer.similarity(s, linesHintZh) >= 0.35 || Organizer.similarity(s, linesHintEn) >= 0.5
    }

    private func extract(_ text: String, hint: Hint?) async throws -> [Unit] {
        let zh = lang.resolved == .zhHant || lang.resolved == .zhHans
        // 不用「新內容：」當標籤：小模型會把它抄進項目（「新內容還在等法務看」）
        var prompt = "<<<\n\(text)\n>>>"
        switch hint {
        case .split: prompt += zh ? "\n這段話包含不只一件事，請拆成多項，每項只有一件事。" : "\nThis contains more than one thing. Split it into separate items, one thing each."
        case .single: prompt += zh ? "\n這是一句話，列出它包含的事（寒暄或沒有實質內容就回傳空的 items）。" : "\nThis is a single sentence. List what it contains (return empty items if it is small talk)."
        case .lines: prompt += "\n" + (zh ? Self.linesHintZh : Self.linesHintEn)
        case nil: break
        }
        let raw: [(Kind, String, String, String)]
        if let cloud {
            let data = try await CloudClient.json(cloud, system: Organizer.parseInstructions(lang), prompt: prompt, schema: Organizer.parseSchema)
            raw = try JSONDecoder().decode(CloudItems.self, from: data).items
                .map { (Kind(rawValue: $0.kind.lowercased()) ?? .note, $0.text, $0.quote ?? "", $0.evidence ?? "") }
        } else {
            let response = try await Organizer.withRetry {
                try await LanguageModelSession(instructions: Organizer.parseInstructions(lang))
                    .respond(to: prompt, generating: GenResult.self, options: Organizer.options)
            }
            raw = response.content.items.map { (Kind($0.kind), $0.text, $0.quote, $0.cue) }
        }
        return raw.compactMap { kind, text, quote, evidence in
            let t = Aspect.sanitize(text)
            return t.isEmpty ? nil : Unit(kind: kind, text: t, quote: Aspect.sanitize(quote), evidence: evidence)
        }
    }

    private func check(_ u: Unit) async throws -> (kind: Kind, reasoning: String) {
        let zh = lang.resolved == .zhHant || lang.resolved == .zhHans
        let prompt = zh
            ? "原文：「\(u.quote.isEmpty ? u.text : u.quote)」\n這件事在使用者寫下這句話時，已經做完了嗎？"
            : "Text: \"\(u.quote.isEmpty ? u.text : u.quote)\"\nHad this already happened when the user wrote it?"
        if let cloud {
            let data = try await CloudClient.json(cloud, system: Organizer.checkInstructions(lang), prompt: prompt, schema: Organizer.checkSchema)
            let c = try JSONDecoder().decode(CloudCheck.self, from: data)
            return (Kind(rawValue: c.kind.lowercased()) ?? u.kind, c.reasoning)
        }
        let r = try await Organizer.withRetry {
            try await LanguageModelSession(instructions: Organizer.checkInstructions(lang))
                .respond(to: prompt, generating: GenCheck.self, options: Organizer.options)
        }
        return (Kind(r.content.kind), r.content.reasoning)
    }

    private struct CloudItems: Decodable {
        struct Item: Decodable { var kind: String; var text: String; var quote: String?; var evidence: String? }
        var items: [Item]
    }

    private struct CloudCheck: Decodable { var reasoning: String; var kind: String }
}

// MARK: - 觀察用的工具（純程式規則，不呼叫模型）

enum Aspect {
    enum Tense { case happened, notYet }

    private static let clauseBreak = try! NSRegularExpression(pattern: "(?=但是|但(?!願)|可是|不過|不过|然後|然后|還要|还要|順便|顺便|另外|\\bbut\\b|\\band also\\b)", options: .caseInsensitive)

    /// 依標點與換行切成子句；「但／然後／還要／順便」前面也切開（「bug 修好了但還沒部署」是兩件事）
    static func clauses(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: "\n，,；;。！？!?、"))
            .flatMap { piece -> [String] in
                let ns = piece as NSString
                let cuts = clauseBreak.matches(in: piece, range: NSRange(location: 0, length: ns.length)).map(\.range.location).filter { $0 > 0 }
                var parts: [String] = []
                var start = 0
                for c in cuts { parts.append(ns.substring(with: NSRange(location: start, length: c - start))); start = c }
                parts.append(ns.substring(from: start))
                return parts
            }
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•*0123456789. ")) }
            .filter { !$0.isEmpty }
    }

    /// 有沒有實質內容：中日文字數＋英文單字數×2 至少 4（「bug 修好了」中英夾雜也算）
    static func isContentful(_ s: String) -> Bool {
        let isCJK = { (c: Character) in c.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) } }
        let cjk = s.filter(isCJK).count
        let words = s.filter { !isCJK($0) }.split { !$0.isLetter && !$0.isNumber }.count
        if cjk == 0 { return words >= 3 }
        return cjk + words * 2 >= 4
    }

    private static let courtesy = ["謝謝大家", "感謝大家", "大家好", "謝謝", "感謝", "早安", "午安", "晚安", "哈哈", "好喔", "好的", "收到", "辛苦了", "不客氣", "嗨", "你好", "大家好",
                                   "谢谢", "感谢", "好哦", "thanks", "thank you", "good morning", "ok", "okay", "lol", "ありがとう", "おはよう"]

    /// 模型偶爾在字串裡接著寫 JSON 結尾或程式碼區塊：從第一個 } ] ``` 的位置截斷
    static func sanitize(_ s: String) -> String {
        var t = s
        for stop in ["}", "]", "```", "\\n", "\n"] {
            if let r = t.range(of: stop) { t = String(t[..<r.lowerBound]) }
        }
        // 太長通常是模型在自言自語：只留第一句
        if t.count > 100, let r = t.range(of: #"[。.!！?？]"#, options: .regularExpression) {
            t = String(t[...r.lowerBound])
        }
        return t.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"」「")))
    }

    private static let metaPhrases = ["無新內容", "沒有新內容", "無實質內容", "沒有實質內容", "內容尚未", "尚未列出", "未明確列出", "請提供", "請輸入",
                                      "无实质内容", "没有实质内容", "no real content", "no content", "nothing to list"]
    /// 模型在描述自己的輸出，而不是使用者的事
    static func isMeta(_ s: String) -> Bool {
        let l = s.lowercased()
        return metaPhrases.contains { l.contains($0) }
    }

    private static let metric = try! NSRegularExpression(pattern: "\\d+(\\.\\d+)?\\s*(%|％|萬|万|元|k\\b|K\\b)")
    private static let change = try! NSRegularExpression(pattern: "降|升|成長|成长|增長|增长|增加|減少|减少|下滑|dropped|rose|grew|fell|increased|decreased", options: .caseInsensitive)
    /// 數據變化：「當機率降到 0.4%」「營收成長 12%」
    static func isMetricChange(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        return metric.firstMatch(in: s, range: r) != nil && change.firstMatch(in: s, range: r) != nil
    }

    private static let decision = try! NSRegularExpression(pattern: "^(會議|会议)?(結論|结论|決定|决定|決議|决议)|^(we |team )?(agreed|decided)", options: .caseInsensitive)
    private static let selfAction = try! NSRegularExpression(pattern: "我要|要我|我得|我會|我会|\\bI (need|will|have to)\\b", options: .caseInsensitive)
    /// 決策或結論本身是資訊；寫明「我要／要我」的才是待辦
    static func isDecision(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-•*0123456789. "))
        if let r = t.range(of: #"^[^:：]{1,12}[:：]\s*"#, options: .regularExpression), !t[r].contains("結論"), !t[r].contains("决定") { t.removeSubrange(r) }
        let r = NSRange(t.startIndex..., in: t)
        return decision.firstMatch(in: t, range: r) != nil && selfAction.firstMatch(in: t, range: r) == nil
    }

    /// 有數字（數據、金額、比例）的通常是筆記，不用再確認時態
    static func hasNumber(_ s: String) -> Bool { s.contains { $0.isNumber } }

    /// 連接多件事的詞：一句裡有這些，通常是兩件以上的事
    private static let connectors = try! NSRegularExpression(pattern: "順便|顺便|還要|还要|然後|然后|另外|並且|并且|同時|也要|\\b(and also|but still|then|also need)\\b", options: .caseInsensitive)
    static func hasConnector(_ s: String) -> Bool {
        connectors.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// 這一項對應的原文那一行（用引用與改寫找最像的一行）
    static func bestLine(for u: ReActParser.Unit, in chunk: String) -> String {
        let lines = chunk.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let key = u.quote + u.text
        return lines.max { Organizer.similarity($0, key) < Organizer.similarity($1, key) } ?? u.quote
    }

    /// 去掉寒暄詞、標點、說話者後，幾乎沒剩字就是雜訊
    static func isNoise(_ s: String) -> Bool {
        var t = s.lowercased()
        if let r = t.range(of: #"^[^:：]{1,12}[:：]"#, options: .regularExpression) { t.removeSubrange(r) }
        for w in courtesy { t = t.replacingOccurrences(of: w, with: "") }
        let left = t.filter { $0.isLetter || $0.isNumber }
        return left.count < 2
    }

    // 已完成／未完成的線索。「了」要排除「忘了、為了、除了、了解、受不了、來不及了」等不是完成的用法
    private static let zhDone = try! NSRegularExpression(pattern: "(?<!忘|為|除|不|來不及)了(?!解)|已經|已(?!排定|預約)|剛剛|剛|終於|搞定|完畢|（完成）|\\(完成\\)|（已|过了|過了|好了|[開看寫做改跑填聊吃]完(?!成|後|之後|再)")
    private static let zhNotYet = try! NSRegularExpression(pattern: "要|得(?=[把趕去做])|需要|記得|记得|還沒|还没|尚未|待會|待会|晚點|晚点|答應|答应|說好|说好|預計|预计|打算|準備|准备|之後|之后|以後|以后|明天|後天|后天|下週|下周|下禮拜|下個月|下个月|月底|TODO|請你|请你|麻煩|麻烦|幫我|帮我|希望|提醒|前(把|要|完成|給|给|交|寄|提供|回)|(週|周|禮拜|星期)[一二三四五六日天](之)?前|下班前|之前")
    private static let enDone = try! NSRegularExpression(pattern: "\\b(done|finished|fixed|sent|shipped|completed|booked|merged|deployed|already|just)\\b", options: .caseInsensitive)
    private static let enNotYet = try! NSRegularExpression(pattern: "\\b(need to|needs to|will|by (mon|tue|wed|thu|fri|sat|sun|tomorrow|next|end)|tomorrow|next week|remember|promised|plan to|going to|haven't|hasn't|not yet|still need|pending|todo|to-do|please)\\b", options: .caseInsensitive)
    private static let jaDone = try! NSRegularExpression(pattern: "ました|済み|完了|終わった|した。|した$")
    private static let jaNotYet = try! NSRegularExpression(pattern: "までに|予定|明日|来週|します|する$|しなきゃ|まだ")

    /// 只有一邊的線索時回傳該時態；兩邊都有或都沒有回傳 nil（交給模型判斷）
    static func tense(_ s: String, lang: AppLanguage) -> Tense? {
        let r = NSRange(s.startIndex..., in: s)
        let (d, n): (NSRegularExpression, NSRegularExpression)
        switch lang.resolved {
        case .ja: (d, n) = (jaDone, jaNotYet)
        case .en: (d, n) = (enDone, enNotYet)
        default: (d, n) = (zhDone, zhNotYet)
        }
        let done = d.firstMatch(in: s, range: r) != nil
        let notYet = n.firstMatch(in: s, range: r) != nil
        if done == notYet { return nil }
        return done ? .happened : .notYet
    }
}
