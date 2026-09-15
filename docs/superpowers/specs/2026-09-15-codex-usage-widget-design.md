# Codex Usage Menu Bar Design

## Goal

Extend the existing macOS Claude Usage Mini application so its single menu-bar
item is driven by Codex usage. Clicking the item shows both Codex and Claude
usage in one popover.

The menu-bar label uses the compact format `C 62%(0%)`: weekly Codex usage
first and monthly Codex usage in parentheses. Reset dates remain in the
popover, where there is enough space to label them clearly.

## Scope

This change applies only to the native macOS application in `Sources/`. The
Windows tray application is unchanged. The application and bundle retain the
Claude Usage Mini name for this iteration; renaming and Windows parity are
separate concerns.

## Usage Sources

### Codex

Codex data comes from the locally installed Codex CLI's app-server protocol.
The application launches a persistent `codex app-server --stdio` subprocess,
sends the JSON-RPC `initialize` request, and then requests
`account/rateLimits/read` on each refresh.

The application resolves the executable without assuming that a login-item
process inherits the user's interactive shell `PATH`. It checks the current
environment and standard user/system installation paths, including
`~/.local/bin/codex`, `/opt/homebrew/bin/codex`, and
`/usr/local/bin/codex`.

The response is mapped as follows:

- Weekly usage comes from the rate-limit window whose duration is 10,080
  minutes. Its displayed percentage is `usedPercent`.
- Monthly usage comes from `individualLimit`. Its displayed percentage is
  `100 - remainingPercent`.
- Percentages are clamped to the inclusive 0–100 range before display.
- Unix reset timestamps are converted to `Date` values and use the existing
  local reset-date formatting.

The integration does not read, parse, or copy `~/.codex/auth.json`. Codex owns
authentication, token refresh, and the upstream request.

### Claude

The existing Claude API, cookie handling, organization selection, and parser
remain unchanged. Claude and Codex failures are isolated so one provider can
remain useful when the other is unavailable.

## Application State and Refreshing

`UsageModel` holds independent Codex and Claude usage snapshots, errors, and
loading states. Its existing 60-second timer triggers both provider refreshes.
Each successful provider refresh replaces only that provider's snapshot and
clears only that provider's error.

The Codex app-server connection stays alive between refreshes. If the process
exits, stdout closes, initialization fails, or a response cannot be decoded,
the Codex client tears down the stale process, starts a fresh process, and
retries the read once. A failed retry becomes a Codex-section error and does
not disrupt Claude data or the application itself.

Concurrent refresh calls remain coalesced so timer and manual refresh actions
cannot create duplicate provider requests.

## Menu-Bar Label

The single menu-bar item represents Codex only:

- Both limits available: `C 62%(0%)`
- Weekly limit only: `C 62%`
- No successful Codex snapshot yet: `C —`

The label intentionally excludes reset time to remain compact. It keeps the
existing rounded, monospaced-digit styling.

## Popover

The popover keeps the existing dark visual language, severity colors, cards,
progress bars, and reset formatting.

Content order is:

1. A `Codex` section heading.
2. A Weekly card when weekly data is available.
3. A Monthly card when monthly data is available.
4. A compact Codex error card when Codex cannot refresh.
5. A `Claude` section heading.
6. The existing Claude Session Usage, All models, and model-specific cards.
7. The existing Claude sign-in or error state when required.
8. One shared footer with last-updated time, Refresh, and Quit.

A provider's last successful cards remain visible alongside a refresh error,
so a temporary failure does not turn useful data into an empty state. The
shared updated time reflects the most recent successful provider refresh.

## Errors

Codex errors use short operator-facing messages for these cases:

- Codex CLI not found.
- Codex is not signed in.
- Codex app-server connection failed.
- Codex returned an unsupported or malformed usage response.

The app does not expose raw JSON, process output, tokens, or account IDs in the
popover. Detailed diagnostics may be written to stderr only when the existing
debug environment flag is enabled.

## Verification

Parser checks cover:

- A weekly window plus monthly allowance maps to the correct used
  percentages and reset dates.
- Monthly usage is derived from `remainingPercent`, not displayed as remaining
  allowance.
- A response without `individualLimit` produces a weekly-only label and
  popover.
- Missing or malformed response fields produce a controlled error.
- Percentages below 0 or above 100 are clamped.
- Unrelated rate-limit buckets do not replace the `codex` bucket.

Model/UI checks cover menu-label formatting for both limits, weekly-only data,
and the initial unavailable state. Verification runs the focused parser check
script and the release build; it does not launch the menu-bar application or
take over the screen without separate user approval.

## Files Expected to Change

- `Sources/CodexUsageAPI.swift`: Codex process, JSON-RPC transport, response
  decoding, and mapping.
- `Sources/App.swift`: independent provider state, refresh orchestration, and
  Codex menu-label formatting.
- `Sources/PopoverView.swift`: Codex and Claude sections plus isolated errors.
- `Checks/main.swift`: focused Codex parser and label checks.
- `check.sh`: include the Codex checks if the current script requires explicit
  source enumeration.
- `README.md`: document combined macOS behavior, Codex dependency, privacy,
  and the unchanged Windows scope.

