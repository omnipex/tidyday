import EventKit

/// 把待辦加到 macOS 行事曆。只要「只能新增」權限：TidyDay 讀不到使用者原本的行程。
@MainActor
enum CalendarExport {
    private static let store = EKEventStore()

    enum Failure: Error { case denied, noCalendar }

    /// 回傳新事件的 ID（存回項目，之後顯示「已加入」）
    static func add(title: String, start: Date, allDay: Bool) async throws -> String {
        guard try await store.requestWriteOnlyAccessToEvents() else { throw Failure.denied }
        guard let calendar = store.defaultCalendarForNewEvents else { throw Failure.noCalendar }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.calendar = calendar
        event.isAllDay = allDay
        event.startDate = start
        event.endDate = allDay ? start : start.addingTimeInterval(3600)
        event.notes = "TidyDay"
        try store.save(event, span: .thisEvent)
        return event.eventIdentifier ?? UUID().uuidString
    }
}
