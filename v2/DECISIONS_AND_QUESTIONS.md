# Decisions I inferred while you slept + questions to confirm on wake

You told me to infer answers, log them, and fire an AskUserQuestion when you wake so you can
edit if needed. Here's everything I decided autonomously and why.

## Confirmed earlier by you
- Control panel = **themed GUI window** (matrix-rain styled, interactive alarm CRUD).
- Anti-kill = **maximum lockdown** (keyboard hook + Task Manager disabled, auto-released).

## Inferred decisions (my best judgment — flag any you dislike)
1. **Tonight's 3 alarms run the SAFE frozen ring, not the new lockdown ring.**
   Why: the max-lockdown feature is brand-new; firing an untested keyboard/Task-Manager lock on a
   sleeping person who can't recover is an unacceptable risk. Tonight = proven `override_stable.ps1`.
   The new vibrant+lockdown app becomes the default for alarms you arm **while awake**.
2. **Lockdown applies only to REAL alarms, never to TEST previews.** Test always has an Esc hatch
   and never disables Task Manager — so you can't trap yourself while trying it out.
3. **Animation is fps-capped (~12fps), double-buffered, and pauses when the panel is unfocused.**
   Why: your hard requirement that fans never spin. Ring animation only runs during the ≤3-min ring.
4. **Lockdown auto-release has 3 independent safety nets** (try/finally, a +6-min `-Unlock` task,
   panel self-heal) so a force-kill can't leave Task Manager disabled.
5. **Keyboard hook blocks** Win, Alt+Tab, Ctrl+Esc, Alt+Esc, Ctrl+Shift+Esc. It does NOT block
   normal typing (you need to type answers) and CANNOT block Ctrl+Alt+Del (OS secure screen) — no
   user-mode app can; that's the one honest gap.
6. **v3 ideas are only logged**, in `v3/ideas/ideas.md`, not built.

## Questions queued for AskUserQuestion when you wake
- Make the new vibrant + max-lockdown app the default for alarms you arm going forward? (I assumed yes.)
- Keep tonight's behavior (safe ring, no lockdown) as the right call? (I assumed yes.)
- Which v3 idea should I prototype first, if any?

## Persistence note
Tonight's alarms are persistent OS scheduled tasks (`OVERRIDE_LIVE_*`) — they survive reboots and
any session loss. This file + PROGRESS.md let any future session resume safely.
