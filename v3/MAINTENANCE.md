# OVERRIDE v3 — maintainer's guide

Written so any future maintainer (human or model) can work on this app **without any
context beyond this file**. Read this before changing anything.

## The four invariants (break these and the app has failed its one job)

1. **The alarm must fire.** Nothing in the config, filesystem, or quiz may be able to
   prevent the ring. That is why `Load-Config` falls back to defaults + `.bak`, why a
   missing quiz file still leaves the sound ringing, and why a missing `sounds/` dir
   synthesizes a fallback wav. Never add a hard dependency to the ring path.
2. **0 CPU between alarms.** No daemons, no watchdogs, no polling processes. Alarms are
   OS scheduler entries; the ring is ephemeral. (v1 died because a watchdog/respawn
   cascade ate the machine — see bug museum #1.)
3. **Never manhandle windows.** The quiz gets ONE gentle `SetWindowPos` topmost +
   one soft `SetForegroundWindow` when it appears, then a periodic z-order nudge with
   `SWP_NOACTIVATE|SWP_NOMOVE|SWP_NOSIZE`. No resize, no `AttachThreadInput`, no focus
   retry loops (bug museum #5/#6 — these black-screened/froze the PC).
4. **Lockdown always releases.** Every exit path runs `Invoke-Unlock` (try/finally), a
   `OVERRIDE_V3_safe_*` task fires `-Unlock` at alarm+6min, and the panel self-heals
   `DisableTaskMgr` on open when no ring is active. The low-level hook dies with its
   process by design.

## Architecture (1 minute)

```
scheduler entry (Task Scheduler / launchd / systemd timer)
   └─> ring process (windows/override.ps1 -Ring  |  unix/override.sh ring <id>)
         ├─ writes session.key/.label/.quizcfg/.deadlinems, heartbeats session.beat
         ├─ sound loop (escalating tiers t1_/t2_/t3_ wavs) + volume re-assert (200ms)
         ├─ narrator (random voice; start line + nags every ~22s)
         ├─ launches the quiz UI, relaunches it if closed (real alarms only)
         └─ ends on: UNLOCK file containing session.key | deadline | PANIC file
quiz (quiz/quiz.hta on Windows, quiz/quiz.html in a browser kiosk elsewhere)
   ├─ all logic in quiz/core.js (OVERRIDE_CORE = pure logic, OVERRIDE_UI = screen)
   ├─ HTA: reads session files via FSO, writes UNLOCK via FSO, speaks via SAPI
   └─ html: config via query string, UNLOCK/heartbeat via image beacons to the
            ring's python3 localhost listener (port 8741)
```

Session files live in the **v3 root** (`quiz.hta` computes `parent(dir(self))`).
`UNLOCK` must contain the exact key from `session.key` — prevents a stale quiz from a
previous ring solving a new one. `PANIC` (create the file by hand) ends any ring: the
documented human escape hatch.

### Task namespaces (Windows)
| namespace | meaning |
|---|---|
| `OVERRIDE_V3_<id>` / `OVERRIDE_V3_safe_<id>` | v3 alarm + its unlock safety net |
| `OVERRIDE_V2_*` | legacy v2 — **removed automatically when v3 deploys** (intentional: v3 replaces v2; mutex below makes the overlap night safe) |
| `OVERRIDE_LIVE_*` | historical frozen alarms — **NEVER touch, even though they no longer exist**; the deletion guard in `Remove-Alarms` must stay |

The ring mutex is **`Local\OVERRIDE_V2_ring_lock` on purpose** (same as v2): if both
v2 and v3 tasks exist for one night, only one ring can ever run.

## Bug museum — every real failure this project has had, and the guard that prevents it

| # | what happened | root cause | the guard (do not remove) |
|---|---|---|---|
| 1 | PC crashed, runaway CPU (v1) | watchdog respawn cascade | no watchdogs at all; mutex single-instance (`-Ring` exits if lock held) |
| 2 | quiz windows piled up | engine died, quizzes lived on | quiz watches `session.beat` heartbeat, self-closes when stale (>6s, 10s startup grace) |
| 3 | DEPLOY/TEST stacked stuck scheduler processes | repeated spawns, no guard | mutex + `MultipleInstances IgnoreNew` on tasks |
| 4 | alarms vanished after panel edits | edits not persisted | every panel mutation calls `Panel-Persist` (save + re-register) |
| 5 | PC froze during alarm | foreground-steal every 0.5s | invariant #3 |
| 6 | black screen over everything | fullscreen-resize + `AttachThreadInput` retry loop | invariant #3 |
| 7 | panel/system lag, fans, laptop crashes | unbounded matrix-rain render (IE canvas + GDI full-res) | rain opt-in (`matrixRain:false` default); GDI render capped at 900px wide, 8fps, double-buffered, paused on blur/minimize; quiz ambient is static CSS |
| 8 | volume creep-down audible | re-assert too slow (3s) | 200ms volume timer |
| 9 | alarm could be silent | `sounds/` missing → no audio | `Resolve-Sounds` falls back to v2/sounds, then synthesizes a wav (`FallbackSound`) |
| 10 | ring dies on corrupt config (latent, found in audit) | `ConvertFrom-Json` throw with `$ErrorActionPreference=Stop` | `Load-Config` try/catch → `.bak` → built-in defaults |
| 11 | stale past one-time alarms shown as ARMED (cosmetic) | counted Ready tasks with no next run | `Get-ArmedCount` requires future `NextRunTime`; rows show "(past)" |
| 12 | rhythm + leftover date = confusing config | editor kept both | rhythm checkbox clears + disables the date field; collect drops date when rhythm |
| 13 | non-exact percentage questions (caught by selftest before ship) | `Math.round` in generator | generators construct integer-exact questions; selftest re-computes answers independently |
| 14 | 75%-style answers off by one (same) | same | same |
| 15 | quiz rendered as a white serif titlebar'd window (real alarm) | mshta silently DROPS an external `<link rel=stylesheet>` AND re-parses the head, discarding the `HTA:APPLICATION` window settings | `quiz.hta` has NO `<link>`: it injects `style.css` from disk into an in-document `<style>` at boot (`injectCss`), plus a minimal inline black/green fallback so it's never white; `HTA:APPLICATION` is the literal first line. **Never re-add `<link>` to the HTA.** (Browsers/`quiz.html` are fine with `<link>`.) |
| 16 | panel dumped in the bottom-right corner | `position:absolute;top:50%;left:50%;transform:translate(-50%,-50%)` — IE11/mshta ignores `transform` | centre with `display:table`+`table-cell;vertical-align:middle` only; no transform/flex centring in the quiz CSS |

**Windows honest limit:** `Ctrl+Alt+Del → Task Manager` cannot be blocked by a non-admin
process, and on this (managed) machine the `DisableTaskMgr` policy key is ACL-locked.
The keyboard hook blocks the Ctrl+Shift+Esc hotkey; policy + Taskmgr-kill remain
best-effort. Full grey-out would require running elevated once. This is a Windows
security boundary, not a bug.

## Test playbook (safe on a busy machine)

```powershell
# 1. generators (no UI, ~2s):
cscript //nologo v3\quiz\selftest.js          # expect: ALL PASS (14,400 questions)

# 2. parse + dispatch (no UI):
powershell -NoProfile -File v3\windows\override.ps1 -Probe    # writes+leaves probe.ok
powershell -NoProfile -File v3\windows\override.ps1 -DryRun   # lists armed tasks

# 3. quiet end-to-end ring (quiz appears ~8s, NO sound/voice/volume-grab/lockdown):
'{"numQuestions":1,"difficulty":"easy","categories":{"arithmetic":true},"quiet":true,"durationSec":30}' |
  Set-Content v3\session.testcfg -Encoding Ascii
# launch:  powershell -NoProfile -ExecutionPolicy Bypass -Sta -WindowStyle Hidden `
#            -File "<abs>\v3\windows\override.ps1" -Ring -TestNow
# then read v3\session.key, write its value into v3\UNLOCK -> ring must end + clean up.
```
A loud supervised test: panel → TEST RING (uses the editor's settings, 45s).
macOS/Linux: `./override.sh test` — **first run must be supervised**; that engine is
syntax-checked but was authored on Windows.

## Performance budget (measured 2026-06-10)
- ring process: ~0.5s CPU over 8s incl. startup compile (steady-state ≈0.3%/core)
- quiz (lite): ~0.11s CPU over 4s, WS ≈44 MB
- between alarms: zero processes, zero CPU
Anything you add to a timer tick must stay O(small): ticks run at 500ms (ring),
200ms (volume), 1s (panel status/clock), 1.5s (quiz engine-watch).

## Where to extend
- **New subject:** add a generator in `core.js`, register in `GENS` + `CAT_KEYS`, add the
  key to `$script:CATS` in `windows/override.ps1` — panel checkboxes and config are
  generated from those lists. Then add a semantic check in `selftest.js` and run it.
- **New narrator lines / pranks:** `LINES` / `ERRS` in `core.js` (quiz side) and
  `$script:NAG_LINES` / `$script:START_LINES` in `override.ps1` (ring side).
  The victory line is load-bearing: keep *"…Now go win the day, champion."*
- **Phones (phase 2, discussed, not started):** Android is realistic without a store
  (sideload an APK, or Termux + termux-job-scheduler). iOS without paying Apple is not:
  a PWA cannot ring a real alarm from the background (iOS kills it; Web Push ≠ alarm,
  respects silent switch), AltStore sideloading needs re-signing every 7 days. Honest
  recommendation: keep phones as a companion (the quiz already runs in any mobile
  browser via `quiz.html`) and let the laptop stay the alarm.
