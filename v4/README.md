# OVERRIDE v4 — the themed edition

v3's engine + a design system. You chose it, the gallery in `design_options/` shows it:
**4 themes + roulette**, all effects on, Edge-kiosk renderer with mshta fallback.

## What's new vs v3
- **Theme menu (per alarm)**: `green` phosphor classic · `red` alert/containment ·
  `cyber` neon cyan/magenta · `crt` deep CRT-monitor simulation (curvature, scanlines,
  RGB fringe) · `roulette` = a random theme every time it rings.
- **Effects**: theme-coloured matrix rain (per-alarm toggle), RGB-split glitch burst +
  red screen flash on wrong answers, the **chinese-vanish on solve** (the quiz dissolves
  into CJK glyphs before ACCESS GRANTED), decrypt-reveal + shake kept from v3.
- **Cinematic victory**: panel dissolves → ACCESS GRANTED glitches in → the champion
  quote *types itself* and is spoken aloud → `[ STATUS: DAY — WON ]`.
- **Renderer**: Edge kiosk (GPU-composited, modern CSS) in a private profile
  (`%TEMP%\override_v4_profile`) — your real browser is never touched; cleanup kills
  only that profile. SOLVED/heartbeat arrive on a localhost TcpListener (no admin
  needed). If Edge is missing/fails → automatic mshta fallback (`quiz.hta`, v3-style).
- Keyboard hook additionally blocks **Ctrl+W / Ctrl+F4** (browser-kiosk close keys).

## Switch (when you choose)
```powershell
cd v4\windows ; .\install.ps1     # retargets the OVERRIDE desktop icon to v4
```
Open OVERRIDE → alarms import from v3 automatically → pick a theme → **TEST RING** →
**DEPLOY**. Deploying replaces `OVERRIDE_V3_*`/`V2_*` tasks (never `OVERRIDE_LIVE_*`);
the shared ring mutex keeps any overlap night collision-free. v3 stays on disk as rollback.

## Files
- `quiz/core.js` — generators (identical to v3, 14,400-question selftest) + themed UI
- `quiz/style.css` — all four themes, one file, no CSS variables (fallback-safe)
- `quiz/quiz.html` — primary shell (any browser, all platforms; config via URL)
- `quiz/quiz.hta` — fallback shell (mshta; session files; bug-museum #15/#16 compliant)
- `windows/override.ps1` — engine: ring/panel/arm, TCP unlock listener, kiosk launcher
- `design_options/` — the gallery you picked from + `REAL_quiz_theme_*.png` renders

Everything else (invariants, bug museum, test playbook) → `v3/MAINTENANCE.md` still applies.
