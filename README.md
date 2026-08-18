# Claude Usage Mini

A lightweight menu bar (macOS) and system-tray (Windows) app that shows your
Claude AI usage limits in real time — session, weekly, and per-model usage
including **Fable**. Built native on each platform, no Electron.

- **macOS** — SwiftUI menu bar app, buildable with Command Line Tools only (no Xcode).
- **Windows** — .NET 8 / WPF system-tray app.

The label reads `25%(1%) · 2:00pm` — session usage, Fable weekly usage, and the
session reset time. Click it for a card per limit (session / all models /
per-model weekly) with progress bars and reset times.

## Features

- **Fable usage** — the weekly per-model limit most trackers miss, shown in the
  label and the popup
- **Sign in inside the app** (WKWebView / WebView2) — the `sessionKey` cookie is
  captured automatically, Google SSO supported; no copying cookies from DevTools
- **60-second polling** of `claude.ai/api/organizations/{id}/usage`, preferring
  the subscription (team) organization when the account has several
- **Claude Code statusline integration** — writes a small cache under `~/.claude/`
  so a statusline script can render a `Fable: N%` segment without calling the API
- **Launch at login** — `SMAppService` on macOS, the per-user Run key on Windows
- **Privacy-first** — the session cookie stays local (macOS: `~/.claude-session-key`,
  0600; Windows: the WebView2 cookie store); no cloud, no telemetry

---

## macOS

### Build & run

```bash
git clone https://github.com/klyhyeon/claude-usage-mini.git
cd claude-usage-mini
./build.sh                    # swift build + .app bundle + ad-hoc codesign
open "Claude Usage Mini.app"
```

Requires macOS 14+ and Command Line Tools (`xcode-select --install`). No Xcode.

Click the menu bar item → **Sign In** → sign in to claude.ai once. Usage appears
within a few seconds and refreshes every 60 seconds.

### Debugging

```bash
CUM_DEBUG=1 "./Claude Usage Mini.app/Contents/MacOS/ClaudeUsageMini"
```

prints each API request path and raw response body to stderr. `./check.sh` runs
the parser self-check.

---

## Windows

Full guide: [`windows/README.md`](./windows/README.md). Short version:

### Option A — download the prebuilt exe (no build tools)

1. Open the repo's **[Actions](../../actions/workflows/windows.yml)** tab →
   the latest successful **windows** run → **Artifacts** → download
   `ClaudeUsageMini-win-x64`.
2. Unzip and run `ClaudeUsageMini.exe`. It starts in the system tray (no window).
3. Needs the **WebView2 Runtime** — preinstalled on Windows 11; on Windows 10 get
   it from https://developer.microsoft.com/microsoft-edge/webview2/

### Option B — build it yourself

Requires the [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

```powershell
cd windows\ClaudeUsageMini
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

The exe lands in
`windows\ClaudeUsageMini\bin\Release\net8.0-windows\win-x64\publish\ClaudeUsageMini.exe`.

### Use

Left-click the tray icon → **Sign In** → sign in to claude.ai once. The tray icon
shows the session percentage; hover for the full `25%(4%) · 2:00pm` label; click
for the full breakdown. It registers itself to launch at login (remove it from
Task Manager → Startup to opt out).

---

## Claude Code statusline (optional)

If you use the Claude Code CLI, the app can feed its statusline.

- **macOS** — the app writes `~/.claude/.statusline-fable-cache` and
  `~/.claude/.statusline-usage-cache`; a statusline script reads them and renders
  `Usage: N% … Fable: N%`.
- **Windows** — copy [`windows/statusline.ps1`](./windows/statusline.ps1) to
  `%USERPROFILE%\.claude\statusline.ps1` and register it in
  `%USERPROFILE%\.claude\settings.json` (see the Windows README).

The app must be running — the script only reads the cache and shows the usage
segments while it is under 5 minutes old.

---

## Notes

- claude.ai sits behind Cloudflare; requests reuse the sign-in web view's cookie
  store (`cf_clearance` etc.) and a browser User-Agent — a bare `sessionKey` gets
  a 403 challenge page.
- This is an **unofficial** client of claude.ai's internal web API; the response
  shape can change without notice. The parser handles both the legacy
  `seven_day_*` fields and the newer `limits[]` array.
- Not affiliated with Anthropic.

## License

MIT — see [LICENSE](./LICENSE). Sign-in and cache-format approaches adapted from
[Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker)
(MIT, Hamed Elfayome).
