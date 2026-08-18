# Claude Usage Mini — Windows

A system-tray version of Claude Usage Mini for Windows 11: the session /
weekly / per-model (including Fable) usage limits, a dark flyout, in-app
claude.ai sign-in, and an optional Claude Code statusline feed.

Same behaviour as the macOS build — the tray icon replaces the menu bar item.

## What you get

- **Tray icon** showing the session percentage; hover for the full
  `25%(4%) · 2:00pm` label.
- **Flyout** (left-click the tray icon) with a card per limit — Session,
  All models, and each model the account has used, Fable included.
- **Sign in** inside the app (WebView2): the `sessionKey` cookie is captured
  automatically, Google SSO supported. No copying cookies from DevTools.
- **Launch at login** (per-user, no admin) — on by default; remove it from
  Task Manager → Startup if you don't want it.
- **Statusline feed**: the app writes `%USERPROFILE%\.claude\.statusline-*-cache`;
  a PowerShell script renders them into the Claude Code statusline.

## Prerequisites

1. **Windows 11** (Windows 10 20H1+ also works).
2. **.NET 8 SDK** — https://dotnet.microsoft.com/download/dotnet/8.0
   (verify with `dotnet --version`, expect `8.x`).
3. **WebView2 Runtime** — preinstalled on Windows 11. On older builds get the
   Evergreen runtime: https://developer.microsoft.com/microsoft-edge/webview2/
   The NuGet package is pulled automatically by the build.

## Build

From this `windows` folder in a Developer PowerShell / Command Prompt:

```powershell
cd ClaudeUsageMini
dotnet build -c Release
```

For a single self-contained `.exe` you can copy anywhere (no .NET install
needed on the target machine):

```powershell
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true
```

The executable lands in
`ClaudeUsageMini\bin\Release\net8.0-windows\win-x64\publish\ClaudeUsageMini.exe`.

## Run

Double-click `ClaudeUsageMini.exe`. It starts in the tray (no window).
Left-click the tray icon → **Sign In** → sign in to claude.ai once. Usage
appears within a few seconds and refreshes every 60 seconds.

To move it into a stable location and have it start with Windows, copy the
published `.exe` to e.g. `%LOCALAPPDATA%\ClaudeUsageMini\` and run it once —
it registers itself for launch-at-login from wherever it runs.

## Statusline (optional)

Only needed if you use the Claude Code CLI on this machine.

1. Copy `statusline.ps1` to `%USERPROFILE%\.claude\statusline.ps1`.
2. Add to `%USERPROFILE%\.claude\settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline.ps1\""
     }
   }
   ```

The tray app must be running — the script only reads the cache the app writes,
and shows the usage/Fable segments only while that cache is under 5 minutes old.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Flyout says "Not signed in" | Click **Sign In** and complete claude.ai login. |
| "Session expired" | Sign in again — the cookie was invalidated server-side. |
| Everything reads 0% | You have multiple orgs; the app already prefers the subscription org. If it persists, sign out/in. |
| Raw API dump for debugging | Run from a console with `set CUM_DEBUG=1 && ClaudeUsageMini.exe` — each request path + response prints to stderr. |
| Statusline shows no usage | The tray app isn't running, or the cache is stale (>5 min). |

## Notes

- claude.ai sits behind Cloudflare; requests reuse the WebView2 cookie store
  (`cf_clearance` etc.) and a browser User-Agent — a bare `sessionKey` gets a
  403 challenge page.
- This is an unofficial client of claude.ai's internal web API; the response
  shape can change without notice. `UsageApi.Parse` handles both the legacy
  `seven_day_*` fields and the newer `limits[]` array.
- The session key lives only in the WebView2 cookie store under
  `%LOCALAPPDATA%\ClaudeUsageMini\WebView2` — nothing is written to a plaintext
  key file on Windows.
