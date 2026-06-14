# OVERRIDE v5 — code-improvement line

**v5 started as an exact, frozen copy of v4** (the themed edition you verified working:
real alarm peaked at 442 MB Edge / 3.18 GB free / no relaunch-thrash / clean teardown).
v4 is the **rollback point** — see "Rolling back" below. All optimization work happens here.

## Goal (v5 scope)
Improve the code and fix the lag/problems the new (v4) design introduced, with CPU/RAM
efficiency as the headline — especially for a loaded machine (heavy Edge + several VS Code
+ Claude Code instances running). Planned, in priority order:
1. **Adaptive renderer** — pick the renderer by free RAM at ring time: Edge kiosk when there's
   headroom (best design fidelity), the far lighter **mshta** (~44 MB / 1 proc, still themed)
   when RAM is tight. Never risk a low-memory crash for visual polish.
2. **Code audit** — hunt the lag sources + latent bugs the v4 design added; trim Edge startup.
3. **Cleanup/dedup** of the engine without touching the proven ring invariants.

Everything else (architecture, 12 subjects, 4 themes, bug museum, invariants) lives in
**`v5/MAINTENANCE.md`** (the living maintainer doc — cumulative bug museum, now 19 entries).

## Differences from v4 (so the two never collide)
- Task namespace `OVERRIDE_V5_*`; deploying v5 removes V4/V3/V2 tasks (never `OVERRIDE_LIVE_*`).
- Edge profile `%TEMP%\override_v5_profile`; panel titled v5; imports alarms from v4 on first run.
- Shared ring mutex (unchanged) so v4 and v5 can never ring at the same time.

## Rolling back to v4 (if v5 ever misbehaves)
v4 is frozen and untouched. To return to it:
```powershell
cd ..\v4\windows ; .\install.ps1     # repoints the OVERRIDE desktop icon to v4
```
then open the panel and DEPLOY (re-arms as `OVERRIDE_V4_*`, replacing v5). Git: the exact
state is tagged **`v4-stable`** and lives on branch `v4`.

## Status
Skeleton = identical behavior to v4 (verified: parse-clean, selftest ALL PASS). The desktop
icon still points at **v4** — v5 is not armed and won't be until it's optimized + vetted.
