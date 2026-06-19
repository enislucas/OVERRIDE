# OVERRIDE v6 — alarm reordering

**v6 started as an exact, frozen copy of v5** (the audited line: adaptive renderer + crash-safety
fixes + auto-burn, all verified working). v5 is the **rollback point** (tag `v5-stable`).
v6 adds one thing: **reordering alarms in the list.**

## What's new in v6
- **Move alarms up / down**: each alarm row has **▲ / ▼ buttons** that move it within the list.
  The top row's ▲ and the bottom row's ▼ are disabled (can't go further). Order persists to
  `config.json` and survives reopening. (Order is cosmetic — alarms always fire by their
  scheduled time regardless of list position; this just organizes the list the way you want.)
  Implemented as buttons rather than drag-and-drop because the row list is custom-painted and
  drag-tracking inside it is fragile; buttons can't mis-fire.

Everything else is inherited from v5 and documented in **`v6/MAINTENANCE.md`** (the living
maintainer doc — invariants + cumulative bug museum).

## Differences from v5 (so the two never collide)
- Task namespace `OVERRIDE_V6_*`; deploying v6 removes V5/V4/V3/V2 tasks (never `OVERRIDE_LIVE_*`).
- Edge profile `%TEMP%\override_v6_profile`; panel titled v6; imports alarms from v5 on first run.
- Shared ring mutex (unchanged) so v5 and v6 can never ring at the same time.

## Rolling back to v5 (if v6 ever misbehaves)
v5 is frozen and untouched (tag `v5-stable`, branch `v5`). To return to it:
```powershell
cd ..\v5\windows ; .\install.ps1     # repoints the OVERRIDE desktop icon to v5
```
then open the panel and DEPLOY (re-arms as `OVERRIDE_V5_*`, replacing v6).

## Status
Skeleton = identical behavior to v5 plus the reorder buttons (verified: parse-clean, selftest
ALL PASS, end-to-end reorder persists). Made live: desktop icon → v6, alarm armed on v6.
