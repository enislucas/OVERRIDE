# OVERRIDE v3 — the alarm you cannot snooze your way out of

Cross-platform rebuild: one shared quiz (12 subjects, narrator, pranks), three thin
platform engines. **0% CPU between alarms** on every OS — alarms are native scheduler
entries (Scheduled Tasks / launchd / systemd), and a single ephemeral "ring" process
exists only while an alarm is actually ringing.

## What's new vs v2
- **12 subjects** (each alarm picks its own mix): arithmetic, derivatives, vectors,
  matrices, capitals, **equations, percentages, powers & roots, sequences, integrals,
  binary/hex, chemistry elements** — all auto-generated, all difficulties.
- **New quiz experience**: one question at a time, instant feedback, progress bar,
  live countdown clock, decrypt-style question reveal, shake-on-wrong — and the same
  beloved fake "script error" pranks, now 18 of them. The ending is unchanged and sacred:
  *"Alarm disabled. You beat the machine. Now go win the day, champion."* — now spoken aloud.
- **Narrator**: random system voice per line; speaks at alarm start, nags you while you
  stall, taunts wrong answers, and delivers the champion quote at the end. Per-alarm toggle.
- **Lite by default = no lag**: ambient visuals are pure CSS (vignette + scanlines + glow,
  ~0 CPU). The matrix rain is opt-in (`matrixRain` in config). Measured: quiz ≈0.1s CPU
  over 4s; whole ring ≈0.5s CPU over 8s.
- **Never silent, never crashed by config**: a corrupt/missing `config.json` falls back to
  built-in defaults (+ auto `.bak` restore); missing sound files trigger a synthesized
  fallback wav. The alarm fires no matter what.
- **Harder to escape (Windows)**: keyboard hook swallows Win, Alt+Tab, Alt+F4, Alt+Esc,
  Ctrl+Esc, Ctrl+Shift+Esc **and Alt+Space**; Task Manager is killed on sight; the quiz
  relaunches instantly if closed, until you solve it or the per-alarm duration expires.
  (`Ctrl+Alt+Del` remains the one OS-reserved escape for a non-admin process — documented,
  not hidden.)

## Quick start (Windows)
```powershell
cd v3\windows
.\install.ps1        # icon + sounds + desktop "OVERRIDE" shortcut
```
Open the OVERRIDE shortcut → the control panel. First run imports your v2 alarms
automatically. Set time/subjects/difficulty per alarm → **DEPLOY**.

> Deploying from v3 replaces the old `OVERRIDE_V2_*` scheduled tasks (same alarms, new
> engine). v2 stays on disk; reopen v2's panel and deploy there to roll back.

## Quick start (macOS / Linux) — *written, not yet field-tested*
```bash
cd v3/unix
./override.sh test       # supervised test ring: browser quiz + sound + narrator
./override.sh arm        # arm every enabled alarm in ../config.json
./override.sh list
./override.sh wake-help  # how to wake the machine from real sleep (needs sudo once)
```
Requires `bash` + `python3`. The quiz opens in Chrome/Chromium/Firefox kiosk mode and
reports SOLVED to the ring via a localhost listener. Honest platform limits: no keyboard
lockdown (the ring relaunches the quiz instead), and waking from deep sleep needs
`pmset`/`rtcwake` (see `wake-help`).

## Layout
```
v3/
  quiz/core.js       shared logic: generators, narrator lines, pranks, UI (ES5 — runs everywhere)
  quiz/quiz.hta      Windows shell (mshta + SAPI voices + file-based unlock)
  quiz/quiz.html     macOS/Linux shell (browser + speechSynthesis + localhost unlock)
  quiz/style.css     shared stylesheet (IE11-safe, ambient effects are static = free)
  quiz/selftest.js   cscript harness — 14,400 generated questions verified per run
  windows/           override.ps1 (ring/panel/arm), install.ps1, make_sounds.ps1
  unix/override.sh   macOS launchd + Linux systemd engine
  config.json        created on first panel run (v4 schema); .bak kept automatically
```

## config.json (v4)
```json
{ "version": 4,
  "defaults": { "difficulty":"hard", "numQuestions":3, "durationMin":3,
                "lockVolume":true, "narrator":true, "matrixRain":false,
                "categories": { "arithmetic":true, "...11 more...":false } },
  "alarms": [ { "id":"a1","label":"WAKE UP","time":"04:15","date":"","rhythm":true,
                "enabled":true, "...same fields override defaults..." : {} } ] }
```
Blank date → next occurrence (baked to a concrete date on save). `rhythm` → every day
(and clears any date). Every field is per-alarm; defaults fill the gaps.

## Testing without waking the house
`quiz/selftest.js` (cscript) verifies all generators. The ring honors
`session.testcfg` with `{"quiet":true,"durationSec":20}` → no sound, no voice, no
volume grab. See `MAINTENANCE.md` for the full test playbook and the bug museum.
