import Foundation

enum Kind: String, Codable, CaseIterable {
    case done, todo, note
}

struct Entry: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: Kind
    var text: String
    var createdAt = Date()
    /// 待辦被勾選完成的時間；直接記成 done 的項目為 nil
    var doneAt: Date?
    /// 文字裡提到的時間（建立當下解析，所以隔天再看，「明天」仍指原本那天）
    var due: Date?
    var allDay: Bool?
    /// 已加入行事曆的事件 ID
    var eventID: String?

    /// source：貼上的原文那一行。項目文字裡沒有時間（模型把「今天」拿掉了）時，改從原文抓
    init(kind: Kind, text: String, source: String? = nil) {
        self.kind = kind
        self.text = text
        // 待辦與筆記都抓時間（「今天去李大師那」常被歸成筆記）；已完成的不用
        // 從原文那一行補抓只給待辦：筆記沒寫時間時，不該繼承同一行別的事的日期（「今天開完週會，決定延後上線」）
        if let hint = DateHint.detect(text, kind: kind) ?? (kind == .todo ? source.flatMap({ DateHint.detect($0, kind: kind) }) : nil) {
            due = hint.date
            allDay = hint.allDay
        }
    }
}

struct RawPaste: Codable {
    var at: Date
    var text: String
}

struct DayLog: Codable {
    var entries: [Entry] = []
    var raw: [RawPaste] = []
    var summary: String?
}

/// 某一天檔案裡的一筆項目
struct DayEntry: Identifiable {
    var day: String
    var entry: Entry
    var id: UUID { entry.id }
}

/// 每天一個 JSON：~/Library/Application Support/TidyDay/days/yyyy-MM-dd.json
@MainActor
final class Store: ObservableObject {
    @Published private(set) var days: [String: DayLog] = [:]
    let dir: URL

    nonisolated(unsafe) private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated static func key(_ date: Date) -> String { keyFormatter.string(from: date) }
    nonisolated static func date(_ key: String) -> Date { keyFormatter.date(from: key) ?? Date() }
    nonisolated static var today: String { key(Date()) }

    init() {
        // TIDYDAY_DATA_DIR：截圖或測試時改用另一個資料夾，不碰真實資料
        if let custom = ProcessInfo.processInfo.environment["TIDYDAY_DATA_DIR"] {
            dir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dir = base.appendingPathComponent("TidyDay/days", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let log = try? decoder.decode(DayLog.self, from: data) else { continue }
            days[url.deletingPathExtension().lastPathComponent] = log
        }
        backfillDueDates()
    }

    /// 行事曆功能加入前建立的項目沒有時間：今天建立的補抓一次（舊項目的「明天」不能用今天重算，所以只補今天的）
    private func backfillDueDates() {
        for (day, log) in days {
            var changed = false
            var log = log
            for i in log.entries.indices {
                let e = log.entries[i]
                guard e.due == nil, Calendar.current.isDateInToday(e.createdAt) else { continue }
                // 也看當天貼上的原文：模型可能把「今天」拿掉了
                let rawLines = log.raw.flatMap { $0.text.components(separatedBy: .newlines) }
                let source = rawLines.max { Organizer.similarity($0, e.text) < Organizer.similarity($1, e.text) }
                    .flatMap { Organizer.similarity($0, e.text) >= 0.3 ? $0 : nil }
                guard let hint = DateHint.detect(e.text, kind: e.kind) ?? source.flatMap({ DateHint.detect($0, kind: e.kind) })
                else { continue }
                log.entries[i].due = hint.date
                log.entries[i].allDay = hint.allDay
                changed = true
            }
            if changed {
                days[day] = log
                save(day)
            }
        }
    }

    private func save(_ day: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(days[day] ?? DayLog()) else { return }
        try? data.write(to: dir.appendingPathComponent("\(day).json"), options: .atomic)
    }

    // MARK: - 查詢

    /// 到 day 為止所有還沒完成的待辦（跨天累積）
    func openTodos(upTo day: String) -> [DayEntry] {
        days.keys.filter { $0 <= day }.sorted().flatMap { d in
            days[d]!.entries.filter { $0.kind == .todo }.map { DayEntry(day: d, entry: $0) }
        }
    }

    /// 「現在要處理」的待辦：沒寫日期的、這天到期的、已經過期的。排到之後的只放在行事曆（參考 Things 3 的 Today／Upcoming）。
    /// 選單列徽章與「待辦」標題都用這個數字，兩者永遠一致
    func actionableTodos(on day: String) -> [DayEntry] {
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Store.date(day)) ?? Store.date(day)
        return openTodos(upTo: day).filter { ($0.entry.due ?? .distantPast) < endOfDay }
    }

    /// 行事曆的「排程」，依日期分組（key 是那天的 00:00）：排到明天以後的待辦，以及有日期的筆記。
    /// 今天到期、過期的待辦在「待辦」區，已完成的在「已完成」區 —— 每一筆只出現在一個地方
    func scheduledByDay() -> [Date: [DayEntry]] {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        var result: [Date: [DayEntry]] = [:]
        for (d, log) in days {
            for e in log.entries {
                guard let due = e.due, e.kind != .done else { continue }
                if e.kind == .todo && due < tomorrow { continue }
                result[cal.startOfDay(for: due), default: []].append(DayEntry(day: d, entry: e))
            }
        }
        for k in result.keys { result[k]!.sort { ($0.entry.due ?? .distantPast) < ($1.entry.due ?? .distantPast) } }
        return result
    }

    /// 在 day 當天完成的事：當天直接記的 done，加上任何一天的待辦在當天被勾掉
    func completed(on day: String) -> [DayEntry] {
        days.keys.sorted().flatMap { d in
            days[d]!.entries.filter { e in
                e.kind == .done && (e.doneAt.map(Store.key) ?? d) == day
            }.map { DayEntry(day: d, entry: $0) }
        }
    }

    /// 筆記區只放沒有日期的筆記；有日期的放在行事曆，同一筆不會出現兩次
    func notes(on day: String) -> [DayEntry] {
        (days[day]?.entries ?? []).filter { $0.kind == .note && $0.due == nil }.map { DayEntry(day: day, entry: $0) }
    }

    func summary(on day: String) -> String? { days[day]?.summary }

    // MARK: - 修改

    func apply(_ output: ParseOutput, raw: String, to day: String, openTodos: [DayEntry]) {
        var log = days[day] ?? DayLog()
        log.raw.append(RawPaste(at: Date(), text: raw))
        log.entries += output.items.map { Entry(kind: $0.kind, text: $0.text, source: $0.source) }
        days[day] = log
        save(day)
        for i in output.completedTodoIndexes where i < openTodos.count {
            setKind(.done, for: openTodos[i])
        }
    }

    func addRawNote(_ raw: String, to day: String) {
        var log = days[day] ?? DayLog()
        log.raw.append(RawPaste(at: Date(), text: raw))
        log.entries.append(Entry(kind: .note, text: raw))
        days[day] = log
        save(day)
    }

    func setKind(_ kind: Kind, for item: DayEntry) {
        mutate(item) { e in
            e.doneAt = (e.kind == .todo && kind == .done) ? Date() : nil
            e.kind = kind
        }
    }

    func setText(_ text: String, for item: DayEntry) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate(item) { e in
            e.text = t
            // 今天建立、還沒加入行事曆的項目，改字後重新抓時間；舊項目的「明天」不能用今天重算
            if e.eventID == nil, Calendar.current.isDateInToday(e.createdAt) {
                let hint = DateHint.detect(t, kind: e.kind)
                e.due = hint?.date
                e.allDay = hint?.allDay
            }
        }
    }

    func setEventID(_ id: String, for item: DayEntry) {
        mutate(item) { $0.eventID = id }
    }

    func delete(_ item: DayEntry) {
        days[item.day]?.entries.removeAll { $0.id == item.id }
        save(item.day)
    }

    func setSummary(_ text: String?, for day: String) {
        var log = days[day] ?? DayLog()
        let t = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        log.summary = (t?.isEmpty ?? true) ? nil : t
        days[day] = log
        save(day)
    }

    func addEntry(_ kind: Kind, text: String, to day: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var log = days[day] ?? DayLog()
        log.entries.append(Entry(kind: kind, text: t))
        days[day] = log
        save(day)
    }

    /// 只清掉這一天自己的檔案；之前幾天延續過來的待辦不受影響
    /// 清除一天：檔案丟到垃圾桶（Finder 還救得回來），回傳被清掉的內容給「復原」用
    @discardableResult
    func clearDay(_ day: String) -> DayLog? {
        let removed = days[day]
        days[day] = nil
        let url = dir.appendingPathComponent("\(day).json")
        if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) == nil {
            try? FileManager.default.removeItem(at: url)
        }
        return removed
    }

    func restoreDay(_ day: String, _ log: DayLog) {
        days[day] = log
        save(day)
    }

    /// 有紀錄的日期（新到舊）與項目數
    var recordedDays: [(day: String, count: Int)] {
        days.keys.sorted(by: >).compactMap { d in
            let n = days[d]!.entries.count
            return n > 0 || days[d]!.summary != nil ? (d, n) : nil
        }
    }

    private func mutate(_ item: DayEntry, _ change: (inout Entry) -> Void) {
        guard let i = days[item.day]?.entries.firstIndex(where: { $0.id == item.id }) else { return }
        change(&days[item.day]!.entries[i])
        save(item.day)
    }

    // MARK: - 匯出

    func markdown(for day: String, lang: AppLanguage) -> String {
        let s = lang.strings
        var md = "# \(lang.dayTitle(day))\n"
        if let summary = summary(on: day) { md += "\n## \(s.summaryTitle)\n\(summary)\n" }
        let sections: [(String, [DayEntry], String)] = [
            (s.done, completed(on: day), "- "),
            (s.todo, openTodos(upTo: day), "- [ ] "),
            (s.note, notes(on: day), "- "),
        ]
        for (name, items, bullet) in sections where !items.isEmpty {
            md += "\n## \(name)\n" + items.map { bullet + $0.entry.text }.joined(separator: "\n") + "\n"
        }
        return md
    }
}
