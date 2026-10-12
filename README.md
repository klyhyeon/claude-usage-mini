# Claude Usage Mini

A lightweight menu bar (macOS) and system-tray (Windows) app that shows your
AI usage limits in real time. On macOS, choose Codex or Claude with the toggle
in the popover to switch the usage cards and menu bar label. Windows remains
a Claude-only system-tray application. Built native on each platform, no
Electron.

- **macOS** — SwiftUI menu bar app, buildable with Command Line Tools only (no Xcode).
- **Windows** — .NET 8 / WPF system-tray app.

On macOS, the Codex label reads `C 16% / 62%(0%)` — 5-hour usage, weekly usage,
and monthly usage in parentheses when available. Click it for usage cards and
reset times. Switch to Claude for its Session, All models, and per-model cards;
the Claude label reads `Cl 16% / 33%` for session and weekly usage. Your provider
choice is saved between launches. Limits are shown only when the provider
reports them; Codex accounts with only a weekly limit still show `C 62%`.

## Features

- **Codex 5-hour usage on macOS** — session usage and reset time alongside
  weekly and monthly limits when reported by your account
- **Codex / Claude toggle on macOS** — switches the cards and menu bar label,
  and remembers your choice between launches
- **Fable usage** — the weekly per-model Claude limit most trackers miss, shown
  in the Claude popover and cards
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

### 1. Prerequisites

- macOS 14 or later.
- Apple Command Line Tools with Swift 6 or later; the full Xcode app is not required.
  If the tools are missing, run `xcode-select --install` and finish the installer
  before continuing. Check the compiler with `swift --version`.
- The Codex CLI installed and signed in. In Terminal, run `codex login` before
  launching the widget. The widget reads usage through `codex app-server`.

### 2. Build and start

Open Terminal and run:

```bash
git clone https://github.com/klyhyeon/claude-usage-mini.git
cd claude-usage-mini
./build.sh
open "Claude Usage Mini.app"
```

If you already have the repository, `cd` into that folder and run the last two
commands. `build.sh` compiles the release executable, creates the app bundle in
that folder, and signs it locally.

Look in the **macOS menu bar at the top of the screen** for a label such as
`C 16% / 56%(3%)`. This is a menu bar app: it does not open a main window or appear
in the Dock. When both windows are reported, the percentages are 5-hour usage
followed by weekly usage; parentheses show monthly usage when available.

### 3. Connect accounts and use the widget

- Click the menu bar label to see usage cards and reset times.
- Use the **Codex / Claude** toggle at the top to choose the provider shown in
  the popover and menu bar.
- Select **Claude**, click **Sign In**, and complete the browser sign-in.
  If the session expires, click **Sign In Again**.
- The two providers refresh independently every 60 seconds. Click **Refresh**
  to request an update immediately. Both accounts keep refreshing regardless
  of which provider is selected; the update time belongs to the selected provider.
- If the label shows `C —`, open the popover and read the error. Confirm the CLI
  is installed and run `codex login` if it reports that you are not signed in.
- Click **Quit** at the bottom of the popover to stop the widget.

The app attempts to register itself to launch at login on its first run.
Manage its permission in **System Settings → General → Login Items**. Keep the
app bundle in a stable location so its login registration can find it.

### Start again or update

To start an already-built widget, double-click **Claude Usage Mini.app** in
Finder, or run this from the repository folder:

```bash
open "Claude Usage Mini.app"
```

To update, first click **Quit** in the running widget, then run these commands
from your repository folder (with any local changes saved):

```bash
git switch main
git pull --ff-only
./build.sh
open "Claude Usage Mini.app"
```

Rebuilding replaces the app bundle in the repository folder. Relaunch it to use
the updated executable.

### Debugging

```bash
CUM_DEBUG=1 "./Claude Usage Mini.app/Contents/MacOS/ClaudeUsageMini"
```

prints each Claude API request path and raw response body to stderr. Codex
app-server stderr is discarded. `./check.sh` runs the parser self-check.

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
- The Codex `app-server` contract is supplied by the locally installed Codex
  CLI. If that protocol evolves, update the CLI to the compatible version; the
  app does not bundle the protocol.
- Not affiliated with Anthropic.

## License

MIT — see [LICENSE](./LICENSE). Sign-in and cache-format approaches adapted from
[Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker)
(MIT, Hamed Elfayome).
