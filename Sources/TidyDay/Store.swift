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
    /// 是否置頂
    var pinned: Bool?

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
    @Published private(set) var canUndo = false
    private var undoSnapshot: (day: String, log: DayLog)?
    let dir: URL

    nonisolated private static let keyFormatter: DateFormatter = {
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
        days = readAll()
        backfillDueDates()
    }

    private func readAll() -> [String: DayLog] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var result: [String: DayLog] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let log = try? decoder.decode(DayLog.self, from: data) else { continue }
            result[url.deletingPathExtension().lastPathComponent] = log
        }
        return result
    }

    /// 重新讀取資料夾：別的程序（MCP 伺服器）改過檔案後呼叫
    func reload() {
        let fresh = readAll()
        // 內容沒變就不發布，避免自己存檔觸發的事件讓畫面重畫
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        func same(_ a: DayLog?, _ b: DayLog?) -> Bool {
            (a.flatMap { try? encoder.encode($0) }) == (b.flatMap { try? encoder.encode($0) })
        }
        let keys = Set(fresh.keys).union(days.keys)
        guard keys.contains(where: { !same(fresh[$0], days[$0]) }) else { return }
        days = fresh
    }

    private var watcher: DispatchSourceFileSystemObject?

    /// 監看資料夾：MCP 伺服器（另一個程序）寫入時，app 跟著更新，避免之後存檔把對方的修改蓋掉
    func watchForExternalChanges() {
        guard watcher == nil else { return }
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// 依 ID 找項目（跨所有日期）
    func find(_ id: UUID) -> DayEntry? {
        for (d, log) in days {
            if let e = log.entries.first(where: { $0.id == id }) { return DayEntry(day: d, entry: e) }
        }
        return nil
    }

    /// 行事曆功能加入前建立的項目沒有時間：今天建立的補抓一次（舊項目的「明天」不能用今天重算，所以只補今天的）
    private func backfillDueDates() {
        let today = Self.today
        guard var log = days[today] else { return }
        var changed = false
        let rawLines = log.raw.flatMap { $0.text.components(separatedBy: .newlines) }
        for i in log.entries.indices {
            let e = log.entries[i]
            guard e.due == nil, Calendar.current.isDateInToday(e.createdAt) else { continue }
            // 也看當天貼上的原文：模型可能把「今天」拿掉了
            let source = rawLines.max { Organizer.similarity($0, e.text) < Organizer.similarity($1, e.text) }
                .flatMap { Organizer.similarity($0, e.text) >= 0.3 ? $0 : nil }
            guard let hint = DateHint.detect(e.text, kind: e.kind) ?? source.flatMap({ DateHint.detect($0, kind: e.kind) })
            else { continue }
            log.entries[i].due = hint.date
            log.entries[i].allDay = hint.allDay
            changed = true
        }
        if changed {
            days[today] = log
            save(today)
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
    /// 選單列徽章與「待辦」標題都用這個數字，兩者永遠一致；置頂項目排在最前面
    func actionableTodos(on day: String) -> [DayEntry] {
        let endOfDay = Calendar.current.date(byAdding: .day, value: 1, to: Store.date(day)) ?? Store.date(day)
        let list = openTodos(upTo: day).filter { ($0.entry.due ?? .distantPast) < endOfDay }
        return list.enumerated().sorted { a, b in
            let pa = a.element.entry.pinned == true
            let pb = b.element.entry.pinned == true
            return pa != pb ? pa : a.offset < b.offset
        }.map(\.element)
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
        let list = (days[day]?.entries ?? []).filter { $0.kind == .note && $0.due == nil }.map { DayEntry(day: day, entry: $0) }
        return list.enumerated().sorted { a, b in
            let pa = a.element.entry.pinned == true
            let pb = b.element.entry.pinned == true
            return pa != pb ? pa : a.offset < b.offset
        }.map(\.element)
    }

    /// 跨日搜尋所有項目（由新到舊）
    func search(_ query: String) -> [DayEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return days.keys.sorted(by: >).flatMap { d in
            (days[d]?.entries ?? []).filter { $0.text.localizedStandardContains(q) }.map { DayEntry(day: d, entry: $0) }
        }
    }

    func summary(on day: String) -> String? { days[day]?.summary }

    // MARK: - 修改

    private func recordUndo(for day: String) {
        undoSnapshot = (day, days[day] ?? DayLog())
        canUndo = true
    }

    func performUndo() -> Bool {
        guard let snap = undoSnapshot else { return false }
        days[snap.day] = snap.log.entries.isEmpty && snap.log.summary == nil && snap.log.raw.isEmpty ? nil : snap.log
        save(snap.day)
        undoSnapshot = nil
        canUndo = false
        return true
    }

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
        recordUndo(for: item.day)
        mutate(item) { e in
            e.doneAt = (e.kind == .todo && kind == .done) ? Date() : nil
            e.kind = kind
        }
    }

    func togglePin(for item: DayEntry) {
        mutate(item) { e in
            e.pinned = (e.pinned == true) ? nil : true
        }
    }

    func setDue(_ date: Date?, allDay: Bool = true, for item: DayEntry) {
        mutate(item) { e in
            e.due = date
            e.allDay = date == nil ? nil : allDay
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
        recordUndo(for: item.day)
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

    @discardableResult
    func addEntry(_ kind: Kind, text: String, to day: String) -> Entry? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var log = days[day] ?? DayLog()
        let entry = Entry(kind: kind, text: t)
        log.entries.append(entry)
        days[day] = log
        save(day)
        return entry
    }

    /// 只清掉這一天自己的檔案；之前幾天延續過來的待辦不受影響
    /// 清除一天：檔案丟到垃圾桶（Finder 還救得回來），回傳被清掉的內容給「復原」用
    @discardableResult
    func clearDay(_ day: String) -> DayLog? {
        recordUndo(for: day)
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
        undoSnapshot = nil
        canUndo = false
    }

    /// 日期選單用：每天「點進去會看到、屬於那天」的項目數（新到舊）
    /// - 已完成：算在完成的那天（doneAt），不是記下的那天
    /// - 待辦、筆記：有日期的算在排定的那天，沒日期的算在記下的那天
    /// - 從前幾天延續過來的待辦不重複計算
    /// 只有總結、沒有項目的日子 count 為 0、hasSummary 為 true
    /// 只列到今天為止；排到未來的事項在行事曆看
    var recordedDays: [(day: String, count: Int, hasSummary: Bool)] {
        var counts: [String: Int] = [:]
        for (d, log) in days {
            for e in log.entries {
                let owner: String
                if e.kind == .done {
                    owner = e.doneAt.map(Store.key) ?? d
                } else {
                    owner = e.due.map(Store.key) ?? d
                }
                counts[owner, default: 0] += 1
            }
        }
        for (d, log) in days where log.summary != nil && counts[d] == nil { counts[d] = 0 }
        let today = Store.today
        return counts.keys.filter { $0 <= today }.sorted(by: >).map { d in (d, counts[d]!, days[d]?.summary != nil) }
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
        // 匯出包含當天全部筆記（含帶有日期的筆記），不會因為放在行事曆而遺漏
        let allDayNotes = (days[day]?.entries ?? []).filter { $0.kind == .note }.map { DayEntry(day: day, entry: $0) }
        let sections: [(String, [DayEntry], String)] = [
            (s.done, completed(on: day), "- "),
            (s.todo, openTodos(upTo: day), "- [ ] "),
            (s.note, allDayNotes, "- "),
        ]
        for (name, items, bullet) in sections where !items.isEmpty {
            let lines = items.map { item -> String in
                var line = bullet + item.entry.text
                if item.entry.kind != .done, let due = item.entry.due,
                   let label = DueChip.label(due, allDay: item.entry.allDay ?? true, locale: lang.locale),
                   !item.entry.text.contains(label) {
                    line += " (\(label))"
                }
                return line
            }
            md += "\n## \(name)\n" + lines.joined(separator: "\n") + "\n"
        }
        return md
    }
}
