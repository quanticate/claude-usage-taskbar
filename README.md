# claude-usage-taskbar

A small Windows 11 taskbar widget that shows your Claude plan usage — the same numbers Claude Code's `/usage` shows — just left of the tray icons.

Single PowerShell script. No compiled exe, no extra dependencies (Windows PowerShell 5.1 + .NET Framework, both built in).

Inspired by [claude-usage-widget-for-windows-taskbar](https://github.com/AbdoSarmini/claude-usage-widget-for-windows-taskbar).

## What it shows

- Two rows: **5h** (5-hour window) and **7d** (weekly), each with a progress ring and percentage.
- Orange at 80%, red at 95%. Follows the Windows light/dark theme.
- **Hover:** reset times, model-specific weekly limits, last-updated time (or the error).
- **Left-click:** opens the claude.ai usage page.
- **Right-click:** Refresh now · Open usage page · Show remaining instead of used · Update interval (2/5/10/15 min) · Start with Windows · Exit.
- If data can't be fetched (network error, expired/rejected token, rate limit) the numbers become `–` and the widget dims — it never shows stale numbers as current. On HTTP 429 it backs off (honours `Retry-After`, otherwise 10 → 20 → 40 → 60 min).
- Hides during full-screen games/videos/presentations; restarts itself if Explorer restarts.

## Requirements

- Windows 11
- Claude Code signed in with a Claude subscription (Pro/Max/Team/Enterprise). The widget reads the OAuth token from `%USERPROFILE%\.claude\.credentials.json` **read-only** — it never writes or refreshes it. Claude Code keeps the token current; the widget re-reads it on every poll.

## Run

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File .\ClaudeUsageWidget.ps1
```

Then right-click the widget → **Start with Windows** to launch it at sign-in (adds `HKCU\...\CurrentVersion\Run\ClaudeUsageWidget`).

## Files and settings

| What | Where |
|------|-------|
| Settings | `HKCU\Software\ClaudeUsageWidget` |
| Log (no secrets) | `%LOCALAPPDATA%\ClaudeUsageWidget\widget.log` |

## Uninstall

Untick **Start with Windows**, choose **Exit**, delete the script, and optionally remove `HKCU\Software\ClaudeUsageWidget` and `%LOCALAPPDATA%\ClaudeUsageWidget`.

## Notes

- Uses `https://api.anthropic.com/api/oauth/usage`, the endpoint behind Claude Code's `/usage`. It's undocumented and may change.
- The widget is a transparent window owned by the taskbar (so it always stays above it) rather than a true child of it. Its position is fixed to the left of the tray, so with many pinned apps it can overlap the last icons.
