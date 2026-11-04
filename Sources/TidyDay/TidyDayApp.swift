import SwiftUI
import ServiceManagement

@main
struct TidyDayApp: App {
    @StateObject private var store = Store()

    init() {
        // 第一次啟動時預設開啟「開機時啟動」，之後以使用者在選單裡的設定為準
        let key = "loginItemConfigured"
        if !UserDefaults.standard.bool(forKey: key) {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            Image(systemName: "checklist")
        }
        .menuBarExtraStyle(.window)
    }
}
