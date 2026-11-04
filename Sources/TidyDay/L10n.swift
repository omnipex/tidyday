import SwiftUI
import AppKit

// 多國語系：介面文字與本地模型的輸出語言都跟著 AppLanguage 走
// 新增語言：在 AppLanguage 加一個 case，補上 nativeName / localeID / promptLanguage，再寫一份 Strings

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHant = "zh-Hant"
    case zhHans = "zh-Hans"
    case en
    case ja

    static let storageKey = "appLanguage"

    var id: String { rawValue }

    var nativeName: String {
        switch self {
        case .system: return "System"
        case .zhHant: return "繁體中文"
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }

    /// 「跟隨系統」時依系統偏好語言挑一個支援的語言，都不支援就用英文
    var resolved: AppLanguage {
        guard self == .system else { return self }
        for id in Locale.preferredLanguages {
            let l = id.lowercased()
            if l.hasPrefix("zh-hant") || l.hasPrefix("zh-tw") || l.hasPrefix("zh-hk") || l.hasPrefix("zh-mo") { return .zhHant }
            if l.hasPrefix("zh") { return .zhHans }
            if l.hasPrefix("en") { return .en }
            if l.hasPrefix("ja") { return .ja }
        }
        return .en
    }

    var locale: Locale {
        switch resolved {
        case .zhHant: return Locale(identifier: "zh_TW")
        case .zhHans: return Locale(identifier: "zh_CN")
        case .ja: return Locale(identifier: "ja_JP")
        default: return Locale(identifier: "en_US")
        }
    }

    /// 給模型看的輸出語言名稱
    var promptLanguage: String {
        switch resolved {
        case .zhHant: return "Traditional Chinese (Taiwan)"
        case .zhHans: return "Simplified Chinese"
        case .ja: return "Japanese"
        default: return "English"
        }
    }

    var strings: Strings {
        switch resolved {
        case .zhHant: return .zhHant
        case .zhHans: return .zhHans
        case .ja: return .ja
        default: return .en
        }
    }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }
}

struct Strings {
    var todo: String
    var done: String
    var note: String

    var today: String
    var yesterday: String
    var daysAgo: (Int) -> String
    var prevDay: String
    var nextDay: String

    var settings: String
    var launchAtLogin: String
    var language: String
    var followSystem: String
    var openFolder: String
    var clearDayMenu: (String) -> String

    var placeholderToday: String
    var placeholderPast: (String) -> String
    var organize: String
    var organizing: String
    var organizeHelp: String
    var paste: String
    var pasteHelp: String
    var clear: String

    var summaryTitle: String
    var editSummary: String
    var deleteSummary: String
    var cancel: String
    var save: String

    var emptyTodo: String
    var emptyDone: String
    var emptyNote: String

    var confirmClear: (String) -> String
    var clearAction: String
    var generateSummary: String
    var copyMarkdown: String
    var quit: String

    var added: (Int) -> String
    var completedExisting: (Int) -> String
    var savedRawNote: (String) -> String
    var organizeFailed: (String) -> String
    var summaryDone: String
    var summaryFailed: (String) -> String
    var copied: String
    var cleared: (String) -> String
    var loginFailed: (String) -> String

    var modelNotEligible: String
    var modelNotEnabled: String
    var modelNotReady: String
    var modelUnavailable: String

    var markDone: String
    var markTodo: String
    var edit: String
    var delete: String
    var copy: String
    var changeTo: (String) -> String
    var add: (String) -> String
    var addPlaceholder: (String) -> String
    var saveHint: String
    var cancelHint: String
    var itemCount: (Int) -> String
    var none: String

    var modelSettings: String
    var engineLabel: String
    var engineApple: String
    var appleInfo: String
    var apiKey: String
    var keychainNote: String
    var baseURL: String
    var modelLabel: String
    var loadModels: String
    var chooseModel: (Int) -> String
    var testConnection: String
    var testing: String
    var testOK: (Int, String) -> String
    var testSample: String
    var cloudPrivacy: (String) -> String
    var ollamaLocal: String
    var missingKey: (String) -> String
    var missingModel: String
    var appearance: String
    var appearSystem: String
    var appearLight: String
    var appearDark: String
    var toggleTheme: String
    var back: String
    var pasteAndOrganize: String
    var clipboardEmpty: String
    var engineShort: String
    var layout: String
    var layoutList: String
    var layoutTabs: String
    var backToToday: String

    func label(_ kind: Kind) -> String {
        switch kind {
        case .todo: return todo
        case .done: return done
        case .note: return note
        }
    }
}

extension Strings {
    static let zhHant = Strings(
        todo: "待辦", done: "已完成", note: "筆記",
        today: "今天", yesterday: "昨天", daysAgo: { "\($0) 天前" },
        prevDay: "前一天", nextDay: "後一天",
        settings: "設定", launchAtLogin: "開機時啟動", language: "語言", followSystem: "跟隨系統",
        openFolder: "開啟資料夾", clearDayMenu: { "清除 \($0) 的紀錄…" },
        placeholderToday: "貼上會議紀錄、聊天、隨手筆記、做完了什麼…",
        placeholderPast: { "補記到 \($0)…" },
        organize: "整理", organizing: "整理中…", organizeHelp: "用本地模型整理（⌘↩）",
        paste: "貼上", pasteHelp: "貼上剪貼簿內容", clear: "清除",
        summaryTitle: "今日總結", editSummary: "編輯總結", deleteSummary: "刪除總結",
        cancel: "取消", save: "儲存",
        emptyTodo: "沒有待辦，太好了", emptyDone: "這天還沒有完成紀錄", emptyNote: "還沒有筆記",
        confirmClear: { "清除 \($0) 的所有紀錄？" }, clearAction: "清除",
        generateSummary: "產生總結", copyMarkdown: "複製 Markdown", quit: "結束",
        added: { "新增 \($0) 項" }, completedExisting: { "，勾掉 \($0) 個既有待辦" },
        savedRawNote: { "\($0)，已原文存成筆記" },
        organizeFailed: { "本地模型整理失敗（\($0)），已原文存成筆記" },
        summaryDone: "已產生總結", summaryFailed: { "產生總結失敗：\($0)" },
        copied: "已複製 Markdown", cleared: { "已清除 \($0) 的紀錄" },
        loginFailed: { "設定開機啟動失敗：\($0)" },
        modelNotEligible: "這台 Mac 不支援 Apple Intelligence",
        modelNotEnabled: "尚未開啟 Apple Intelligence",
        modelNotReady: "本地模型還在下載或準備中",
        modelUnavailable: "本地模型無法使用",
        markDone: "標記完成", markTodo: "改回待辦", edit: "編輯", delete: "刪除", copy: "複製",
        changeTo: { "改成\($0)" }, add: { "新增\($0)" }, addPlaceholder: { "新增\($0)，按 Enter 儲存" },
        saveHint: "儲存（Enter）", cancelHint: "取消（Esc）", itemCount: { "\($0) 項" }, none: "（無）",
        modelSettings: "模型設定", engineLabel: "整理用的模型", engineApple: "Mac 本地模型",
        appleInfo: "使用 Mac 內建的 Apple Intelligence。免費、不用網路，內容不會離開這台電腦。",
        apiKey: "API Key", keychainNote: "存在 macOS 鑰匙圈，不會寫進設定檔", baseURL: "Base URL",
        modelLabel: "模型", loadModels: "載入清單", chooseModel: { "選擇模型（\($0)）" },
        testConnection: "測試連線", testing: "測試中…",
        testOK: { "連線成功，整理出 \($0) 項：\($1)" },
        testSample: "今天修好了登入頁的 bug，明天要寄週報給主管。",
        cloudPrivacy: { "貼上的內容會傳送到 \($0) 處理。公司或客戶資料請先確認是否允許。" },
        ollamaLocal: "Ollama 跑在這台電腦上，內容不會離開本機。",
        missingKey: { "尚未設定 \($0) 的 API Key" }, missingModel: "尚未設定模型",
        appearance: "外觀", appearSystem: "跟隨系統", appearLight: "淺色", appearDark: "深色",
        toggleTheme: "切換深淺色", back: "返回", pasteAndOrganize: "貼上並整理", clipboardEmpty: "剪貼簿裡沒有文字", engineShort: "本地", layout: "顯示方式", layoutList: "條列", layoutTabs: "分頁", backToToday: "回到今天"
    )

    static let zhHans = Strings(
        todo: "待办", done: "已完成", note: "笔记",
        today: "今天", yesterday: "昨天", daysAgo: { "\($0) 天前" },
        prevDay: "前一天", nextDay: "后一天",
        settings: "设置", launchAtLogin: "开机时启动", language: "语言", followSystem: "跟随系统",
        openFolder: "打开文件夹", clearDayMenu: { "清除 \($0) 的记录…" },
        placeholderToday: "粘贴会议记录、聊天、随手笔记、做完了什么…",
        placeholderPast: { "补记到 \($0)…" },
        organize: "整理", organizing: "整理中…", organizeHelp: "用本地模型整理（⌘↩）",
        paste: "粘贴", pasteHelp: "粘贴剪贴板内容", clear: "清除",
        summaryTitle: "今日总结", editSummary: "编辑总结", deleteSummary: "删除总结",
        cancel: "取消", save: "保存",
        emptyTodo: "没有待办，太好了", emptyDone: "这天还没有完成记录", emptyNote: "还没有笔记",
        confirmClear: { "清除 \($0) 的所有记录？" }, clearAction: "清除",
        generateSummary: "生成总结", copyMarkdown: "复制 Markdown", quit: "退出",
        added: { "新增 \($0) 项" }, completedExisting: { "，勾掉 \($0) 个已有待办" },
        savedRawNote: { "\($0)，已原文保存为笔记" },
        organizeFailed: { "本地模型整理失败（\($0)），已原文保存为笔记" },
        summaryDone: "已生成总结", summaryFailed: { "生成总结失败：\($0)" },
        copied: "已复制 Markdown", cleared: { "已清除 \($0) 的记录" },
        loginFailed: { "设置开机启动失败：\($0)" },
        modelNotEligible: "这台 Mac 不支持 Apple Intelligence",
        modelNotEnabled: "尚未开启 Apple Intelligence",
        modelNotReady: "本地模型还在下载或准备中",
        modelUnavailable: "本地模型无法使用",
        markDone: "标记完成", markTodo: "改回待办", edit: "编辑", delete: "删除", copy: "复制",
        changeTo: { "改成\($0)" }, add: { "新增\($0)" }, addPlaceholder: { "新增\($0)，按 Enter 保存" },
        saveHint: "保存（Enter）", cancelHint: "取消（Esc）", itemCount: { "\($0) 项" }, none: "（无）",
        modelSettings: "模型设置", engineLabel: "用于整理的模型", engineApple: "Mac 本地模型",
        appleInfo: "使用 Mac 内置的 Apple Intelligence。免费、无需联网，内容不会离开这台电脑。",
        apiKey: "API Key", keychainNote: "保存在 macOS 钥匙串，不会写入配置文件", baseURL: "Base URL",
        modelLabel: "模型", loadModels: "加载列表", chooseModel: { "选择模型（\($0)）" },
        testConnection: "测试连接", testing: "测试中…",
        testOK: { "连接成功，整理出 \($0) 项：\($1)" },
        testSample: "今天修好了登录页的 bug，明天要把周报发给主管。",
        cloudPrivacy: { "粘贴的内容会发送到 \($0) 处理。公司或客户数据请先确认是否允许。" },
        ollamaLocal: "Ollama 运行在这台电脑上，内容不会离开本机。",
        missingKey: { "尚未设置 \($0) 的 API Key" }, missingModel: "尚未设置模型",
        appearance: "外观", appearSystem: "跟随系统", appearLight: "浅色", appearDark: "深色",
        toggleTheme: "切换深浅色", back: "返回", pasteAndOrganize: "粘贴并整理", clipboardEmpty: "剪贴板里没有文字", engineShort: "本地", layout: "显示方式", layoutList: "列表", layoutTabs: "分页", backToToday: "回到今天"
    )

    static let en = Strings(
        todo: "To-do", done: "Done", note: "Notes",
        today: "TODAY", yesterday: "YESTERDAY", daysAgo: { "\($0) DAYS AGO" },
        prevDay: "Previous day", nextDay: "Next day",
        settings: "Settings", launchAtLogin: "Launch at login", language: "Language", followSystem: "Follow system",
        openFolder: "Open data folder", clearDayMenu: { "Clear \($0)…" },
        placeholderToday: "Paste meeting notes, chats, quick thoughts, what you finished…",
        placeholderPast: { "Add to \($0)…" },
        organize: "Organize", organizing: "Organizing…", organizeHelp: "Organize with the on-device model (⌘↩)",
        paste: "Paste", pasteHelp: "Paste from clipboard", clear: "Clear",
        summaryTitle: "Daily summary", editSummary: "Edit summary", deleteSummary: "Delete summary",
        cancel: "Cancel", save: "Save",
        emptyTodo: "Nothing to do. Nice.", emptyDone: "Nothing finished this day yet", emptyNote: "No notes yet",
        confirmClear: { "Clear everything on \($0)?" }, clearAction: "Clear",
        generateSummary: "Summarize", copyMarkdown: "Copy Markdown", quit: "Quit",
        added: { "Added \($0) item\($0 == 1 ? "" : "s")" },
        completedExisting: { ", checked off \($0) existing to-do\($0 == 1 ? "" : "s")" },
        savedRawNote: { "\($0). Saved the original text as a note." },
        organizeFailed: { "Couldn't organize (\($0)). Saved the original text as a note." },
        summaryDone: "Summary ready", summaryFailed: { "Couldn't summarize: \($0)" },
        copied: "Markdown copied", cleared: { "Cleared \($0)" },
        loginFailed: { "Couldn't change launch at login: \($0)" },
        modelNotEligible: "This Mac doesn't support Apple Intelligence",
        modelNotEnabled: "Apple Intelligence is turned off",
        modelNotReady: "The on-device model is still downloading",
        modelUnavailable: "The on-device model is unavailable",
        markDone: "Mark as done", markTodo: "Mark as to-do", edit: "Edit", delete: "Delete", copy: "Copy",
        changeTo: { "Move to \($0)" }, add: { "Add to \($0)" }, addPlaceholder: { "Add to \($0), press Enter" },
        saveHint: "Save (Enter)", cancelHint: "Cancel (Esc)",
        itemCount: { "\($0) item\($0 == 1 ? "" : "s")" }, none: "(none)",
        modelSettings: "Model settings", engineLabel: "Model used for organizing", engineApple: "On-device (Mac)",
        appleInfo: "Uses Apple Intelligence built into your Mac. Free, works offline, and nothing leaves this Mac.",
        apiKey: "API key", keychainNote: "Stored in the macOS Keychain, never in a settings file", baseURL: "Base URL",
        modelLabel: "Model", loadModels: "Load list", chooseModel: { "Choose a model (\($0))" },
        testConnection: "Test connection", testing: "Testing…",
        testOK: { "Connected. Organized \($0) item\($0 == 1 ? "" : "s"): \($1)" },
        testSample: "Fixed the login page bug today. Need to send the weekly report to my manager tomorrow.",
        cloudPrivacy: { "What you paste is sent to \($0) for processing. Check before sending company or customer data." },
        ollamaLocal: "Ollama runs on this Mac, so nothing leaves it.",
        missingKey: { "No \($0) API key yet" }, missingModel: "No model selected yet",
        appearance: "Appearance", appearSystem: "Follow system", appearLight: "Light", appearDark: "Dark",
        toggleTheme: "Toggle light/dark", back: "Back", pasteAndOrganize: "Paste & organize", clipboardEmpty: "The clipboard has no text", engineShort: "Local", layout: "Layout", layoutList: "List", layoutTabs: "Tabs", backToToday: "Back to today"
    )

    static let ja = Strings(
        todo: "ToDo", done: "完了", note: "メモ",
        today: "今日", yesterday: "昨日", daysAgo: { "\($0) 日前" },
        prevDay: "前の日", nextDay: "次の日",
        settings: "設定", launchAtLogin: "ログイン時に起動", language: "言語", followSystem: "システムに合わせる",
        openFolder: "データフォルダを開く", clearDayMenu: { "\($0) の記録を消去…" },
        placeholderToday: "議事録、チャット、メモ、終わったことを貼り付け…",
        placeholderPast: { "\($0) に追加…" },
        organize: "整理", organizing: "整理中…", organizeHelp: "オンデバイスモデルで整理（⌘↩）",
        paste: "貼り付け", pasteHelp: "クリップボードから貼り付け", clear: "クリア",
        summaryTitle: "今日のまとめ", editSummary: "まとめを編集", deleteSummary: "まとめを削除",
        cancel: "キャンセル", save: "保存",
        emptyTodo: "ToDo はありません", emptyDone: "この日の完了記録はまだありません", emptyNote: "メモはまだありません",
        confirmClear: { "\($0) の記録をすべて消去しますか？" }, clearAction: "消去",
        generateSummary: "まとめを作成", copyMarkdown: "Markdown をコピー", quit: "終了",
        added: { "\($0) 件追加" }, completedExisting: { "、既存の ToDo を \($0) 件完了" },
        savedRawNote: { "\($0)。原文をメモとして保存しました" },
        organizeFailed: { "整理できませんでした（\($0)）。原文をメモとして保存しました" },
        summaryDone: "まとめを作成しました", summaryFailed: { "まとめを作成できませんでした：\($0)" },
        copied: "Markdown をコピーしました", cleared: { "\($0) の記録を消去しました" },
        loginFailed: { "ログイン時の起動を変更できませんでした：\($0)" },
        modelNotEligible: "この Mac は Apple Intelligence に対応していません",
        modelNotEnabled: "Apple Intelligence がオフになっています",
        modelNotReady: "オンデバイスモデルを準備中です",
        modelUnavailable: "オンデバイスモデルを利用できません",
        markDone: "完了にする", markTodo: "ToDo に戻す", edit: "編集", delete: "削除", copy: "コピー",
        changeTo: { "\($0)に移動" }, add: { "\($0)を追加" }, addPlaceholder: { "\($0)を追加（Enter で保存）" },
        saveHint: "保存（Enter）", cancelHint: "キャンセル（Esc）", itemCount: { "\($0) 件" }, none: "（なし）",
        modelSettings: "モデル設定", engineLabel: "整理に使うモデル", engineApple: "Mac のオンデバイスモデル",
        appleInfo: "Mac 内蔵の Apple Intelligence を使います。無料・オフラインで動作し、内容はこの Mac から出ません。",
        apiKey: "API キー", keychainNote: "macOS のキーチェーンに保存され、設定ファイルには書き込まれません", baseURL: "Base URL",
        modelLabel: "モデル", loadModels: "一覧を読み込む", chooseModel: { "モデルを選択（\($0)）" },
        testConnection: "接続テスト", testing: "テスト中…",
        testOK: { "接続できました。\($0) 件に整理：\($1)" },
        testSample: "今日はログイン画面のバグを直した。明日は上司に週報を送る。",
        cloudPrivacy: { "貼り付けた内容は \($0) に送信されます。社内や顧客のデータは送ってよいか確認してください。" },
        ollamaLocal: "Ollama はこの Mac で動いているので、内容は外に出ません。",
        missingKey: { "\($0) の API キーが未設定です" }, missingModel: "モデルが未設定です",
        appearance: "外観", appearSystem: "システムに合わせる", appearLight: "ライト", appearDark: "ダーク",
        toggleTheme: "ライト／ダークを切り替え", back: "戻る", pasteAndOrganize: "貼り付けて整理", clipboardEmpty: "クリップボードにテキストがありません", engineShort: "ローカル", layout: "表示方法", layoutList: "リスト", layoutTabs: "タブ", backToToday: "今日に戻る"
    )
}

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue = AppLanguage.system
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

extension AppLanguage {
    func dayTitle(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMdEEEE")
        return f.string(from: Store.date(key))
    }

    /// 標題列用的短日期：星期用縮寫（Wed, Nov 4／11月4日 週三）
    func shortDayTitle(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("MMMdEEE")
        return f.string(from: Store.date(key))
    }

    func shortDate(_ key: String) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.setLocalizedDateFormatFromTemplate("Md")
        return f.string(from: Store.date(key))
    }
}

/// 外觀：預設跟隨系統，也可以固定淺色／深色
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance"

    var id: String { rawValue }

    static var current: Appearance {
        Appearance(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    func label(_ s: Strings) -> String {
        switch self {
        case .system: return s.appearSystem
        case .light: return s.appearLight
        case .dark: return s.appearDark
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApplication.shared.appearance = nil
        case .light: NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case .dark: NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
