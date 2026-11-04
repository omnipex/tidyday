# TidyDay

A menu bar app for macOS that tidies up your day. Paste anything (meeting notes, chat logs, quick thoughts) and an on-device model sorts it into **Done**, **To-do** and **Notes**.

[繁體中文說明](#繁體中文)

## Features

- **Paste and organize.** One click pastes your clipboard and splits it into items. Each item is classified as done, to-do or note.
- **Checks off existing to-dos.** If you paste "sent the budget draft", TidyDay marks the matching open to-do as done.
- **To-dos carry over.** Unfinished to-dos stay on your list across days until you check them off.
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

## Privacy

- Your entries are stored as one JSON file per day in `~/Library/Application Support/TidyDay/days/`.
- With the on-device model, or Ollama on `localhost`, nothing leaves your Mac.
- With a cloud model, the text you organize is sent to that provider. The settings page shows a warning when this applies.
- API keys are kept in the macOS Keychain and never written to a settings file.

## Known limitations

- The on-device model is small. It sometimes misclassifies items. For example, it may split a chat thread into a to-do and a done item instead of one. You can right-click an item to move it.
- To avoid losing information, TidyDay adds any substantial line the model skipped back as a note, so you may occasionally see an extra note.
- Switching the language does not translate items you have already saved.

## License

[MIT](LICENSE)

---

## 繁體中文

TidyDay 是常駐在 macOS 選單列的小工具。把會議紀錄、聊天內容、隨手筆記貼上，本地模型會自動整理成**已完成**、**待辦**、**筆記**。

- **貼上並整理**：一鍵貼上剪貼簿內容，自動拆成條列並分類。
- **自動勾掉待辦**：貼上「預算草稿寄出了」，對應的待辦會自動標成完成。
- **待辦跨天延續**：沒做完的會一直留著，直到你勾掉。
- **每日總結**：產生幾句話的當日摘要，也可以整天複製成 Markdown。
- **預設用 Mac 本地模型**：免費、不用網路，內容不會離開你的電腦。也可以改用 OpenAI、Claude、Gemini、OpenRouter 或 Ollama，API key 存在鑰匙圈。
- **多國語系**：介面和模型輸出支援繁中、简中、English、日本語，預設跟隨系統。

**需要的環境**：Apple 晶片的 Mac、macOS 26 以上；要用本地模型的話，需要開啟 Apple Intelligence。

**安裝**：從 [Releases](../../releases) 下載 DMG，把 TidyDay 拖到「應用程式」。這版還沒有 Apple 開發者簽章，第一次打開會被擋下來，請到「系統設定 → 隱私權與安全性」按「仍要打開」。
