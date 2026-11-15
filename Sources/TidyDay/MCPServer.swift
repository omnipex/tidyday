import Foundation

/// MCP（Model Context Protocol）伺服器：`TidyDay --mcp` 以 stdio 收發 JSON-RPC（一行一則訊息），
/// 讓 Claude Desktop、Claude Code、Cursor 等 MCP 客戶端讀寫 TidyDay 的紀錄。
///
/// 和 app 共用同一個資料夾（含 TIDYDAY_DATA_DIR）與設定（整理引擎、語言）。每次呼叫工具前重新讀檔；
/// app 那邊監看資料夾（Store.watchForExternalChanges），所以兩邊同時開著也不會互相覆蓋。
/// stdout 只能放協定訊息，記錄一律寫到 stderr。
@MainActor
final class MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let store = Store()

    static func run() -> Never {
        let server = MCPServer()
        Task { @MainActor in
            do {
                for try await line in FileHandle.standardInput.bytes.lines {
                    await server.handle(line)
                }
            } catch {
                log("stdin error: \(error)")
            }
            exit(0)
        }
        dispatchMain()
    }

    nonisolated static func log(_ message: String) {
        FileHandle.standardError.write(Data("[tidyday-mcp] \(message)\n".utf8))
    }

    // MARK: - JSON-RPC

    private struct RPCError: Error {
        var code: Int
        var message: String
        static func invalidParams(_ m: String) -> RPCError { RPCError(code: -32602, message: m) }
    }

    /// 工具執行失敗（參數錯、找不到項目）：依 MCP 規範放在結果裡（isError），讓模型看得到原因
    private struct ToolError: Error {
        var message: String
        init(_ message: String) { self.message = message }
    }

    func handle(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        let id = obj["id"]
        guard let method = obj["method"] as? String else { return }  // 客戶端回應我們的請求：我們不發請求，忽略
        let params = obj["params"] as? [String: Any] ?? [:]
        do {
            let result = try await dispatch(method, params)
            if let id { send(["jsonrpc": "2.0", "id": id, "result": result]) }
        } catch let e as RPCError {
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": e.code, "message": e.message]]) }
        } catch {
            if let id { send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]]) }
        }
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    private func dispatch(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "tidyday", "title": "TidyDay", "version": appVersion],
                "instructions": Self.instructions,
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": Self.tools]
        case "tools/call":
            guard let name = params["name"] as? String else { throw RPCError.invalidParams("Missing tool name") }
            let args = params["arguments"] as? [String: Any] ?? [:]
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else {
                throw RPCError.invalidParams("Unknown tool: \(name)")
            }
            store.reload()
            do {
                return textResult(try await call(name, args))
            } catch let e as ToolError {
                return textResult(["error": e.message], isError: true)
            }
        default:
            if method.hasPrefix("notifications/") { return [:] }
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func textResult(_ value: Any, isError: Bool = false) -> [String: Any] {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
        if isError { result["isError"] = true }
        return result
    }

    // MARK: - 工具

    private static let instructions = """
    TidyDay is the user's personal daily work log. Each day holds to-dos, done items and notes, plus an optional summary. \
    Days are "yyyy-MM-dd" in the user's local time zone; omit `day` to mean today. \
    Open to-dos carry over to later days until completed. Items that mention a date are scheduled for that date. \
    Use organize_text for free-form text (chat logs, meeting notes): TidyDay splits it into items with its own model. \
    Use add_items when you already know each item's kind and text. Item ids come from get_day, search and add_items.
    """

    private static let dayProp: [String: Any] = ["type": "string", "description": "Day as yyyy-MM-dd (local time). Defaults to today."]
    private static let kindProp: [String: Any] = ["type": "string", "enum": ["todo", "done", "note"]]

    private static func tool(_ name: String, _ title: String, _ description: String,
                             _ properties: [String: Any] = [:], required: [String] = [],
                             readOnly: Bool = false, destructive: Bool = false) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return [
            "name": name, "title": title, "description": description, "inputSchema": schema,
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive, "openWorldHint": false],
        ]
    }

    static let tools: [[String: Any]] = [
        tool("list_days", "List days",
             "Days up to today that have something on them, newest first, with how many items belong to each day.",
             readOnly: true),
        tool("get_day", "Get a day",
             "Everything shown for one day: actionable to-dos (including ones carried over from earlier days and ones due that day), items completed that day, undated notes, items scheduled for that day, and the summary.",
             ["day": dayProp], readOnly: true),
        tool("search", "Search items",
             "Find items whose text contains the query, across all days, newest first.",
             ["query": ["type": "string"], "limit": ["type": "integer", "description": "Default 50."]],
             required: ["query"], readOnly: true),
        tool("add_items", "Add items",
             "Add items with a known kind. A date mentioned in the text (e.g. \"tomorrow 3pm\") schedules the item automatically; pass `due` to set it explicitly.",
             ["day": dayProp,
              "items": ["type": "array", "items": [
                "type": "object",
                "properties": [
                    "kind": kindProp,
                    "text": ["type": "string"],
                    "due": ["type": "string", "description": "yyyy-MM-dd for all-day, or ISO 8601 date-time."],
                ],
                "required": ["kind", "text"],
              ]]],
             required: ["items"]),
        tool("organize_text", "Organize text",
             "Paste free-form text (chat log, meeting notes, thoughts). TidyDay splits it into to-dos, done items and notes with the engine the user picked in settings, and marks existing to-dos the text says are finished. Slower than add_items.",
             ["text": ["type": "string"], "day": dayProp], required: ["text"]),
        tool("update_item", "Update an item",
             "Change an item. Set kind to \"done\" to complete a to-do, or \"todo\" to reopen it. Pass due as an empty string to unschedule.",
             ["id": ["type": "string"], "text": ["type": "string"], "kind": kindProp,
              "pinned": ["type": "boolean"],
              "due": ["type": "string", "description": "yyyy-MM-dd for all-day, ISO 8601 date-time, or \"\" to clear."]],
             required: ["id"]),
        tool("delete_item", "Delete an item", "Delete one item permanently.",
             ["id": ["type": "string"]], required: ["id"], destructive: true),
        tool("set_summary", "Set the summary", "Replace a day's summary. An empty string removes it.",
             ["day": dayProp, "summary": ["type": "string"]], required: ["summary"], destructive: true),
    ]

    private func call(_ name: String, _ args: [String: Any]) async throws -> Any {
        switch name {
        case "list_days":
            return store.recordedDays.map { d -> [String: Any] in
                ["day": d.day, "items": d.count, "hasSummary": d.hasSummary]
            }

        case "get_day":
            let day = try dayArg(args)
            let todos = store.actionableTodos(on: day)
            // 查未來的日子時，到期的待辦同時在 todos 和行事曆裡：每一筆只列一次
            let todoIDs = Set(todos.map(\.id))
            let scheduled = (store.scheduledByDay()[Store.date(day)] ?? []).filter { !todoIDs.contains($0.id) }
            return [
                "day": day,
                "summary": store.summary(on: day) ?? NSNull(),
                "todos": todos.map(json),
                "done": store.completed(on: day).map(json),
                "notes": store.notes(on: day).map(json),
                "scheduled": scheduled.map(json),
            ] as [String: Any]

        case "search":
            let query = try string(args, "query")
            let limit = max(1, args["limit"] as? Int ?? 50)
            return store.search(query).prefix(limit).map(json)

        case "add_items":
            let day = try dayArg(args)
            guard let items = args["items"] as? [[String: Any]], !items.isEmpty else { throw ToolError("items must be a non-empty array") }
            // 先全部檢查，避免加到一半失敗
            let parsed = try items.map { item -> (Kind, String, (Date, Bool)?) in
                guard let k = (item["kind"] as? String).flatMap(Kind.init(rawValue:)) else { throw ToolError("kind must be todo, done or note") }
                let text = (item["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw ToolError("text must not be empty") }
                let due = try (item["due"] as? String).flatMap { $0.isEmpty ? nil : try parseDue($0) }
                return (k, text, due)
            }
            var added: [DayEntry] = []
            for (k, text, due) in parsed {
                guard let e = store.addEntry(k, text: text, to: day) else { continue }
                var item = DayEntry(day: day, entry: e)
                if let due {
                    store.setDue(due.0, allDay: due.1, for: item)
                    item = store.find(e.id) ?? item
                }
                added.append(item)
            }
            return ["added": added.map(json)]

        case "organize_text":
            let text = try string(args, "text")
            let day = try dayArg(args)
            let lang = AppLanguage.current
            let engine = Engine.current
            if let reason = Organizer.unavailableReason(lang.strings, engine: engine) {
                throw ToolError("TidyDay's organizer is unavailable (\(reason)). Use add_items instead.")
            }
            let todos = store.openTodos(upTo: day)
            let before = Set(store.days[day]?.entries.map(\.id) ?? [])
            let output: ParseOutput
            do {
                output = try await Organizer.parse(text, openTodos: todos.map(\.entry.text), lang: lang, engine: engine)
            } catch {
                throw ToolError("Organizing failed: \(error.localizedDescription). Nothing was saved; use add_items instead.")
            }
            store.apply(output, raw: text, to: day, openTodos: todos)
            let added = (store.days[day]?.entries ?? []).filter { !before.contains($0.id) }.map { DayEntry(day: day, entry: $0) }
            let completed = output.completedTodoIndexes.sorted().compactMap { $0 < todos.count ? store.find(todos[$0].id) : nil }
            return ["added": added.map(json), "completedExisting": completed.map(json)] as [String: Any]

        case "update_item":
            var item = try itemArg(args)
            if let text = args["text"] as? String {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("text must not be empty") }
                store.setText(text, for: item)
            }
            if let raw = args["kind"] as? String {
                guard let k = Kind(rawValue: raw) else { throw ToolError("kind must be todo, done or note") }
                if k != item.entry.kind { store.setKind(k, for: store.find(item.id) ?? item) }
            }
            if let pinned = args["pinned"] as? Bool, pinned != (item.entry.pinned == true) {
                store.togglePin(for: store.find(item.id) ?? item)
            }
            if let raw = args["due"] as? String {
                let due = raw.isEmpty ? nil : try parseDue(raw)
                store.setDue(due?.0, allDay: due?.1 ?? true, for: store.find(item.id) ?? item)
            }
            item = store.find(item.id) ?? item
            return json(item)

        case "delete_item":
            let item = try itemArg(args)
            store.delete(item)
            return ["deleted": item.id.uuidString]

        case "set_summary":
            let day = try dayArg(args)
            guard let summary = args["summary"] as? String else { throw ToolError("summary is required") }
            store.setSummary(summary, for: day)
            return ["day": day, "summary": store.summary(on: day) ?? NSNull()] as [String: Any]

        default:
            throw ToolError("Unknown tool: \(name)")
        }
    }

    // MARK: - 參數與輸出

    private func string(_ args: [String: Any], _ key: String) throws -> String {
        let v = (args[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { throw ToolError("\(key) is required") }
        return v
    }

    private func dayArg(_ args: [String: Any]) throws -> String {
        guard let raw = args["day"] as? String, !raw.isEmpty else { return Store.today }
        guard Self.isDayKey(raw) else {
            throw ToolError("day must be yyyy-MM-dd, got \"\(raw)\"")
        }
        return raw
    }

    /// 嚴格檢查 yyyy-MM-dd（DateFormatter 會接受 2026-13-40 之類再自動進位，所以轉回字串比對）
    private static func isDayKey(_ raw: String) -> Bool {
        raw.count == 10 && raw.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil
            && Store.key(Store.date(raw)) == raw
    }

    private func itemArg(_ args: [String: Any]) throws -> DayEntry {
        let raw = try string(args, "id")
        guard let id = UUID(uuidString: raw) else { throw ToolError("id is not a valid item id") }
        guard let item = store.find(id) else { throw ToolError("No item with id \(raw)") }
        return item
    }

    /// yyyy-MM-dd → 整天；ISO 8601（有沒有秒、時區都可以）→ 指定時間
    private func parseDue(_ raw: String) throws -> (Date, Bool) {
        if Self.isDayKey(raw) {
            return (Store.date(raw), true)
        }
        let f = ISO8601DateFormatter()
        for opts: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            f.formatOptions = opts
            if let d = f.date(from: raw) { return (d, false) }
        }
        // 沒寫時區：當成本地時間
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: raw) { return (d, false) }
        }
        throw ToolError("due must be yyyy-MM-dd or an ISO 8601 date-time, got \"\(raw)\"")
    }

    private static let isoLocal: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func json(_ item: DayEntry) -> [String: Any] {
        let e = item.entry
        var o: [String: Any] = [
            "id": e.id.uuidString,
            "kind": e.kind.rawValue,
            "text": e.text,
            "recordedOn": item.day,
            "createdAt": Self.isoLocal.string(from: e.createdAt),
        ]
        if let due = e.due {
            o["due"] = e.allDay == false ? Self.isoLocal.string(from: due) : Store.key(due)
        }
        if let doneAt = e.doneAt { o["doneAt"] = Self.isoLocal.string(from: doneAt) }
        if e.pinned == true { o["pinned"] = true }
        return o
    }
}
