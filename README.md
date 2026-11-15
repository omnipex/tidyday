# TidyDay

A menu bar app for macOS that tidies up your day. Paste anything (meeting notes, chat logs, quick thoughts) and an on-device model sorts it into **Done**, **To-do** and **Notes**.

<p align="center">
  <img src="docs/screenshot-light.png" width="380" alt="TidyDay in light mode, showing a daily summary, to-dos and done items">
  <img src="docs/screenshot-dark.png" width="380" alt="TidyDay in dark mode">
</p>

[繁體中文說明](#繁體中文)

## Features

- **Paste and organize.** One click pastes your clipboard and splits it into items. Each item is classified as done, to-do or note.
- **Understands sentences with more than one thing.** "Fixed the login bug, but still need to write tests" becomes a done item and a to-do.
- **Checks off existing to-dos.** If you paste "sent the budget draft", TidyDay marks the matching open to-do as done.
- **To-dos carry over.** Unfinished to-dos stay on your list across days until you check them off.
- **Calendar.** Items that mention a time ("call the dentist tomorrow at 10am", "by Friday") get a date. A week, month or year view shows what is coming up. Click a time label to add the item to the macOS Calendar app.
- **Menu bar count.** The menu bar icon shows how many to-dos need your attention today.
- **Global shortcut.** Press ⌃⌥T from any app to open TidyDay with the cursor in the input box. You can turn this off in ⚙️.
- **Daily summary.** Generates a short summary of the day. You can copy the whole day as Markdown.
- **On-device by default.** Uses Apple Intelligence (Foundation Models) on your Mac. It is free, works offline, and nothing leaves your machine.
- **Optional other models.** You can switch to OpenAI, Claude, Gemini, OpenRouter or Ollama. API keys are stored in the macOS Keychain.
- **Languages.** The interface and the model output support English, 繁體中文, 简体中文 and 日本語. The default follows your system language.
- **Light and dark mode.** Follows the system by default. The moon icon switches it.
- **Two layouts.** A list (default) or tabs.

## Requirements

- A Mac with Apple silicon (M1 or later)
- macOS 26 or later
- Apple Intelligence turned on (System Settings → Apple Intelligence & Siri) for the on-device model

Without Apple Intelligence you can still use a cloud model or Ollama. If no model is available, pasted text is saved as a note as-is.

## Install

Download the `.dmg` from [Releases](../../releases) and drag TidyDay to Applications.

The app is not signed with an Apple Developer ID yet, so macOS blocks the first launch. To open it, do one of these:

- Open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to TidyDay.
- Or run this in Terminal:
  ```sh
  xattr -dr com.apple.quarantine /Applications/TidyDay.app
  ```

TidyDay has no window. Look for the checklist icon in the menu bar. It sets itself to launch at login the first time it runs; you can turn this off in ⚙️.

## Build from source

You need Xcode 26 or later.

```sh
./build.sh            # builds build/TidyDay.app
./build.sh install    # builds, installs to ~/Applications and launches
./build.sh dist       # builds build/TidyDay-<version>.dmg
```

To sign and notarize with your own Developer ID:

```sh
SIGN_ID="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=notary ./build.sh dist
```

## How organizing works

The on-device model is small, so TidyDay does not trust a single answer. It works in steps:

1. The model quotes the original words for each item, notes the words that decide the tense ("finished", "by Friday"), and then picks done, to-do or note.
2. TidyDay checks the result with simple rules: a sentence with both finished and unfinished parts, a done item that only says "need to", lines that no item covers, invented or duplicated items.
3. Only the sentences with a problem go back to the model for a second look.

Dates are read from your original text with the system date parser, not by the model.

The `eval/` folder has 112 test cases in English, Chinese and Japanese, including chat logs, meeting notes and sentences with more than one thing. Run them with:

```sh
eval/run.sh 3        # every case, 3 times each (about 20 minutes)
eval/run.sh 2 mi-    # only the cases whose id starts with mi-
```

The last run scored 96.7% (the previous single-prompt version scored 84.2%).

## Use with AI assistants (MCP)

TidyDay includes an [MCP](https://modelcontextprotocol.io) server, so assistants such as Claude Desktop, Claude Code and Cursor can read and update your log. The server is the app itself run with `--mcp`. It uses the same data folder and the same organizing engine as the app, and the app picks up changes right away.

Claude Code:

```sh
claude mcp add tidyday -- /Applications/TidyDay.app/Contents/MacOS/TidyDay --mcp
```

Claude Desktop, Cursor and other clients (`claude_desktop_config.json`, `.cursor/mcp.json`, ...):

```json
{
  "mcpServers": {
    "tidyday": {
      "command": "/Applications/TidyDay.app/Contents/MacOS/TidyDay",
      "args": ["--mcp"]
    }
  }
}
```

If you installed with `./build.sh install`, the path is `~/Applications/TidyDay.app/Contents/MacOS/TidyDay`. Write it out in full, because most clients do not expand `~`.

| Tool | What it does |
|---|---|
| `list_days` | Days up to today that have items, with how many items each day has |
| `get_day` | One day's to-dos, done items, notes, scheduled items and summary |
| `search` | Find items by text across all days |
| `add_items` | Add items when the kind is already known, with an optional due date |
| `organize_text` | Split free-form text into items with TidyDay's organizer |
| `update_item` | Edit text, complete or reopen, pin, or reschedule an item |
| `delete_item` | Delete an item |
| `set_summary` | Replace or remove a day's summary |

Days are written as `yyyy-MM-dd` in your local time zone. Leave the day out to mean today. Set `TIDYDAY_DATA_DIR` in the server's environment to try it on a copy of your data.

The server only talks to the client that started it, over standard input and output. It does not open a network port. With a cloud model selected, `organize_text` sends the text to that provider, just as organizing in the app does.

## Privacy

- Your entries are stored as one JSON file per day in `~/Library/Application Support/TidyDay/days/`.
- With the on-device model, or Ollama on `localhost`, nothing leaves your Mac.
- With a cloud model, the text you organize is sent to that provider. The settings page shows a warning when this applies.
- API keys are kept in the macOS Keychain and never written to a settings file.
- Calendar access is write-only. TidyDay can add events when you click a time label, but it cannot read your existing events.

## Known limitations

- The on-device model is small and still makes mistakes, about 3 in 100 items in the test set. For example, it may split a chat thread into a to-do and a done item instead of one. You can right-click an item to move it.
- Organizing takes about 3 seconds, because TidyDay double-checks unclear sentences.
- Removing a to-do does not remove an event you already added to Calendar.
- Switching the language does not translate items you have already saved.

## License

[MIT](LICENSE)

---

## 繁體中文

TidyDay 是常駐在 macOS 選單列的小工具。把會議紀錄、聊天內容、隨手筆記貼上，本地模型會自動整理成**已完成**、**待辦**、**筆記**。

- **貼上並整理**：一鍵貼上剪貼簿內容，自動拆成條列並分類。
- **一句話多件事也能拆開**：「bug 修好了但還沒部署」會變成一筆已完成、一筆待辦。
- **自動勾掉待辦**：貼上「預算草稿寄出了」，對應的待辦會自動標成完成。
- **待辦跨天延續**：沒做完的會一直留著，直到你勾掉。
- **行事曆**：提到時間的事（「明天下午 3 點開會」「週五前」）會自動記下日期，可以用週、月、年檢視；點時間標籤就能加到 macOS 行事曆。
- **選單列數字**：圖示上顯示今天要處理的待辦數。
- **全域快捷鍵**：在任何 App 按 ⌃⌥T 叫出 TidyDay，直接輸入。
- **每日總結**：產生幾句話的當日摘要，也可以整天複製成 Markdown。
- **預設用 Mac 本地模型**：免費、不用網路，內容不會離開你的電腦。也可以改用 OpenAI、Claude、Gemini、OpenRouter 或 Ollama，API key 存在鑰匙圈。
- **多國語系**：介面和模型輸出支援繁中、简中、English、日本語，預設跟隨系統。

**需要的環境**：Apple 晶片的 Mac、macOS 26 以上；要用本地模型的話，需要開啟 Apple Intelligence。

**安裝**：從 [Releases](../../releases) 下載 DMG，把 TidyDay 拖到「應用程式」。這版還沒有 Apple 開發者簽章，第一次打開會被擋下來，請到「系統設定 → 隱私權與安全性」按「仍要打開」。

**給 AI 助理用（MCP）**：TidyDay 內建 MCP 伺服器，Claude Desktop、Claude Code、Cursor 等工具可以讀取、新增、完成你的紀錄。伺服器就是 app 本身加上 `--mcp` 參數執行，和 app 共用同一份資料和整理引擎，app 開著時也會馬上顯示變動。Claude Code 用 `claude mcp add tidyday -- /Applications/TidyDay.app/Contents/MacOS/TidyDay --mcp` 加入；其他工具的設定檔和工具清單請見上方英文說明的「Use with AI assistants (MCP)」。伺服器只透過標準輸入輸出和啟動它的工具溝通，不會開網路埠。
