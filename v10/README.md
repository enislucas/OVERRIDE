# OVERRIDE v10 — the universal version

One version, every device. Merges v6 (Windows) + v7/v8/v9 (iPad/iPhone/Android web)
into a single folder with **one shared quiz engine** (`quiz/core.js` = `web/core.js`,
hash-identical).

| Piece | Runs on | How |
|---|---|---|
| `windows/` | Windows | native engine: Scheduled Tasks, **rings even from Sleep** (WakeToRun), Edge-kiosk/mshta quiz, volume lock + decreasing-sound, lockdown. The strongest option. |
| `web/` | iPad · iPhone · Android · any desktop browser | one PWA at `…/OVERRIDE/v10/web/` — platform detected at runtime (checklists adapt), multi-alarm, leave-open foreground. |
| `unix/` | macOS · Linux | best-effort native engine (launchd/systemd + pmset/rtcwake deep-sleep wake). **Supervised first run required** — see `unix/README.md`. |

**v10.1** = the universal merge (archived as tag `v10.1`).
**v10.2** = deep-sleep additions: laptop-asleep wake (Windows native ✓, Mac/Linux via
`unix/wake.sh`) and closed-phone gating: a **native Clock alarm wakes you** (works
locked — physics: no web page can ring a closed phone), and a Shortcuts/Routines
automation auto-opens `…/v10/web/?gate=1`, which forces the quiz on-screen
immediately (first tap enables the siren + nags until solved). Setup steps live in
the app's **DEEP SLEEP** card.

Rollback: Windows → `cd ..\v6\windows; .\install.ps1` then DEPLOY (re-arms V6).
Web → the old v7/v8/v9 URLs still serve the previous build. History: `MAINTENANCE.md`.
