# OVERRIDE v2 — v1's design + subjects, with no idle CPU

A clean rebuild: **v1's exact quiz** (matrix rain, fake "script error" pranks, glitch, and all
five subjects — arithmetic, derivatives, vectors, matrices, capitals) driven the **no‑CPU** way.

## How it works
- **Alarms = Windows Scheduled Tasks** (wake‑from‑sleep). Between alarms **nothing runs → 0% CPU**.
  No watchdog/respawn cascade (that was v1's CPU/crash problem, not the quiz).
- At fire time, one ephemeral **ring engine** (`override.ps1 -Ring`) runs the alarm:
  - launches **`wake_quiz.hta`** (v1's quiz, all 5 subjects, per‑alarm settings),
  - **escalating sound**, **un‑mutable volume** (re‑asserts 100% + unmute ~5×/sec),
  - **keyboard lockdown** — swallows Win / Alt+Tab / Ctrl+Esc / Ctrl+Shift+Esc / **Alt+F4**,
    closes Task Manager on sight, and **pins the quiz full‑screen on top**,
  - **relaunches the quiz if you close it**, until you solve it or the per‑alarm **duration** runs out,
  - releases everything on solve/timeout (try/finally + a `-Unlock` safety task at alarm+6min).

## Control panel (the desktop OVERRIDE icon)
Opens **maximized / full‑screen**, resizable, matrix‑rain background. Each alarm is fully
independent — its own **time, label, date, difficulty, # questions, subjects, duration, volume‑lock**:
- **Blank date → next occurrence** (today if the time is still ahead, else tomorrow).
- **Rhythm** checkbox → rings **every day** at that time.
- A specific **date** → one‑time on that day.
- Buttons: **TEST RING** (preview the editor's settings), **SAVE & ARM**, **DISARM ALL**.

Closing the panel doesn't disarm anything — the alarms fire via Windows regardless.

## Files
- `override.ps1` — engine (`-Ring`), scheduler (`-Arm`/`-Disarm`), control panel (default), `-Unlock`.
- `wake_quiz.hta` — v1's quiz (borderless/full‑screen), reads per‑alarm settings from `session.quizcfg`.
- `config.json` — `defaults` + per‑alarm `alarms[]`.
- `install.ps1` — makes the icon + desktop shortcut. `make_icon.ps1`, `override.bat`, `sounds/`.

## config.json (per‑alarm)
```json
{ "version": 3,
  "defaults": { "difficulty":"hard","numQuestions":3,"durationMin":3,"lockVolume":true,
                "categories":{"arithmetic":true,"derivatives":false,"vectors":false,"matrices":false,"capitals":false} },
  "alarms": [
    { "id":"a1","label":"WAKE UP","time":"03:42","date":"","rhythm":false,"enabled":true,
      "difficulty":"hard","numQuestions":3,"durationMin":3,"lockVolume":true,
      "categories":{"arithmetic":true,"vectors":true} }
  ] }
```

## Honest limit (no admin)
Fully greying out Task Manager needs admin on a managed machine (the policy key is ACL‑locked and
Task Manager can run at an integrity a non‑admin process can't kill). The keyboard hook still blocks
the Ctrl+Shift+Esc hotkey; Ctrl+Alt+Del → Task Manager is the one escape no non‑admin app can block.
