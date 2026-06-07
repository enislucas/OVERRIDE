# OVERRIDE — overnight rebuild progress / resume guide

_Working log so progress survives a usage-limit cutoff. If you're a fresh session, READ THIS FIRST._

## ⛔ CRITICAL — do not break tonight's alarms
Tonight's 3 alarms (2026-06-08, **03:30 / 03:42 / 04:25**) are armed as **protected** scheduled
tasks in their own namespace so the rebuild can't touch them:

- `OVERRIDE_LIVE_a1`, `OVERRIDE_LIVE_a2`, `OVERRIDE_LIVE_a3`
- Each runs: `override_stable.ps1 -Ring -AlarmId aX` (WakeToRun, 5-min cap, one-time).
- `override_stable.ps1` is a **frozen copy of the already-tested ring** — no keyboard
  lockdown, no animation. Deliberately the SAFE version for an unattended sleeping user.

**Rule:** never delete/modify `OVERRIDE_LIVE_*` or `override_stable.ps1` before they fire.
The rebuild uses the **`OVERRIDE_V2_*`** namespace only.

## Architecture (unchanged, good)
- Alarms = Windows Scheduled Tasks (wake-from-sleep) that launch an **ephemeral ring**
  process. **0 CPU between alarms** (nothing runs). No watchdog/respawn (that was v1's crash).
- A ring = one short-lived process: full-screen unclosable math gate, sound, volume lock,
  gives up after 3 min, then exits.

## Task namespaces
| name | purpose | who manages |
|---|---|---|
| `OVERRIDE_LIVE_*` | tonight's frozen alarms → `override_stable.ps1` | set manually, leave alone |
| `OVERRIDE_V2_*` | the new app's alarms → `override.ps1` | new control panel (arm/disarm) |
| `OVERRIDE_V2_safe_*` | lockdown auto-release at alarm+6min → `override.ps1 -Unlock` | new arm |
| `OVERRIDE_V2_probe` | transient test only (always removed) | tests |

## What the rebuild adds (in `override.ps1`)
1. **Vibrant ring**: matrix-rain backdrop + scanlines + glitch-on-wrong + green glow.
   Animation fps-capped + double-buffered → fan-safe (target < few % CPU; measured in tests).
2. **Maximum lockdown** during REAL alarms only (not test): low-level keyboard hook swallows
   Win / Alt+Tab / Ctrl+Esc / Alt+Esc / Ctrl+Shift+Esc, plus `DisableTaskMgr` (HKCU, no admin).
   - Auto-release layers: (a) try/finally on every exit, (b) `OVERRIDE_V2_safe_*` task at
     alarm+6min runs `-Unlock`, (c) control panel self-heals `DisableTaskMgr=0` on open when
     no ring is active. Hook dies automatically if the process is killed.
3. **Standalone themed GUI control panel** (the default when you open the app): add/edit/delete
   alarms, set difficulty/count, arm/disarm, test, live "next alarm" — user-controlled, not a
   log-for-the-assistant. Rain animation pauses when the window is unfocused/minimized.

## Decisions (see DECISIONS_AND_QUESTIONS.md) — confirmed by user
- Panel = themed GUI window. Lockdown = maximum.
- Inferred (to confirm on wake): tonight stays on the safe stable ring (no untested lockdown
  on a sleeping user); new vibrant+lockdown app becomes the default for alarms you arm awake.

## Status checklist
- [x] Tonight's alarms frozen on stable ring (`OVERRIDE_LIVE_*`)
- [x] Progress/idea/decision logs written
- [ ] New `override.ps1` (ring + lockdown + GUI panel) written
- [ ] install.ps1 / shortcut updated for clean GUI launch
- [ ] Syntax + headless construction tests
- [ ] Adversarial safety-review workflow
- [ ] Live stress tests (CPU%, relaunch, kill-during-ring recovery, arm/disarm)
- [ ] Re-verify `OVERRIDE_LIVE_*` intact; final report; AskUserQuestion queued for wake

## Resume instructions if cut off
1. Confirm `OVERRIDE_LIVE_*` tasks still exist and are Ready (`Get-ScheduledTask OVERRIDE_LIVE_*`).
2. Continue from the first unchecked box above.
3. Never point tonight's alarms at the new `override.ps1` until the user is awake to vet lockdown.
