# OVERRIDE

**The alarm you cannot snooze your way out of.** It rings until you solve a quiz —
math, capitals, chemistry, up to 50 questions, five themes — narrated by a machine
that does not respect your blanket.

## ➜ Everything lives in [`v10/`](v10/) — the universal version

| You have | Use |
|---|---|
| **Any phone / tablet / browser** | **https://enislucas.github.io/OVERRIDE/v10/web/** — one PWA; detects iPad / iPhone / Android / desktop and adapts. Multi-alarm, decreasing-sound, deep-sleep gate mode. |
| **Windows** | [`v10/windows/`](v10/windows/) — native engine: rings **even from Sleep** (0% CPU between alarms). Run `install.ps1`, open the desktop icon, DEPLOY. |
| **macOS / Linux** | [`v10/unix/`](v10/unix/) — best-effort engine + hardware-wake (`pmset`/`rtcwake`). **Supervised first run.** |

Docs: [`v10/README.md`](v10/README.md) · engineering history & bug museum: [`v10/MAINTENANCE.md`](v10/MAINTENANCE.md).

Older versions (v1–v9) were removed from the repo head; their full history is
preserved in git history and tags (`v10.1`, `v10.2`, `v4-stable`, `v5-stable`).
