import SwiftUI
import ServiceManagement

@main
struct TidyDayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // 第一次啟動時預設開啟「開機時啟動」，之後以使用者在選單裡的設定為準
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    // 選單列圖示與面板由 StatusController 管理（見 StatusPanel.swift）；這裡只需要一個不會顯示的 Scene
    var body: some Scene {
        Settings { EmptyView() }
    }
}
