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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("TidyDay/days", isDirectory: true)
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

    /// 在 day 當天完成的事：當天直接記的 done，加上任何一天的待辦在當天被勾掉
    func completed(on day: String) -> [DayEntry] {
        days.keys.sorted().flatMap { d in
            days[d]!.entries.filter { e in
                e.kind == .done && (e.doneAt.map(Store.key) ?? d) == day
            }.map { DayEntry(day: d, entry: $0) }
        }
    }

    func notes(on day: String) -> [DayEntry] {
        (days[day]?.entries ?? []).filter { $0.kind == .note }.map { DayEntry(day: day, entry: $0) }
    }

    func summary(on day: String) -> String? { days[day]?.summary }

    // MARK: - 修改

    func apply(_ output: ParseOutput, raw: String, to day: String, openTodos: [DayEntry]) {
        var log = days[day] ?? DayLog()
        log.raw.append(RawPaste(at: Date(), text: raw))
        log.entries += output.items.map { Entry(kind: $0.kind, text: $0.text) }
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
        mutate(item) { $0.text = t }
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
