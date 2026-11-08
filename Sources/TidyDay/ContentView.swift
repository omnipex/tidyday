import SwiftUI
import AppKit
import ServiceManagement

/// 參考 macOS 控制中心：背景是系統毛玻璃（透明），疊上半透明的層，藍色用系統藍
/// 不用 accentColor：按鈕停用時 macOS 會把它變灰
enum Theme {
    /// 輸入框、分頁軌道：半透明疊層，透出後面的毛玻璃
    static let field = adaptive(light: (0x000000, 0.04), dark: (0xFFFFFF, 0.06))
    static let card = adaptive(light: (0x000000, 0.05), dark: (0xFFFFFF, 0.06))
    static let segment = adaptive(light: (0xFFFFFF, 0.85), dark: (0xFFFFFF, 0.14))
    static let hover = Color.primary.opacity(0.07)
    static let stroke = Color.primary.opacity(0.10)
    static let accent = Color(nsColor: .systemBlue)
    static let radius: CGFloat = 10
    static let hairline = Color.primary.opacity(0.08)
    /// 面板底色：淺色模式在毛玻璃上疊一層白，後面是深色視窗時才不會整片發灰；深色模式維持透明
    static let panelTint = adaptive(light: (0xFFFFFF, 0.62), dark: (0x000000, 0.0))

    static func color(_ k: Kind) -> Color {
        switch k {
        case .todo: return Color(nsColor: .systemBlue)
        case .done: return Color(nsColor: .systemGreen)
        case .note: return Color(nsColor: .systemOrange)
        }
    }

    static func symbol(_ k: Kind) -> String {
        switch k {
        case .todo: return "list.bullet"
        case .done: return "checkmark"
        case .note: return "text.alignleft"
        }
    }

    private static func adaptive(light: (UInt32, CGFloat), dark: (UInt32, CGFloat)) -> Color {
        func ns(_ c: (UInt32, CGFloat)) -> NSColor {
            NSColor(srgbRed: CGFloat((c.0 >> 16) & 0xFF) / 255, green: CGFloat((c.0 >> 8) & 0xFF) / 255,
                    blue: CGFloat(c.0 & 0xFF) / 255, alpha: c.1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var day = Store.today
    @State private var tab: Kind = .todo
    @State private var input = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var editingSummary = false
    @State private var summaryText = ""
    @State private var summaryExpanded = false
    @State private var confirmClear = false
    @State private var undoClear: (day: String, log: DayLog)?
    @State private var showDays = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AppLanguage.storageKey) private var langRaw = AppLanguage.system.rawValue
    @AppStorage(Appearance.storageKey) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(Engine.storageKey) private var engineRaw = Engine.apple.rawValue
    @State private var showSettings = false
    @State private var addingKind: Kind?
    @AppStorage(GlobalHotKey.storageKey) private var hotKeyEnabled = true
    @AppStorage("layout") private var layoutRaw = "list"
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inputFocused: Bool

    private var isToday: Bool { day == Store.today }
    private var lang: AppLanguage { AppLanguage(rawValue: langRaw) ?? .system }
    private var s: Strings { lang.strings }

    private func items(_ kind: Kind) -> [DayEntry] {
        switch kind {
        case .todo: return store.actionableTodos(on: day)
        case .done: return store.completed(on: day)
        case .note: return store.notes(on: day)
        }
    }

    private var engine: Engine { Engine(rawValue: engineRaw) ?? .apple }
    private var isTabs: Bool { layoutRaw == "tabs" }
    private var collapsed: Set<Kind> { Set(collapsedRaw.split(separator: ",").compactMap { Kind(rawValue: String($0)) }) }

    var body: some View {
        Group {
            if showSettings {
                SettingsPanel { showSettings = false }
            } else {
                main
            }
        }
        .frame(width: 380, height: 640)
        .background(Theme.panelTint)
        .environment(\.appLanguage, lang)
        .environment(\.locale, lang.locale)
        .onAppear { Appearance(rawValue: appearanceRaw)?.apply() }
        .onChange(of: appearanceRaw) { _, v in Appearance(rawValue: v)?.apply() }
    }

    private var main: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
            separator.padding(.bottom, 12)
            if confirmClear {
                clearConfirmCard
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .transition(.opacity)
            }
            inputCard
                .padding(.horizontal, 16)
            if store.summary(on: day) != nil || editingSummary {
                summaryCard
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            if isTabs {
                CalendarCard()
                    .padding(.horizontal, 16).padding(.top, 12)
                tabs
                    .padding(.horizontal, 16).padding(.top, 14)
                list
            } else {
                sections
                    .padding(.top, 6)
            }
            footer
        }
        .onReceive(NotificationCenter.default.publisher(for: TidyMessage.name)) { n in
            if let text = n.userInfo?["text"] as? String {
                show(text, error: n.userInfo?["error"] as? Bool ?? false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: GlobalHotKey.focusInput)) { _ in
            // 快捷鍵叫出時：回到今天、游標放進輸入框
            showSettings = false
            day = Store.today
            inputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            day = Store.today
        }
        .onChange(of: day) { _, _ in
            addingKind = nil
            editingSummary = false
            confirmClear = false
            summaryExpanded = false
            message = nil
        }
    }

    /// 控制中心風格的細分隔線，左右留邊
    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1).padding(.horizontal, 16)
    }

    // MARK: - 頂部：日期與設定

    private var header: some View {
        // 一行：日期可以被截斷，膠囊和圖示固定寬度、不會被壓扁
        HStack(alignment: .center, spacing: 2) {
            Button { showDays.toggle() } label: {
                HStack(spacing: 5) {
                    headerText(for: day)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDays, arrowEdge: .bottom) { dayPicker }

            Spacer(minLength: 8)
            engineChip
                .fixedSize()
                .padding(.trailing, 4)
            if !isToday {
                IconButton(systemName: "arrow.uturn.backward", help: s.backToToday + "（⌘T）") { day = Store.today }
                    .keyboardShortcut("t", modifiers: .command)
                    .transition(.opacity)
            }
            IconButton(systemName: "chevron.left", help: s.prevDay) { shiftDay(-1) }
            IconButton(systemName: "chevron.right", help: s.nextDay) { shiftDay(1) }
                .disabled(isToday)
                .opacity(isToday ? 0.35 : 1)
            // 依目前實際的深淺色顯示相反的圖示：淺色時是月亮，點了切到深色
            IconButton(systemName: colorScheme == .dark ? "sun.max" : "moon", help: s.toggleTheme) {
                appearanceRaw = (colorScheme == .dark ? Appearance.light : .dark).rawValue
            }
            Menu {
                Button(s.modelSettings + "…") { showSettings = true }
                Picker(s.layout, selection: $layoutRaw) {
                    Text(s.layoutList).tag("list")
                    Text(s.layoutTabs).tag("tabs")
                }
                Picker(s.appearance, selection: $appearanceRaw) {
                    ForEach(Appearance.allCases) { a in Text(a.label(s)).tag(a.rawValue) }
                }
                Divider()
                Toggle(s.launchAtLogin, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                Toggle(s.globalHotKey, isOn: $hotKeyEnabled)
                    .onChange(of: hotKeyEnabled) { _, _ in GlobalHotKey.shared.apply() }
                Picker(s.language, selection: $langRaw) {
                    ForEach(AppLanguage.allCases) { l in
                        Text(l == .system ? s.followSystem : l.nativeName).tag(l.rawValue)
                    }
                }
                Button(s.openFolder) { NSWorkspace.shared.open(store.dir) }
                Divider()
                Button(s.clearDayMenu(lang.shortDate(day))) { withAnimation { confirmClear = true } }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(s.settings)
        }
    }

    /// 日期選單：只列有紀錄的日子；回到今天改由標題列的 icon 負責
    private var dayPicker: some View {
        let days = store.recordedDays
        return Group {
            if days.isEmpty {
                Text(s.none).font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(days, id: \.day) { d in
                            DayPickerRow(title: pickerTitle(for: d.day), detail: s.itemCount(d.count), selected: d.day == day) {
                                day = d.day; showDays = false
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
                .padding(8)
            }
        }
        .frame(width: 230)
    }

    // MARK: - 輸入

    /// 輸入列：參考 Fantastical 選單列小視窗與 Todoist Quick Add —— 平常只有一行，按鈕放在框內；
    /// 貼上多行時自動長高（最多 6 行）。空的時候右側是「貼上」，有字時變成送出鍵（Enter 或 ⌘↩）
    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 22)
                TextField(isToday ? s.placeholderToday : s.placeholderPast(lang.shortDate(day)),
                          text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit { if !input.isEmpty && !busy { organize() } }
                    .frame(minHeight: 22)
                    .disabled(busy)
                inputAction
            }
            .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.field))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(inputFocused ? Theme.accent.opacity(0.9) : Theme.stroke,
                                  lineWidth: inputFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: inputFocused)

            if let message {
                HStack(spacing: 8) {
                    Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(isError ? Color.orange : .secondary)
                    if let undo = undoClear {
                        Button(s.undo) {
                            store.restoreDay(undo.day, undo.log)
                            undoClear = nil
                            show(s.restored)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var inputAction: some View {
        if busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(s.organizing).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(height: 24).padding(.horizontal, 6)
        } else if input.isEmpty {
            Button(action: pasteAndOrganize) {
                Label(s.paste, systemImage: "doc.on.clipboard")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.accent.opacity(0.13)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help(s.pasteHelp)
        } else {
            HStack(spacing: 2) {
                IconButton(systemName: "xmark", help: s.clear, size: 22) { input = "" }
                Button(action: organize) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: .command)
                .help(s.organizeHelp)
            }
        }
    }

    /// 清除確認：放在最上面，紅色卡片，寫清楚會刪掉什麼
    private var clearConfirmCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(s.confirmClear(lang.shortDate(day)), systemImage: "trash")
                .font(.system(size: 13, weight: .semibold))
            Text(s.confirmClearDetail)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(s.cancel) { withAnimation { confirmClear = false } }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                Button(s.clearAction) {
                    let target = day
                    let removed = store.clearDay(target)
                    withAnimation { confirmClear = false }
                    show(s.cleared(lang.shortDate(target)))
                    undoClear = removed.map { (target, $0) }
                }
                .buttonStyle(DestructiveButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color.red.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Color.red.opacity(0.35)))
    }

    /// 目前用哪個模型整理：放在標題列圖示左邊的小膠囊，雲端引擎用雲朵提醒內容會送出去，點一下進設定
    private var engineChip: some View {
        let c = CloudConfig.load(engine)
        let name = engine == .apple ? s.engineShort : (engine.brand ?? "")
        let full = engine == .apple ? s.engineApple : "\(engine.brand ?? "") · \(c.model.isEmpty ? "—" : c.model)"
        return Button { showSettings = true } label: {
            HStack(spacing: 4) {
                Image(systemName: c.isOnDevice ? "lock.shield" : "cloud")
                Text(name).lineLimit(1)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Theme.card))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(s.modelSettings)：\(full)")
    }

    // MARK: - 總結

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(s.summaryTitle, systemImage: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                if !editingSummary, let summary = store.summary(on: day) {
                    IconButton(systemName: "pencil", help: s.editSummary, size: 22) {
                        summaryText = summary; editingSummary = true
                    }
                    IconButton(systemName: "trash", help: s.deleteSummary, size: 22) {
                        store.setSummary(nil, for: day)
                    }
                }
            }
            if editingSummary {
                TextEditor(text: $summaryText)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: 80)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
                HStack {
                    Spacer()
                    Button(s.cancel) { editingSummary = false }.buttonStyle(SecondaryButtonStyle(compact: true))
                    Button(s.save) {
                        store.setSummary(summaryText, for: day)
                        editingSummary = false
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                }
            } else if let summary = store.summary(on: day) {
                Text(summary)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .lineLimit(summaryExpanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { summaryExpanded.toggle() } }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.08)))
    }

    // MARK: - 分頁與清單

    /// 分頁模式：撐滿寬度，標籤和數字同一行，選中只用淡淡的底色
    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach([Kind.todo, .done, .note], id: \.self) { k in
                let selected = tab == k
                Button { withAnimation(.easeOut(duration: 0.15)) { tab = k } } label: {
                    HStack(spacing: 5) {
                        Text(s.label(k)).font(.system(size: 12.5, weight: .semibold))
                        Text("\(items(k).count)")
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(selected ? Theme.accent : .secondary)
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.segment : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
    }

    /// 條列模式（預設）：參考 Things 3／提醒事項／Todoist
    /// 每區一個彩色圓形圖示＋標題，數量靠右；區塊之間用留白分隔；新增放在每區最後一列
    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 行事曆放在捲動區最上面：展開整個月時跟清單一起捲，不會把清單擠扁
                CalendarCard()
                ForEach([Kind.todo, .done, .note], id: \.self) { sectionBlock($0) }
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .animation(.easeOut(duration: 0.18), value: collapsedRaw)
        }
        .frame(maxHeight: .infinity)
    }

    /// 待辦固定有「＋ 新增待辦」列；已完成、筆記較少手動新增，滑過標題才出現 ＋
    private func sectionBlock(_ k: Kind) -> some View {
        let rows = items(k)
        let isCollapsed = collapsed.contains(k)
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader(kind: k, title: s.label(k), count: rows.count, collapsed: isCollapsed,
                          addHelp: k == .todo ? nil : s.add(s.label(k))) {
                toggleCollapse(k)
            } onAdd: {
                if isCollapsed { toggleCollapse(k) }
                addingKind = k
            }
            if !isCollapsed {
                ForEach(rows) { EntryRow(item: $0, viewingDay: day) }
                if k == .todo {
                    AddEntryField(kind: k, day: day)
                } else if addingKind == k {
                    AddEntryField(kind: k, day: day, autoStart: true) { addingKind = nil }
                        .padding(.top, 4)
                }
            }
        }
    }

    private func toggleCollapse(_ k: Kind) {
        var set = collapsed
        if set.contains(k) { set.remove(k) } else { set.insert(k) }
        collapsedRaw = set.map(\.rawValue).sorted().joined(separator: ",")
    }

    private var list: some View {
        let rows = items(tab)
        return ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if rows.isEmpty {
                    emptyState
                } else {
                    ForEach(rows) { EntryRow(item: $0, viewingDay: day) }
                }
                AddEntryField(kind: tab, day: day)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .animation(.easeOut(duration: 0.18), value: rows.map(\.id))
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        let (icon, text): (String, String) = switch tab {
        case .todo: ("checkmark.seal", s.emptyTodo)
        case .done: ("tray", s.emptyDone)
        case .note: ("text.alignleft", s.emptyNote)
        }
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 16)
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 8)
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 0) {
            separator
            HStack(spacing: 14) {
                FooterButton(title: s.generateSummary, systemName: "sparkles", action: summarize)
                    .disabled(busy)
                FooterButton(title: s.copyMarkdown, systemName: "doc.on.doc", action: copyMarkdown)
                Spacer()
                FooterButton(title: s.quit, systemName: "power") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 16)
            .frame(height: 40)
        }
    }

    // MARK: - 動作

    private func organize() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let target = day
        let lang = lang
        let s = s
        let engine = engine
        if let reason = Organizer.unavailableReason(s, engine: engine) {
            store.addRawNote(text, to: target)
            input = ""
            show(s.savedRawNote(reason), error: true)
            return
        }
        let todos = store.openTodos(upTo: target)
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let output = try await Organizer.parse(text, openTodos: todos.map(\.entry.text), lang: lang, engine: engine)
                store.apply(output, raw: text, to: target, openTodos: todos)
                input = ""
                // 說清楚加到哪幾區，並把收起來的區塊打開，避免「新增了卻看不到」
                let kinds = [Kind.todo, .done, .note].filter { k in output.items.contains { $0.kind == k } }
                var msg = s.added(output.items.count)
                if !kinds.isEmpty {
                    msg += " · " + kinds.map { k in "\(s.label(k)) \(output.items.filter { $0.kind == k }.count)" }.joined(separator: ", ")
                }
                // 排到以後的事不會出現在「待辦」：訊息寫出排到哪天，行事曆也跳過去，避免以為沒新增
                let endOfToday = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
                if let later = output.items
                    .compactMap({ DateHint.detect($0.text, kind: $0.kind)?.date }).filter({ $0 >= endOfToday }).min() {
                    msg += " · " + s.scheduledOn(DueChip.label(later, allDay: true, locale: lang.locale) ?? "")
                    NotificationCenter.default.post(name: CalendarCard.reveal, object: later)
                }
                let stillCollapsed = collapsed.subtracting(kinds)
                collapsedRaw = stillCollapsed.map(\.rawValue).sorted().joined(separator: ",")
                if !output.completedTodoIndexes.isEmpty {
                    msg += s.completedExisting(output.completedTodoIndexes.count)
                }
                show(msg)
            } catch {
                store.addRawNote(text, to: target)
                input = ""
                show(s.organizeFailed(error.localizedDescription), error: true)
            }
        }
    }

    private func pasteAndOrganize() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            show(s.clipboardEmpty, error: true)
            return
        }
        input = text
        organize()
    }

    private func summarize() {
        let target = day
        let lang = lang
        let s = s
        let engine = engine
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let summary = try await Organizer.summarize(
                    done: store.completed(on: target).map(\.entry.text),
                    todo: store.openTodos(upTo: target).map(\.entry.text),
                    notes: store.notes(on: target).map(\.entry.text),
                    lang: lang,
                    engine: engine
                )
                store.setSummary(summary, for: target)
                show(s.summaryDone)
            } catch {
                show(s.summaryFailed(error.localizedDescription), error: true)
            }
        }
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.markdown(for: day, lang: lang), forType: .string)
        show(s.copied)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            show(s.loginFailed(error.localizedDescription), error: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func show(_ text: String, error: Bool = false) {
        undoClear = nil
        withAnimation(.easeOut(duration: 0.15)) {
            message = text
            isError = error
        }
    }

    private func shiftDay(_ n: Int) {
        let d = Calendar.current.date(byAdding: .day, value: n, to: Store.date(day)) ?? Date()
        day = min(Store.key(d), Store.today)
    }

    private func title(for key: String) -> String { lang.dayTitle(key) }

    /// 今天／昨天的前綴；其他日子沒有
    private func relativeLabel(for key: String) -> String? {
        let days = Calendar.current.dateComponents([.day], from: Store.date(key), to: Store.date(Store.today)).day ?? 0
        switch days {
        case 0: return s.today.capitalized
        case 1: return s.yesterday.capitalized
        default: return nil
        }
    }

    /// 標題列：前綴小一號、灰色，日期粗體
    private func headerText(for key: String) -> Text {
        let date = Text(lang.shortDayTitle(key)).font(.system(size: 15, weight: .semibold))
        guard let label = relativeLabel(for: key) else { return date }
        return Text("\(label)  ").font(.system(size: 12, weight: .medium)).foregroundColor(.secondary) + date
    }

    /// 日期選單每一列都寫出日期，今天那列是「今天 · 11月4日週三」，看得出點了會跳到哪天
    private func pickerTitle(for key: String) -> String {
        let date = lang.shortDayTitle(key)
        return relativeLabel(for: key).map { "\($0) · \(date)" } ?? date
    }
}

// MARK: - 元件

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, compact: compact)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .padding(.horizontal, compact ? 12 : 14)
                .frame(height: compact ? 26 : 36)
                .foregroundStyle(.white.opacity(isEnabled ? 1 : 0.6))
                .background(
                    RoundedRectangle(cornerRadius: compact ? 7 : 9)
                        .fill(Theme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4))
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
}

struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .systemRed).opacity(configuration.isPressed ? 0.75 : 1)))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, compact ? 12 : 14)
            .frame(height: compact ? 26 : 36)
            .background(
                RoundedRectangle(cornerRadius: compact ? 7 : 9)
                    .fill(Theme.accent.opacity(configuration.isPressed ? 0.22 : 0.12))
            )
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    var size: CGFloat = 28
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Theme.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct FooterButton: View {
    let title: String
    let systemName: String?
    var tint: Color = .secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemName { Image(systemName: systemName) }
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? (tint == .secondary ? .primary : tint) : tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct DayPickerRow: View {
    let title: String
    let detail: String?
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular))
                Spacer()
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
                if selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 區塊標題：彩色圓形圖示＋標題，數量靠右；滑過才出現收合箭頭
struct SectionHeader: View {
    let color: Color
    let symbol: String
    let title: String
    let count: Int
    let collapsed: Bool
    /// 有值時，滑過標題會在數量左邊出現 ＋
    var addHelp: String?
    let toggle: () -> Void
    var onAdd: () -> Void = {}
    @State private var hovering = false

    init(kind: Kind, title: String, count: Int, collapsed: Bool, addHelp: String? = nil,
         toggle: @escaping () -> Void, onAdd: @escaping () -> Void = {}) {
        self.init(color: Theme.color(kind), symbol: Theme.symbol(kind), title: title, count: count,
                  collapsed: collapsed, addHelp: addHelp, toggle: toggle, onAdd: onAdd)
    }

    init(color: Color, symbol: String, title: String, count: Int, collapsed: Bool, addHelp: String? = nil,
         toggle: @escaping () -> Void, onAdd: @escaping () -> Void = {}) {
        self.color = color
        self.symbol = symbol
        self.title = title
        self.count = count
        self.collapsed = collapsed
        self.addHelp = addHelp
        self.toggle = toggle
        self.onAdd = onAdd
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(count == 0 ? Color.secondary.opacity(0.35) : color)
                    Image(systemName: symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(count == 0 ? .secondary : .primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .opacity(hovering || collapsed ? 1 : 0)
                Spacer(minLength: 0)
                if let addHelp, hovering {
                    IconButton(systemName: "plus", help: addHelp, size: 20, action: onAdd)
                }
                Text("\(count)")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(count == 0 ? .tertiary : .secondary)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.bottom, 2)
    }
}

/// 待辦提到的時間：顯示在項目右側，過期變紅；點一下加入行事曆，加入後換成打勾的行事曆圖示
struct DueChip: View {
    @EnvironmentObject var store: Store
    @Environment(\.appLanguage) private var lang
    let item: DayEntry
    let due: Date
    let allDay: Bool
    var timeOnly = false
    var rowHovering = false
    @State private var hovering = false
    @State private var working = false

    private var added: Bool { item.entry.eventID != nil }
    private var overdue: Bool {
        guard item.entry.kind == .todo else { return false }
        return allDay ? Calendar.current.startOfDay(for: Date()) > due : Date() > due
    }

    private var text: String? {
        timeOnly ? Self.timeLabel(due, allDay: allDay, locale: lang.locale) : Self.label(due, allDay: allDay, locale: lang.locale)
    }

    var body: some View {
        // 只剩圖示的小框看起來像壞掉的按鈕：沒有文字時，滑過那一列才出現「加入行事曆」
        let iconOnly = text == nil && !added
        Button(action: add) {
            HStack(spacing: 4) {
                Image(systemName: added ? "calendar.badge.checkmark" : (hovering || iconOnly ? "calendar.badge.plus" : "calendar"))
                if let text { Text(text) }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(overdue ? Color(nsColor: .systemRed) : (hovering && !added ? Theme.accent : .secondary))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(hovering && !added ? Theme.accent.opacity(0.12) : Theme.hover))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(added || working)
        .onHover { hovering = $0 }
        .help(added ? lang.strings.addedToCalendar : lang.strings.addToCalendar)
        .opacity(iconOnly && !rowHovering ? 0 : 1)
        .allowsHitTesting(!(iconOnly && !rowHovering))
    }

    private func add() {
        working = true
        Task {
            defer { working = false }
            do {
                let id = try await CalendarExport.add(title: item.entry.text, start: due, allDay: allDay)
                store.setEventID(id, for: item)
                TidyMessage.post(lang.strings.addedToCalendar)
            } catch CalendarExport.Failure.denied {
                TidyMessage.post(lang.strings.calendarDenied, error: true)
            } catch {
                TidyMessage.post(lang.strings.calendarFailed(error.localizedDescription), error: true)
            }
        }
    }

    /// 只顯示幾點；整天的不顯示文字（只剩行事曆圖示）
    static func timeLabel(_ date: Date, allDay: Bool, locale: Locale) -> String? {
        guard !allDay else { return nil }
        let f = DateFormatter()
        f.locale = locale
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// 今天、明天用相對說法（今天 15:00）；其他天寫日期與星期；整天的不寫時間
    static func label(_ date: Date, allDay: Bool, locale: Locale) -> String? {
        let cal = Calendar.current
        if cal.isDateInToday(date) || cal.isDateInTomorrow(date) || cal.isDateInYesterday(date) {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .medium
            f.timeStyle = allDay ? .none : .short
            f.doesRelativeDateFormatting = true
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate(allDay ? "MdEEE" : "MdEEEjm")
        return f.string(from: date)
    }
}

/// 面板內元件要顯示提示訊息時，透過通知交給 ContentView 的訊息列
enum TidyMessage {
    static let name = Notification.Name("TidyDayMessage")
    static func post(_ text: String, error: Bool = false) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["text": text, "error": error])
    }
}

/// 單一項目：滑過時整列高亮並出現編輯／刪除，雙擊文字也能編輯
struct EntryRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.appLanguage) private var lang
    let item: DayEntry
    let viewingDay: String
    /// 行事曆清單已經依日期分組，時間標籤只需要顯示幾點
    var hideDueDate = false
    @State private var hovering = false
    @State private var editing = false
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            marker
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            if editing {
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.8)))
                    .onSubmit(save)
                    .onExitCommand { editing = false }
                IconButton(systemName: "checkmark", help: lang.strings.saveHint, size: 22, action: save)
                IconButton(systemName: "xmark", help: lang.strings.cancelHint, size: 22) { editing = false }
            } else {
                Text(item.entry.text)
                    .font(.system(size: 13))
                    .foregroundStyle(item.entry.kind == .done ? .secondary : .primary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: startEditing)

                if let due = item.entry.due, item.entry.kind != .done {
                    DueChip(item: item, due: due, allDay: item.entry.allDay ?? false, timeOnly: hideDueDate, rowHovering: hovering)
                }
                if hovering {
                    HStack(spacing: 0) {
                        IconButton(systemName: "pencil", help: lang.strings.edit, size: 22, action: startEditing)
                        IconButton(systemName: "trash", help: lang.strings.delete, size: 22) {
                            withAnimation { store.delete(item) }
                        }
                    }
                } else if item.day != viewingDay && item.entry.due == nil {
                    // 前幾天延續下來的待辦：右側小字標出原本的日期
                    Label(lang.shortDate(item.day), systemImage: "arrow.turn.down.right")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(minHeight: 36)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering && !editing ? Theme.hover : .clear))
        .overlay(alignment: .bottom) {
            // 提醒事項風格：分隔線從文字開頭起算，滑過時隱藏
            Rectangle().fill(Theme.hairline).frame(height: 1)
                .padding(.leading, 36).padding(.trailing, 8)
                .opacity(hovering ? 0 : 1)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(lang.strings.edit, action: startEditing)
            ForEach(Kind.allCases.filter { $0 != item.entry.kind }, id: \.self) { k in
                Button(lang.strings.changeTo(lang.strings.label(k))) { store.setKind(k, for: item) }
            }
            Button(lang.strings.copy) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.entry.text, forType: .string)
            }
            Divider()
            Button(lang.strings.delete, role: .destructive) { store.delete(item) }
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch item.entry.kind {
        case .todo:
            Button { withAnimation { store.setKind(.done, for: item) } } label: {
                ZStack {
                    Circle()
                        .strokeBorder(hovering ? Theme.color(.todo) : Color.primary.opacity(0.28), lineWidth: 1.5)
                    // 滑過時預先顯示淡淡的勾，提示點了會完成
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(Theme.color(.todo))
                        .opacity(hovering ? 0.8 : 0)
                }
                .frame(width: 17, height: 17)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(lang.strings.markDone)
        case .done:
            Button { withAnimation { store.setKind(.todo, for: item) } } label: {
                ZStack {
                    Circle().fill(Theme.color(.done))
                    Image(systemName: "checkmark")
                        .font(.system(size: 8.5, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 17, height: 17)
            }
            .buttonStyle(.plain)
            .help(lang.strings.markTodo)
        case .note:
            Circle()
                .fill(Theme.color(.note))
                .frame(width: 6, height: 6)
                .frame(width: 17, height: 17)
        }
    }

    private func startEditing() {
        text = item.entry.text
        editing = true
        focused = true
    }

    private func save() {
        store.setText(text, for: item)
        editing = false
    }
}

/// 清單底部的「＋ 新增」：不經過模型，直接手動加一筆到目前的分頁
struct AddEntryField: View {
    @EnvironmentObject var store: Store
    @Environment(\.appLanguage) private var lang
    let kind: Kind
    let day: String
    /// 條列模式由標題的＋觸發：一出現就是輸入狀態，結束時通知外面收起來
    var autoStart = false
    var onFinish: (() -> Void)?
    @State private var adding = false
    @State private var text = ""
    @State private var hovering = false
    @FocusState private var focused: Bool

    init(kind: Kind, day: String, autoStart: Bool = false, onFinish: (() -> Void)? = nil) {
        self.kind = kind
        self.day = day
        self.autoStart = autoStart
        self.onFinish = onFinish
        _adding = State(initialValue: autoStart)
    }

    var body: some View {
        if adding {
            HStack(spacing: 6) {
                TextField(lang.strings.addPlaceholder(lang.strings.label(kind)), text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.field))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.accent.opacity(0.8)))
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onAppear { focused = true }
                IconButton(systemName: "xmark", help: lang.strings.cancelHint, size: 22, action: cancel)
            }
            .padding(.horizontal, 4)
        } else {
            Button { adding = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.color(kind))
                        .frame(width: 17)
                    Text(lang.strings.add(lang.strings.label(kind)))
                        .font(.system(size: 13))
                        .foregroundStyle(hovering ? .primary : .tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }

    private func commit() {
        withAnimation { store.addEntry(kind, text: text, to: day) }
        text = ""
        focused = true  // 保持輸入狀態，可以連續新增
    }

    private func cancel() {
        adding = false
        text = ""
        onFinish?()
    }
}
