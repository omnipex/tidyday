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
    @State private var showDays = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage(AppLanguage.storageKey) private var langRaw = AppLanguage.system.rawValue
    @AppStorage(Appearance.storageKey) private var appearanceRaw = Appearance.system.rawValue
    @AppStorage(Engine.storageKey) private var engineRaw = Engine.apple.rawValue
    @State private var showSettings = false
    @State private var addingKind: Kind?
    @AppStorage("layout") private var layoutRaw = "list"
    @AppStorage("collapsedSections") private var collapsedRaw = ""
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var inputFocused: Bool

    private var isToday: Bool { day == Store.today }
    private var lang: AppLanguage { AppLanguage(rawValue: langRaw) ?? .system }
    private var s: Strings { lang.strings }

    private func items(_ kind: Kind) -> [DayEntry] {
        switch kind {
        case .todo: return store.openTodos(upTo: day)
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
            inputCard
                .padding(.horizontal, 16)
            if store.summary(on: day) != nil || editingSummary {
                summaryCard
                    .padding(.horizontal, 16).padding(.top, 12)
            }
            if isTabs {
                tabs
                    .padding(.horizontal, 16).padding(.top, 14)
                list
            } else {
                sections
                    .padding(.top, 6)
            }
            footer
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
                Picker(s.language, selection: $langRaw) {
                    ForEach(AppLanguage.allCases) { l in
                        Text(l == .system ? s.followSystem : l.nativeName).tag(l.rawValue)
                    }
                }
                Button(s.openFolder) { NSWorkspace.shared.open(store.dir) }
                Divider()
                Button(s.clearDayMenu(lang.shortDate(day))) { confirmClear = true }
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

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $input)
                    .focused($inputFocused)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 7).padding(.vertical, 8)
                if input.isEmpty {
                    Text(isToday ? s.placeholderToday : s.placeholderPast(lang.shortDate(day)))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 78)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.field))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius)
                    .strokeBorder(inputFocused ? Theme.accent.opacity(0.9) : Theme.stroke,
                                  lineWidth: inputFocused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: inputFocused)

            // 空的時候不擺一顆停用的大按鈕，直接給最常用的「貼上並整理」
            HStack(spacing: 8) {
                Button(action: input.isEmpty ? pasteAndOrganize : organize) {
                    HStack(spacing: 7) {
                        if busy {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: input.isEmpty ? "doc.on.clipboard" : "sparkles")
                        }
                        Text(busy ? s.organizing : (input.isEmpty ? s.pasteAndOrganize : s.organize))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(busy)
                .help(input.isEmpty ? s.pasteHelp : s.organizeHelp)

                if !input.isEmpty && !busy {
                    Button { input = "" } label: { Label(s.clear, systemImage: "xmark") }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }

            if let message {
                Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(isError ? Color.orange : .secondary)
                    .transition(.opacity)
            }
        }
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

    /// 條列模式（預設）：三區由上往下，控制中心風格的灰色小標題，點標題收合，＋在標題右側
    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach([Kind.todo, .done, .note], id: \.self) { k in
                    if k != .todo {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                            .padding(.horizontal, 8).padding(.top, 6)
                    }
                    sectionBlock(k)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            .animation(.easeOut(duration: 0.18), value: collapsedRaw)
        }
        .frame(maxHeight: .infinity)
    }

    private func sectionBlock(_ k: Kind) -> some View {
        let rows = items(k)
        let isCollapsed = collapsed.contains(k)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button { toggleCollapse(k) } label: {
                    HStack(spacing: 6) {
                        Text(s.label(k)).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        Text("\(rows.count)")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                IconButton(systemName: "plus", help: s.add(s.label(k)), size: 22) {
                    if isCollapsed { toggleCollapse(k) }
                    addingKind = k
                }
            }
            .padding(.leading, 8)
            .padding(.top, 10).padding(.bottom, 2)

            if !isCollapsed {
                ForEach(rows) { EntryRow(item: $0, viewingDay: day) }
                if addingKind == k {
                    AddEntryField(kind: k, day: day, autoStart: true) { addingKind = nil }
                        .padding(.top, 2)
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
                if confirmClear {
                    Text(s.confirmClear(lang.shortDate(day)))
                        .font(.system(size: 12))
                    Spacer()
                    FooterButton(title: s.cancel, systemName: nil) { confirmClear = false }
                    FooterButton(title: s.clearAction, systemName: "trash", tint: .red) {
                        store.clearDay(day)
                        confirmClear = false
                        show(s.cleared(lang.shortDate(day)))
                    }
                } else {
                    FooterButton(title: s.generateSummary, systemName: "sparkles", action: summarize)
                        .disabled(busy)
                    FooterButton(title: s.copyMarkdown, systemName: "doc.on.doc", action: copyMarkdown)
                    Spacer()
                    FooterButton(title: s.quit, systemName: "power") { NSApp.terminate(nil) }
                }
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
                var msg = s.added(output.items.count)
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

/// 單一項目：滑過時整列高亮並出現編輯／刪除，雙擊文字也能編輯
struct EntryRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.appLanguage) private var lang
    let item: DayEntry
    let viewingDay: String
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

                if hovering {
                    HStack(spacing: 0) {
                        IconButton(systemName: "pencil", help: lang.strings.edit, size: 22, action: startEditing)
                        IconButton(systemName: "trash", help: lang.strings.delete, size: 22) {
                            withAnimation { store.delete(item) }
                        }
                    }
                } else if item.day != viewingDay {
                    Text(lang.shortDate(item.day))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.hover))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering && !editing ? Theme.hover : .clear))
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
                Circle()
                    .strokeBorder(hovering ? Theme.accent : Color.secondary.opacity(0.6), lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(lang.strings.markDone)
        case .done:
            Button { withAnimation { store.setKind(.todo, for: item) } } label: {
                ZStack {
                    Circle().fill(Theme.accent)
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help(lang.strings.markTodo)
        case .note:
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Theme.accent.opacity(0.6))
                .frame(width: 3, height: 14)
                .frame(width: 16)
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
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).frame(width: 16)
                    Text(lang.strings.add(lang.strings.label(kind))).font(.system(size: 12.5))
                }
                .foregroundStyle(hovering ? Theme.accent : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 6)
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
