import AppKit
import SwiftUI
import Combine

/// 選單列圖示＋下拉面板。原本用 SwiftUI MenuBarExtra，但它沒有公開的開關 API，
/// 全域快捷鍵叫不出來（performClick、模擬滑鼠事件都試過無效），所以改成自己管理 NSStatusItem 與面板。
@MainActor
final class StatusController: NSObject {
    static let shared = StatusController()

    let store = Store()
    private var item: NSStatusItem!
    private var panel: StatusPanel!
    private var cancellable: AnyCancellable?
    private var dayObserver: NSObjectProtocol?

    func start() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        refreshIcon()
        // 待辦有變動就更新圖示上的數字
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshIcon() }
        }
        dayObserver = NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIcon() }
        }

        panel = StatusPanel(content: ContentView().environmentObject(store))
    }

    private func refreshIcon() {
        item.button?.image = MenuBarIcon.image(count: store.actionableTodos(on: Store.today).count)
    }

    var isOpen: Bool { panel.isVisible }

    private var closedAt = Date.distantPast

    @objc func togglePanel() {
        // 面板開著時點圖示：面板會先因失去焦點自己收起，這時不要又馬上打開
        if isOpen { close() } else if Date().timeIntervalSince(closedAt) > 0.3 { open() }
    }

    func open(focusInput: Bool = false) {
        guard let button = item.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.frame
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: anchor.minY - size.height - 6))
        button.highlight(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if focusInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NotificationCenter.default.post(name: GlobalHotKey.focusInput, object: nil)
            }
        }
    }

    func close() {
        closedAt = Date()
        panel.orderOut(nil)
        item.button?.highlight(false)
    }
}

/// 無邊框、毛玻璃、圓角的面板；點到面板外面（失去焦點）就收起，跟系統選單列面板一樣
final class StatusPanel: NSPanel {
    init<V: View>(content: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 640),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            host.topAnchor.constraint(equalTo: fx.topAnchor),
            host.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        // 點到別的地方就收起；但面板裡跳出的選單（齒輪、日期）會暫時拿走焦點，那時不要收
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.isVisible, !self.isKeyWindow else { return }
            let popupOpen = NSApp.windows.contains { w in
                w !== self && w.isVisible && (w.parent == self || w.className.contains("Popover") || w.className.contains("Menu"))
            }
            if popupOpen { return }
            MainActor.assumeIsolated { StatusController.shared.close() }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { StatusController.shared.close() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            StatusController.shared.start()
            GlobalHotKey.shared.apply()
        }
    }
}
