import SwiftUI

/// 行事曆區塊：標題跟「待辦」等區塊同一種樣式，可收合。
/// 參考 Itsycal（日期下的小點＋下方清單）與 TickTick（週／月／年切換）：
/// - 週、月：日期格，有排程的日子下方有小點；下方清單列出這段期間的排程，點某天只看那天（再點一次取消）
/// - 年：12 個月份方塊顯示排程數量，點月份進到月檢視
struct CalendarCard: View {
    enum Mode: String, CaseIterable { case week, month, year }

    @EnvironmentObject var store: Store
    @Environment(\.appLanguage) private var lang
    @AppStorage("calendarCollapsed") private var collapsed = false
    @AppStorage("calendarMode") private var modeRaw = Mode.week.rawValue
    @State private var selected: Date?
    @State private var anchor = Date()

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .week }
    private var s: Strings { lang.strings }
    private var cal: Calendar { var c = Calendar.current; c.locale = lang.locale; return c }
    private var today: Date { cal.startOfDay(for: Date()) }
    static let color = Color(nsColor: .systemRed)
    /// 新增了排到以後的事：展開行事曆並跳到那天（object 是那天的 Date）
    static let reveal = Notification.Name("TidyDayRevealDate")

    var body: some View {
        let byDay = store.scheduledByDay()
        let days = agendaDays(byDay)
        // 跟其他區塊一樣：標題數字＝下面列出的筆數（這週／這個月／今年，或選取的那天）
        let shown = days.reduce(0) { $0 + (byDay[$1]?.count ?? 0) }
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(color: Self.color, symbol: "calendar", title: s.calendarTitle, count: shown,
                          collapsed: collapsed) { collapsed.toggle() }
            if !collapsed {
                VStack(alignment: .leading, spacing: 8) {
                    toolbar
                    switch mode {
                    case .week, .month:
                        weekdayRow
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
                            ForEach(visibleDays, id: \.self) { dayCell($0, items: byDay[$0] ?? []) }
                        }
                    case .year:
                        yearGrid(byDay)
                    }
                }
                .padding(.horizontal, 6).padding(.top, 4)
                agenda(byDay, days: days)
            }
        }
        .animation(.easeOut(duration: 0.18), value: collapsed)
        .animation(.easeOut(duration: 0.18), value: modeRaw)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in anchor = Date() }
        .onReceive(NotificationCenter.default.publisher(for: Self.reveal)) { n in
            guard let date = n.object as? Date else { return }
            collapsed = false
            if mode == .year { modeRaw = Mode.month.rawValue }
            // 不選取那天（否則清單只剩那天的事）；週檢視時，7 天內的就維持從今天起，超過才翻過去
            selected = nil
            if mode == .week, let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: date)).day, days < 7 {
                anchor = Date()
            } else {
                anchor = date
            }
        }
    }

    // MARK: - 工具列：週／月／年＋期間＋前後切換

    private var toolbar: some View {
        HStack(spacing: 6) {
            // 系統分段按鈕選中時是整塊藍，比內容還搶眼；改成跟「分頁」一樣低調的灰底
            HStack(spacing: 2) {
                ForEach([(Mode.week, s.showWeek), (.month, s.showMonth), (.year, s.showYear)], id: \.0) { m, label in
                    Button { modeRaw = m.rawValue; selected = nil; if m == .week { anchor = Date() } } label: {
                        Text(label)
                            .font(.system(size: 11.5, weight: mode == m ? .semibold : .medium))
                            .foregroundStyle(mode == m ? .primary : .secondary)
                            .padding(.horizontal, 9).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(mode == m ? Theme.segment : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .fixedSize()
            Text(periodTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)
            if mode == .week ? !cal.isDateInToday(anchor) : !cal.isDate(anchor, equalTo: Date(), toGranularity: granularity) {
                Button(s.today) { anchor = Date(); selected = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            IconButton(systemName: "chevron.left", size: 22) { move(-1) }
            IconButton(systemName: "chevron.right", size: 22) { move(1) }
        }
    }

    private var granularity: Calendar.Component {
        switch mode { case .week: .weekOfYear; case .month: .month; case .year: .year }
    }

    private var periodTitle: String {
        let f = DateFormatter()
        f.locale = lang.locale
        switch mode {
        case .year:
            f.setLocalizedDateFormatFromTemplate("y")
            return f.string(from: anchor)
        case .month:
            f.setLocalizedDateFormatFromTemplate("yMMMM")
            return f.string(from: anchor)
        case .week:
            let days = visibleDays
            f.setLocalizedDateFormatFromTemplate("Md")
            return "\(f.string(from: days.first ?? anchor)) – \(f.string(from: days.last ?? anchor))"
        }
    }

    private func move(_ step: Int) {
        anchor = mode == .week
            ? cal.date(byAdding: .day, value: 7 * step, to: anchor) ?? anchor
            : cal.date(byAdding: granularity, value: step, to: anchor) ?? anchor
        selected = nil
    }

    // MARK: - 週、月

    private var weekdayRow: some View {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        // 週檢視從 anchor 那天開始，星期列跟著轉；月檢視照系統的一週第一天
        let first = (mode == .week ? cal.component(.weekday, from: anchor) : cal.firstWeekday) - 1
        let ordered = Array(symbols[first...] + symbols[..<first])
        return HStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, sym in
                Text(sym)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekStart(_ d: Date) -> Date {
        cal.dateInterval(of: .weekOfYear, for: d)?.start ?? cal.startOfDay(for: d)
    }

    private var visibleDays: [Date] {
        if mode == .week {
            // 從 anchor 那天起連續 7 天（預設是今天）：週六時也看得到明天、下週一的排程
            let start = cal.startOfDay(for: anchor)
            return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        }
        guard let month = cal.dateInterval(of: .month, for: anchor) else { return [] }
        let start = weekStart(month.start)
        let lastDay = cal.date(byAdding: .day, value: -1, to: month.end) ?? month.end
        let end = cal.date(byAdding: .day, value: 7, to: weekStart(lastDay)) ?? month.end
        let count = cal.dateComponents([.day], from: start, to: end).day ?? 35
        return (0..<count).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
    }

    private func dayCell(_ day: Date, items: [DayEntry]) -> some View {
        let isToday = day == today
        let isSelected = day == selected
        let inPeriod = mode == .week || cal.isDate(day, equalTo: anchor, toGranularity: .month)
        return Button { selected = isSelected ? nil : day } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.system(size: 12, weight: isToday || isSelected ? .bold : .regular, design: .rounded))
                    .foregroundStyle(isToday ? Color.white : (inPeriod ? Color.primary : Color.secondary.opacity(0.5)))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(isToday ? Theme.accent : (isSelected ? Theme.accent.opacity(0.18) : .clear)))
                    .overlay(Circle().strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 1.5))
                Circle()
                    .fill(dotColor(day, items))
                    .frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 小點顏色跟區塊一致：有待辦是藍色，只有筆記是橘色
    private func dotColor(_ day: Date, _ items: [DayEntry]) -> Color {
        guard !items.isEmpty else { return .clear }
        return items.contains { $0.entry.kind == .todo } ? Theme.color(.todo) : Theme.color(.note)
    }

    // MARK: - 年

    private func yearGrid(_ byDay: [Date: [DayEntry]]) -> some View {
        let year = cal.dateInterval(of: .year, for: anchor)?.start ?? anchor
        let months = (0..<12).compactMap { cal.date(byAdding: .month, value: $0, to: year) }
        let f = DateFormatter()
        f.locale = lang.locale
        f.setLocalizedDateFormatFromTemplate("MMM")
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(months, id: \.self) { m in
                let count = byDay.filter { cal.isDate($0.key, equalTo: m, toGranularity: .month) }
                    .values.joined().count  // 跟清單筆數一致（含已完成）
                let isThisMonth = cal.isDate(m, equalTo: Date(), toGranularity: .month)
                Button {
                    anchor = m
                    modeRaw = Mode.month.rawValue
                } label: {
                    VStack(spacing: 2) {
                        Text(f.string(from: m))
                            .font(.system(size: 12, weight: isThisMonth ? .bold : .medium))
                            .foregroundStyle(isThisMonth ? Theme.accent : .primary)
                        Text(count > 0 ? "\(count)" : "–")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(count > 0 ? Theme.accent : Color.secondary.opacity(0.5))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8).fill(count > 0 ? Theme.accent.opacity(0.10) : Theme.hover))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - 清單：這段期間（或選取那天）的排程，依日期分組

    private func agendaDays(_ byDay: [Date: [DayEntry]]) -> [Date] {
        byDay.keys.filter { day in
            if let selected { return day == selected }
            if mode == .week { return visibleDays.contains(day) }
            return cal.isDate(day, equalTo: anchor, toGranularity: granularity)
        }.sorted()
    }

    @ViewBuilder
    private func agenda(_ byDay: [Date: [DayEntry]], days: [Date]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if days.isEmpty {
                Text(s.noSchedule)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
            }
            ForEach(days, id: \.self) { day in
                Text(dayHeader(day))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(day == today ? Theme.accent : (day < today ? Color.secondary : Color.secondary))
                    .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 2)
                ForEach(byDay[day] ?? []) { EntryRow(item: $0, viewingDay: $0.day, hideDueDate: true) }
            }
        }
    }

    private func dayHeader(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = lang.locale
        if cal.isDateInToday(day) || cal.isDateInTomorrow(day) || cal.isDateInYesterday(day) {
            f.dateStyle = .medium
            f.doesRelativeDateFormatting = true
            let rel = f.string(from: day)
            f.doesRelativeDateFormatting = false
            f.setLocalizedDateFormatFromTemplate("MdEEE")
            return "\(rel) · \(f.string(from: day))"
        }
        f.setLocalizedDateFormatFromTemplate("MdEEE")
        return f.string(from: day)
    }
}
