# OVERRIDE v9 — iPhone wake alarm (PWA)

v9 is the **iPhone build** of the OVERRIDE quiz-gated alarm — the same foreground
Home-Screen PWA as v7 (iPad), made **responsive for a phone screen** with
**iPhone-specific setup** (the side mute switch). Built for an **iPhone 11 on
iOS 26**. Live at **https://enislucas.github.io/OVERRIDE/v9/web/**.

> Architecture is shared with v7 — see `v7/web/README.md` for the full design
> (clock-poll scheduler, dual audio engine + watchdog, screen wake lock, and the
> `core.js init()` per-ring reset). The in-app checklist on the setup screen has
> the exact, device-correct steps.

### What's different from v7 (iPad)
- **Responsive** phone layout (`phone.css`) — the quiz panel/inputs reflow for a narrow screen.
- **iPhone mute switch:** flip the side switch to **RING**. `audioSession='playback'`
  already routes to the media channel (audible even on silent), but ring + volume-up
  is the belt-and-suspenders the in-app steps call for.
- Otherwise identical to v7's iOS audio handling (audioSession primer, silent `<audio>`
  fallback, wake lock). No vibration (iOS Safari has no web vibration API).

## How it works
- **Leave-it-open foreground PWA.** A web page cannot run a real *background*
  alarm on iOS, so the page stays **open + foreground + screen-on** all night.
  It keeps the screen awake (Screen Wake Lock) and you set Auto-Lock = Never.
- **Clock-poll scheduler.** It compares the wall clock to the target every
  250 ms (not one long `setTimeout`), so it's immune to timer drift/throttle.
- **Sound that survives mute.** Web Audio with `navigator.audioSession.type =
  'playback'` routes to the **media channel**, which Control-Center mute *and*
  Focus/DND do **not** silence (WebKit, reliable iPadOS 17+). A silent `<audio>`
  loop is the iPadOS-16 fallback. A **second, independent loud `<audio>` loop**
  (`alarm.wav`) plays in parallel as a backstop, and a **watchdog** rebuilds the
  AudioContext if iOS freezes/interrupts it overnight.
- **Quiz handoff.** At fire time it calls `OVERRIDE_UI.init(...)` (the shared
  engine) with `unlock: onSolved`. The engine calls `unlock()` the instant the
  quiz is solved → both sound engines stop. Nothing else stops the sound:
  `deadlineMs: 0` means **no auto-end — you must solve it.**
- **"Inescapable" (soft).** Fullscreen, re-asserts the sound on every
  visibility/focus/tap, warns on unload. See honest limits below.

## Honest limits (read these)
- **A website cannot truly lock an iPad.** No web API can block the home gesture,
  app switcher, Control Center, or power button. The alarm owns the whole window,
  stays loud, and is quiz-gated, but a determined user can leave it. It is
  "force yourself," not a kiosk lock.
- **It must stay foreground + screen-on + plugged in.** If you switch apps or the
  page is killed, the alarm can't sound.
- **JS can't raise the volume from zero.** You must set a non-zero volume and not
  be muted before sleeping.
- **Failsafe:** also set a normal **Clock-app alarm** at the same time. It's the
  only fully reliable iOS backstop (a web PWA can't guarantee background audio).

## Verified iOS facts baked in (research workflow, 2026-06)
- `audioSession.type='playback'` beats Control-Center mute + Focus (media channel).
- Screen Wake Lock: iPad Safari 16.4+; **installed PWA needs iPadOS 18.4+**. iOS
  releases the lock on every hide → re-acquired (ungated) on visibility-visible.
- A foreground, screen-on tab/PWA is **not** background-throttled; clock-poll is
  the correct pattern.
- AudioContext can go `interrupted`/"running but frozen" hours in and `resume()`
  may never recover → the watchdog **recreates** the context.

## Divergence from the shared engine
`v7/web/core.js` is a copy of the desktop `quiz/core.js` with **one change**: `init()`
resets the per-run flags (`finished/solved/wrongs`). The desktop spawns a fresh
process per ring; the iPad reuses the same page across daily rings, so without the
reset a repeating alarm's 2nd firing would be unsilenceable (`finished===true`
makes `check()` early-return). The generators are untouched (selftest unaffected).

## Setup on the iPad (one time)
1. Open the page in Safari → Share → **Add to Home Screen**, open it from the icon.
2. **Volume up**, iPad **not muted** (Control Center).
3. Settings → Display & Brightness → **Auto-Lock = Never**.
4. **Plug in**, **Low Power Mode OFF**.
5. Set the time, tap **ARM**, leave it open.
6. **Failsafe:** set a Clock-app alarm at the same time too.

Use **TEST SOUND (5s)** and **TEST FULL ALARM (~1s)** on the setup screen to
confirm sound + quiz before trusting it overnight.

## Files
```
v7/web/index.html   PWA shell (loads engine + app)
v7/web/app.js       alarm brain: scheduler, audio, wake lock, "inescapable", quiz handoff
v7/web/core.js      shared quiz engine (verbatim + the init() reset above)
v7/web/style.css    themed quiz stylesheet (verbatim from desktop)
v7/web/alarm.css    setup/armed screen styles
v7/web/manifest.webmanifest, sw.js   installable + offline
v7/web/alarm.wav    loud backstop tone   ·   silence.wav   audio-session primer
v7/web/icons/, apple-touch-icon.png    app icons
```

## Hosting
Served via **GitHub Pages** off the `v7` branch (root). URL:
`https://enislucas.github.io/OVERRIDE/v7/web/index.html`. HTTPS is required for
Wake Lock / audioSession / service worker — Pages provides it. Offline-capable
after first load (service worker), so no 4 AM network dependency.
