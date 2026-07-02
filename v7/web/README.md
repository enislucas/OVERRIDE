# OVERRIDE web — quiz-gated wake alarm PWA (canonical app)

> **2026-07-02 overhaul:** the v7/v8/v9 folders now serve a **byte-identical app**.
> Platform (iPad / iPhone / Android) is detected at runtime; the version label comes
> from the URL path. **Multiple alarms** (each with its own time/label/daily-or-once/
> theme/difficulty/questions/subjects/decreasing-sound/rain); v6.7 engine (cap 50,
> soften curve 100→50→40→−4→20, themes 1890 + boring); per-version localStorage with
> migration; fixes for engine interval leaks across rings, the test-sound race, and
> the stuck victory screen. Edit ONE folder and copy to the others (hash-verify).
> Everything below describes the underlying single-alarm v7 design and still applies
> to the alarm/audio/wake-lock architecture.

# OVERRIDE v7 — iPad / web wake alarm (PWA)

v7 is the **iOS/web port**: the same OVERRIDE quiz-gated alarm, running as a
**Home-Screen PWA** on an iPad (built/verified for an **iPad Air 5**, current
iPadOS). It reuses the desktop quiz engine verbatim — all 12 subjects, the
narrator, the "champion" victory — and wraps it in a web alarm shell.

> The Windows app (v6) is unchanged and stays the desktop alarm. v7 is a
> separate platform line; it lives in `v7/web/` and is served as a website.

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
