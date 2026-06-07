# OVERRIDE — the alarm you can't snooze your way out of

Two versions live here:

- **[v2/](v2/) — current.** Alarms fire via Windows Scheduled Tasks (wake-from-sleep
  capable), each opening a short-lived, unclosable 3-minute math gate. **~0 CPU when
  idle, no watchdog/respawn, no crashes.** Start here → [v2/README.md](v2/README.md).
- **[v1/](v1/) — archived.** The original "unkillable" build (engine + watchdog respawn
  each other, daily tasks, HTA control panel). Still works, but the mutual-respawn loop
  could pile up processes and crash a machine. Kept for reference.

Quick start (v2): run `v2\install.ps1` once (makes the desktop **OVERRIDE** icon and arms
your alarms), or just double-click the desktop icon to see status / re-arm.
