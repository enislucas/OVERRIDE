# OVERRIDE v10 — macOS / Linux engine

The quiz-gated wake alarm, for Mac and Linux. Same shared quiz as the Windows and web
builds (`../quiz/quiz.html`); same philosophy: **0% CPU between alarms** (alarms are
native scheduler entries), and one short-lived `ring` process only while an alarm is
actually going off.

> ## ⚠️ SUPERVISED FIRST RUN — READ THIS FIRST
> **This engine has been written and syntax-checked (`bash -n`) but NOT yet run on real
> Mac/Linux hardware.** Treat the first run as a supervised test while you are **awake and
> watching**, at a time that is not a real wake-up:
> ```bash
> cd v10/unix
> ./override.sh install     # chmod +x + report what it found
> ./override.sh test        # 45-second ring: browser quiz + sound + narrator
> ```
> Only after `test` behaves (sound plays, the quiz opens, solving it stops everything, and
> the volume is restored) should you `arm` it for a real morning. Keep the escape hatch in
> mind: **`touch ../PANIC`** from any terminal ends a ring immediately.

## Requirements
- **bash** and **python3** (python3 does all JSON parsing — `jq` is *not* used — and runs
  the localhost unlock/heartbeat listener). If python3 is missing the engine refuses to run
  and prints install hints.
- A browser for the kiosk quiz: **Chrome / Chromium** (best — true `--kiosk`), else it
  falls back to Safari/`xdg-open` in a normal window.
- Optional niceties, each probed with `command -v` and skipped if absent: `say`/`spd-say`/
  `espeak` (narrator), `afplay`/`paplay`/`aplay`/`ffplay` (sound), `osascript`/`pactl`/
  `amixer` (volume), `caffeinate` (keep the display awake on mac).

## Setup

### macOS
```bash
cd v10/unix
./override.sh install
./override.sh test          # supervised — do this first
./override.sh arm           # writes ~/Library/LaunchAgents/com.override.v10.<id>.plist per alarm
./override.sh status        # show alarms + which launchd agents are loaded
sudo ./wake.sh              # (optional) wake the Mac from sleep before each alarm — see below
```

### Linux
```bash
cd v10/unix
./override.sh install
./override.sh test          # supervised — do this first
./override.sh arm           # systemd --user timer per alarm, or a crontab line if no user-systemd
./override.sh status
sudo ./wake.sh              # (optional) hardware wake for the SOONEST alarm — see below
```
`arm` auto-detects: if `systemctl --user` works it writes `override-v10-<id>.timer` units;
otherwise it adds a `crontab` line tagged `# OVERRIDE_V10 <id>`. Either way `disarm` removes
exactly what `arm` added.

## config.json
Read from `../config.json` (this folder's parent, `v10/`) — the **same file and schema the
Windows panel writes**, so you can configure alarms on Windows and just `arm` here. It is
read BOM-tolerantly (PowerShell writes a UTF-8 BOM). Per alarm: `id, time ("HH:MM"), label,
rhythm` (daily), `date` (one-shot `YYYY-MM-DD`), `enabled, difficulty, numQuestions,
durationMin, narrator, matrixRain, theme, softenVolume, categories`; `defaults{}` fills any
gaps. A missing/corrupt config still lets `test` ring (built-in defaults); `arm` refuses
without a config so it never arms phantom alarms.

## How a ring works
A native timer runs `override.sh ring <id>` at the set time. That process:
1. starts a python3 listener on the first free port **8741–8749**, serving a real 1×1 GIF to
   the quiz's `/beat` heartbeat, writing `../UNLOCK` on `/unlock?key=<match>`, and recording
   the decreasing-sound target (`../session.vol`) on `/vol?level=N`;
2. loops the alarm sound (from `../sounds` or `../../v3/sounds`; a spoken klaxon if there are
   no `.wav`s) and speaks narrator start/nag lines;
3. opens `../quiz/quiz.html` in a Chrome/Chromium **kiosk with its own `--user-data-dir`** so
   your real browser profile is never touched;
4. ends when you **solve the quiz** (correct unlock key) **or** the **`durationMin` deadline**
   passes **or** a **`../PANIC`** file appears;
5. on exit (always, via a trap) it kills only its own kiosk + sound, restores the system
   volume to what it was (or a sane 70%), and deletes its session files.

**Soften / decreasing-sound:** with `softenVolume` on, the quiz beacons a lower target after
each correct answer; the ring reads `session.vol` and lowers system volume toward it, then
**restores volume on exit**. With it off, the ring keeps volume at max so the alarm stays loud.

## Deep-sleep wake (`./wake.sh`) — how it works and its limits
Timers fire fine when the machine is awake or only the **display** is asleep (lid open,
plugged in). To wake from **real sleep** you must program the hardware, which needs `sudo`
once. `./wake.sh` reads `../config.json` and schedules a wake a few minutes before each
enabled alarm:

- **macOS** — `sudo pmset schedule wake "MM/dd/yy HH:mm:ss"` (one-shot per alarm). For daily
  use prefer `./wake.sh repeat`, which sets `pmset repeat wakeorpoweron MTWRFSU HH:MM:SS` at
  the earliest daily alarm — it is idempotent **and can power the Mac on from a full
  shutdown**. `./wake.sh cancel` clears both. Only ONE `repeat` schedule can exist, so it
  covers the earliest daily time; later same-day alarms rely on the machine staying awake.
- **Linux** — `sudo rtcwake -m no -t <epoch>`. The RTC holds a **single** alarm and `rtcwake`
  **overwrites** any earlier one, so this schedules **only the soonest** alarm; re-run after
  it fires to arm the next. `./wake.sh cancel` clears the RTC alarm. RTC local-vs-UTC config
  can shift the time — if a wake is an hour off, that's the usual cause.

**Hard limits (honest):**
- **Hibernate / powered-off cannot be woken** — *except* macOS `wakeorpoweron`. Linux
  `rtcwake -m no` cannot power a fully-off machine on (that's firmware "wake on RTC").
- **No keyboard lockdown.** An unprivileged process can't block Cmd-Tab, the app switcher, or
  the power button. The ring is loud, fullscreen, and quiz-gated, but a determined person can
  leave it — it's "force yourself", not a true kiosk lock.
- `wake.sh` needs `sudo` and is safe to re-run (`repeat`/`rtcwake` overwrite in place; the
  mac one-shot `schedule` appends harmless same-time events — use `cancel` to clear).

## Rollback
```bash
./override.sh disarm     # removes every launchd agent / systemd timer / crontab line it added
./wake.sh cancel         # removes the hardware wake schedule (sudo)
```
`disarm` is the full rollback for alarms; `wake.sh cancel` undoes the deep-sleep wake. Nothing
outside this project directory is ever deleted.

## Files
```
v10/unix/override.sh   the engine: test / ring <id> / arm / disarm / status / install
v10/unix/wake.sh       deep-sleep hardware wake helper (sudo): schedule / repeat / cancel
v10/unix/README.md     this file
v10/config.json        shared alarm config (written by the Windows panel; BOM-tolerant read)
v10/quiz/quiz.html     the shared browser quiz opened at ring time
```
See `../MAINTENANCE.md` for the cross-platform architecture and bug museum.
