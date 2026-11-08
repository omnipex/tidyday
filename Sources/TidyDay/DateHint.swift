import Foundation

/// 從項目文字抓出提到的時間（明天下午 3 點、週五前、tomorrow at 3pm、明日の15時）。
/// 用系統的 NSDataDetector（依規則解析），不交給模型：11/7 實測本地模型會算錯星期，
/// NSDataDetector 在繁中、簡中、英文、日文 17 個樣本全對，數字、百分比、金額也不會誤抓。
enum DateHint {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    /// 有這些字才算「有指定時間」；沒有的話（週五、下週一、11/12）當成整天
    private static let timeMarkers = try? NSRegularExpression(
        pattern: "[:：]|點|点|時|时|上午|下午|早上|晚上|中午|傍晚|凌晨|今晚|午前|午後|夜|\\d\\s*(am|pm)\\b|\\b(am|pm|noon|morning|afternoon|evening|tonight)\\b",
        options: [.caseInsensitive])

    /// 依項目類型決定要不要記時間：已完成的不記；筆記只記今天或以後（「昨天修正後…」是在描述過去，不是排程）；
    /// 待辦保留過去的時間，因為那代表已經過期
    static func detect(_ text: String, kind: Kind) -> (date: Date, allDay: Bool)? {
        guard kind != .done, let hint = detect(text) else { return nil }
        if kind == .note, hint.date < Calendar.current.startOfDay(for: Date()) { return nil }
        return hint
    }

    static func detect(_ text: String) -> (date: Date, allDay: Bool)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let m = detector?.firstMatch(in: text, range: range), let date = m.date else { return nil }
        let phrase = (text as NSString).substring(with: m.range)
        let hasTime = timeMarkers?.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) != nil
        return hasTime ? (date, false) : (Calendar.current.startOfDay(for: date), true)
    }
}
