import Foundation

// TidyDay 分類評估：讀 cases.json，用 App 實際的 Organizer.parse 跑每個案例 N 次，計分並列出錯誤。
// 用法：./run.sh [次數] [篩選id前綴]

struct Case: Decodable {
    let id: String
    let cat: String
    let text: String
    let expect: [[String]]          // [種類（可用 | 允許多種）, 關鍵字（可用 | 允許多個）]
    var todos: [String]? = nil
    var expectCompleted: [Int]? = nil
}

struct Tally { var expected = 0, correct = 0, wrongKind = 0, missing = 0, extra = 0, runs = 0, compOK = 0, compRuns = 0, simplified = 0 }

let args = CommandLine.arguments
let runs = args.count > 1 ? Int(args[1]) ?? 3 : 3
let filter = args.count > 2 ? args[2] : ""
let dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: dir.appendingPathComponent("cases.json")))
    .filter { c in filter.isEmpty || filter.split(separator: ",").contains { c.id.hasPrefix($0) } }

var byCat: [String: Tally] = [:]
var total = Tally()
var failures: [String] = []
let start = Date()

for (n, c) in cases.enumerated() {
    // 進度直接寫到 stderr（不經緩衝），背景執行時可以隨時看跑到哪
    FileHandle.standardError.write("[\(n + 1)/\(cases.count)] \(c.id) \(Int(Date().timeIntervalSince(start)))s\n".data(using: .utf8)!)
    var t = Tally()
    for r in 0..<runs {
        let out: ParseOutput
        do {
            out = try await Organizer.parse(c.text, openTodos: c.todos ?? [], lang: .en, engine: .apple)
        } catch {
            failures.append("[\(c.id)] 第\(r+1)次 錯誤：\(error)")
            t.runs += 1; t.expected += c.expect.count; t.missing += c.expect.count
            continue
        }
        t.runs += 1
        var used = Set<Int>()
        var problems: [String] = []
        for e in c.expect {
            // 種類前面加 ? 表示可有可無：列出來不算多出，沒列也不算漏抓
            let optional = e[0].hasPrefix("?")
            let kinds = e[0].trimmingCharacters(in: CharacterSet(charactersIn: "?")).split(separator: "|").map(String.init)
            if optional {
                let keys = e[1].split(separator: "|").map { $0.lowercased() }
                if let i = out.items.indices.first(where: { !used.contains($0) && keys.contains(where: out.items[$0].text.lowercased().contains) }) { used.insert(i) }
                continue
            }
            t.expected += 1
            let keys = e[1].split(separator: "|").map { $0.lowercased() }
            if let i = out.items.indices.first(where: { !used.contains($0) && keys.contains(where: out.items[$0].text.lowercased().contains) }) {
                used.insert(i)
                if kinds.contains(out.items[i].kind.rawValue) { t.correct += 1 }
                else { t.wrongKind += 1; problems.append("「\(e[1])」應為 \(e[0])，得到 \(out.items[i].kind.rawValue)") }
            } else {
                t.missing += 1; problems.append("漏掉「\(e[1])」")
            }
        }
        let extras = out.items.indices.filter { !used.contains($0) }
        t.extra += extras.count
        if !extras.isEmpty { problems.append("多出 " + extras.map { "\(out.items[$0].kind.rawValue):\(out.items[$0].text)" }.joined(separator: "、")) }
        if let exp = c.expectCompleted {
            t.compRuns += 1
            if out.completedTodoIndexes == Set(exp) { t.compOK += 1 }
            else { problems.append("勾既有待辦 應為 \(exp)，得到 \(out.completedTodoIndexes.sorted())") }
        }
        if Organizer.contentLanguage(c.text, fallback: .en).resolved == .zhHant {
            for it in out.items where it.text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) != it.text {
                t.simplified += 1; problems.append("疑似簡體：\(it.text)")
            }
        }
        if !problems.isEmpty {
            failures.append("[\(c.id)] \(c.text.replacingOccurrences(of: "\n", with: " / "))\n      → " + out.items.map { "\($0.kind.rawValue):\($0.text)" }.joined(separator: " ; ") + "\n      ✗ " + problems.joined(separator: "；") + "\n" + out.trace.map { "        · " + $0 }.joined(separator: "\n"))
        }
    }
    var cat = byCat[c.cat] ?? Tally()
    for (k, v) in [(\Tally.expected, t.expected), (\.correct, t.correct), (\.wrongKind, t.wrongKind), (\.missing, t.missing), (\.extra, t.extra), (\.runs, t.runs), (\.compOK, t.compOK), (\.compRuns, t.compRuns), (\.simplified, t.simplified)] as [(WritableKeyPath<Tally, Int>, Int)] {
        cat[keyPath: k] += v; total[keyPath: k] += v
    }
    byCat[c.cat] = cat
}

func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "  -  " : String(format: "%5.1f%%", Double(a) / Double(b) * 100) }
print("\n==== 錯誤明細 ====")
failures.forEach { print($0) }
print("\n==== 分類別（每案 \(runs) 次）====")
print("類別            正確率   錯類  漏抓  多出  勾待辦   簡體")
for (name, t) in byCat.sorted(by: { $0.key < $1.key }) {
    print(name.padding(toLength: 12, withPad: "　", startingAt: 0), pct(t.correct, t.expected), String(format: "%4d  %4d  %4d", t.wrongKind, t.missing, t.extra), pct(t.compOK, t.compRuns), String(format: "%4d", t.simplified))
}
print("總計：正確 \(total.correct)/\(total.expected) = \(pct(total.correct, total.expected))，錯類 \(total.wrongKind)，漏抓 \(total.missing)，多出 \(total.extra)，勾待辦 \(pct(total.compOK, total.compRuns))，簡體 \(total.simplified)")
print(String(format: "耗時 %.0f 秒", Date().timeIntervalSince(start)))
