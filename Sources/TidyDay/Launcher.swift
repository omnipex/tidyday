import Foundation

/// 進入點：`TidyDay --mcp` 以 stdio 執行 MCP 伺服器（不顯示任何介面），其他情況照常啟動 app
@main
@MainActor
enum Launcher {
    static func main() {
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.run()
        } else {
            TidyDayApp.main()
        }
    }
}
