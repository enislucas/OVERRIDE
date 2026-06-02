```
  ___ _   _ ___ ___ ___ ___ ___ ___
 | _ \ | | | __| _ \ _ \_ _|   \ __|
 |   / |_| | _||   /   /| || |) | _|
 |_|_\\___/|___|_|_\_|_\___|___/|___|   // WAKE PROTOCOL
```

# OVERRIDE — the alarm you can't snooze your way out of

A Windows wake-up alarm that forces you to **solve math to turn it off**, **locks your
volume at 100%** so muting does nothing, and **respawns itself** if you try to kill it.
Built for people who out-smart their own alarms.

> Honest note: if you are an administrator on your own PC you can *always* win eventually
> (Task Scheduler, kill the right processes, delete the folder). This isn't a prison —
> it's enough friction that your half-asleep self gives up and just does the math.

## Requirements
**None.** Pure Windows — PowerShell + .NET + HTA, all built in. No Python, no installs,
no admin needed. Works on Windows 10/11.

## Setup (30 seconds)
1. Put this folder anywhere (e.g. `Documents\OVERRIDE`).
2. Double-click **`OVERRIDE.hta`**.
3. Add your alarm times (24-hour, e.g. `06:30`), pick the **categories** (arithmetic,
   derivatives, vectors, matrices, capitals), how many questions, and how hard.
4. Click **DEPLOY**. Done — it now fires every day at those times.
5. (Optional) Click **TEST NOW (60s)** to see it work right away. Try to mute it. 🙂

## How to turn the alarm off when it goes off
**Solve the math** in the green window that pops up. That's the only clean way —
solving it instantly releases the volume lock and stops everything.

## Buttons
- **DEPLOY** — saves your settings and arms all enabled alarms (daily).
- **TEST NOW (60s)** — runs an alarm immediately for 1 minute as a preview.
- **STOP TEST** — emergency stop for a test/running alarm.
- **DISARM ALL** — removes every armed alarm.

## To uninstall
Open `OVERRIDE.hta` → **DISARM ALL**, then delete the folder.

## Tips
- Leave the PC **on or asleep** (not shut down) so it can wake for the alarm.
- It ships with 10 synthesized rage-sounds in `sounds/` that **randomly cycle** (so your
  brain never habituates) and **escalate** the longer you ignore them. Drop your own
  **`.wav`** files in `sounds/` and they join the rotation (use prefixes `t1_`/`t2_`/`t3_`
  to set their escalation tier). Run `make_sounds.ps1` to regenerate the built-in ones.
- The alarm rings in cycles: ~3 min on, 2 min off, repeating up to the "give up" minutes.
- For maximum effect, put the PC **across the room** — then you have to stand up to
  read the questions, which is the part no software can do for you.

## Files (for the curious)
- `OVERRIDE.hta` — control panel (this is the one you open)
- `wake_quiz.hta` — the math gate that appears when the alarm fires
- `engine.ps1` — plays the sound + locks the volume
- `watchdog.ps1` — respawns the engine if it's killed (and vice-versa)
- `arm.ps1` — creates/removes the scheduled tasks
- `make_sounds.ps1` — regenerates the synthesized sounds in `sounds/`
- `config.json` — your saved alarms and settings
- `sounds/` — the rotating alarm clips (WAV)

## How it works (for contributors)
- One alarm time = one **daily Windows Scheduled Task** that runs `engine.ps1`.
- `engine.ps1` plays a looping, escalating sound (`System.Media.SoundPlayer`), forces the
  volume to 100% via the Core Audio API, opens `wake_quiz.hta`, and writes a heartbeat file.
- `engine.ps1` and `watchdog.ps1` **guard each other** — kill one and the other relaunches
  it. Both stop the instant the quiz writes the session key to `UNLOCK`, the deadline passes,
  or a `PANIC` file appears.
- **The concurrency locks are intentional — please don't remove them.** `OVERRIDE.hta`
  ignores repeated DEPLOY/TEST clicks while one is in progress (the `OV_BUSY` flag), and
  `arm.ps1` takes a single-instance mutex (`Global\OVERRIDE_arm_lock`) and exits immediately
  if another copy is already running. Without these, rapidly re-triggering DEPLOY can spawn
  many concurrent scheduler runs that hang on the Windows Task Scheduler service and pile up
  (high RAM/CPU).
- Runtime files (`session.*`, `UNLOCK`, `PANIC`, `arm.log`) are created while an alarm runs
  and are git-ignored.

## License & disclaimer
MIT (see `LICENSE`). This is a fun, self-binding alarm — not a security product. On a PC
where you have admin rights you can always shut it off eventually; it's designed to add
*friction*, not to be unbreakable. Use at your own risk, and don't rely on it alone for
anything safety-critical.
