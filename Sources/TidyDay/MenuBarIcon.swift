import AppKit

/// 選單列圖示：有待辦時在右上角加一個實心圓形徽章，數字鏤空。
/// 做成模板圖片，系統會依淺色／深色選單列自動著色。
enum MenuBarIcon {
    static func image(count: Int) -> NSImage {
        let symbol = NSImage(systemSymbolName: "checklist", accessibilityDescription: "TidyDay")!
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
        let s = symbol.size
        let h: CGFloat = 18
        guard count > 0 else {
            symbol.isTemplate = true
            return symbol
        }
        let text = count > 99 ? "99+" : "\(count)"
        let font = NSFont.systemFont(ofSize: 8, weight: .heavy)
        let ts = (text as NSString).size(withAttributes: [.font: font])
        let bh: CGFloat = 10, bw = max(bh, ts.width + 4)
        let size = NSSize(width: s.width + bw * 0.8, height: h)
        let img = NSImage(size: size, flipped: false) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            symbol.draw(in: NSRect(x: 0, y: (h - s.height) / 2, width: s.width, height: s.height))
            let badge = NSRect(x: size.width - bw, y: h - bh, width: bw, height: bh)
            // 徽章周圍留一圈空白，跟圖示分開
            cg.setBlendMode(.clear)
            NSBezierPath(roundedRect: badge.insetBy(dx: -1.5, dy: -1.5), xRadius: bh / 2 + 1.5, yRadius: bh / 2 + 1.5).fill()
            cg.setBlendMode(.normal)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: badge, xRadius: bh / 2, yRadius: bh / 2).fill()
            cg.setBlendMode(.destinationOut)
            (text as NSString).draw(at: NSPoint(x: badge.midX - ts.width / 2, y: badge.midY - ts.height / 2),
                                    withAttributes: [.font: font, .foregroundColor: NSColor.black])
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "TidyDay, \(count)"
        return img
    }
}
