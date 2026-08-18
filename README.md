# Claude Usage Mini

A minimal macOS menu bar app that shows your Claude AI usage limits — built
with SwiftUI and buildable with Command Line Tools only (no Xcode required).

Menu bar label: `25%(1%) · 2:00pm` — session usage, Fable weekly usage, and
the session reset time. The popover lists every limit the API reports
(session / all models / per-model weekly) with progress bars and reset times.

## Features

- Sign in to claude.ai inside the app (WKWebView); the `sessionKey` cookie is
  captured automatically — Google SSO popups supported
- 60-second polling of `claude.ai/api/organizations/{id}/usage`, preferring
  the subscription (team) organization when the account has several
- Claude Code statusline integration: writes
  `~/.claude/.statusline-fable-cache` so a statusline script can render a
  `Fable: N%` segment without calling the API itself
- Launch at login via `SMAppService` (no helper bundle)
- Session key stored at `~/.claude-session-key` (0600), compatible with
  [Claude-Usage-Tracker](https://github.com/hamed-elfayome/Claude-Usage-Tracker)

## Build & run

```bash
./build.sh          # swift build + .app bundle + ad-hoc codesign
open "Claude Usage Mini.app"
./check.sh          # parser self-check
```

Requires macOS 14+ and Command Line Tools (`xcode-select --install`).

## Debugging

```bash
CUM_DEBUG=1 "./Claude Usage Mini.app/Contents/MacOS/ClaudeUsageMini"
```

prints each API request path and raw response body to stderr.

## Notes

- claude.ai sits behind Cloudflare; requests reuse the sign-in web view's
  cookie store (`cf_clearance` etc.) and a browser User-Agent — a bare
  `sessionKey` gets a 403 challenge page.
- This is an unofficial client of claude.ai's internal web API; the response
  shape can change without notice. `UsageAPI.parse` handles both the legacy
  `seven_day_*` fields and the newer `limits[]` array.

## License

MIT — see [LICENSE](./LICENSE). Sign-in and cache-format approaches adapted
from Claude-Usage-Tracker (MIT, Hamed Elfayome).
