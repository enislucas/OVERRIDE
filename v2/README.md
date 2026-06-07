# OVERRIDE v2 — the alarm that can't snooze, can't crash

A rebuild of OVERRIDE focused on three promises:

1. **The alarms always fire** — even if no window is open, even from sleep.
2. **~0 CPU when idle** — nothing runs between alarms.
3. **No crashes** — the runaway respawn loop from v1 is gone.

## How it works

- Each alarm is **one Windows Scheduled Task** (`OVERRIDE_V2_<id>`, wake-from-sleep
  capable). At the alarm minute the OS launches `override.ps1 -Ring` and **nothing
  runs the rest of the time** — that's the 0% idle CPU.
- A ring is **one short-lived process**: a full-screen, **unclosable** math gate that
  rings the escalating sounds and **locks the volume at 100%** (re-asserted every ~3s,
  not 10×/sec like v1). Solve the 3 hard arithmetic problems and it stops; ignore it
  and it **gives up after 3 minutes** — no snooze, no 40-minute nagging.
- **No watchdog, no respawn, no mutual-guard loop.** A single mutex means there is
  never more than one ring, and each task has a hard **5-minute** execution cap.

> Trade-off vs v1: the ring resists casual closing (no X, ignores Alt+F4, stays on top),
> but Task Manager → End Task can still kill it. That's the price of never crashing —
> and exactly what you asked for.

## Use

- **Double-click the `OVERRIDE` icon on your desktop** → a small status panel showing the
  armed alarms and next fire times. You can close it freely; the alarms stay armed.
- `override.bat test` — preview the ring now (Esc closes it in test mode).
- `override.bat arm` — re-arm after editing `config.json`.
- `override.bat disarm` — remove all alarms.

## Files
- `override.ps1` — everything: ring window, scheduler (arm/disarm), control panel.
- `override.bat` — launcher (this is what the desktop icon runs).
- `install.ps1` — makes the icon, the desktop shortcut, and arms the alarms.
- `make_icon.ps1` — regenerates `override.ico`.
- `config.json` — your alarms and settings.
- `sounds/` — the rotating WAV clips (shared design with v1).

## config.json
```json
{
  "numQuestions": 3, "difficulty": "hard", "lockVolume": true, "answerWindowSec": 180,
  "categories": { "arithmetic": true },
  "alarms": [ { "id": "a1", "label": "WAKE UP", "time": "03:30", "date": "2026-06-07", "enabled": true } ]
}
```
`date` optional: blank = daily, `YYYY-MM-DD` = one-time. Past one-time alarms are skipped.
