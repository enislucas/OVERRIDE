/* OVERRIDE // web wake-alarm shell (canonical — IDENTICAL file in v7/v8/v9 folders).
   ---------------------------------------------------------------------------
   Wraps the shared quiz engine (core.js -> OVERRIDE_UI) in a leave-it-open
   foreground PWA alarm. Platform (iPad / iPhone / Android) is detected at
   RUNTIME and the app version is derived from the URL path, so the three
   deployments never drift again.

   v10-web overhaul (2026-07-02): MULTIPLE ALARMS (each with its own time,
   label, repeat, theme, difficulty, question count, subjects, decreasing-sound,
   rain), the v6.7 engine (cap 50, curve 100->50->40->-4->20, themes 1890 +
   boring), per-version localStorage, and fixes: engine interval leaks across
   rings, test-sound race vs a live ring, victory screen returning to the
   countdown, per-ring quiz state reset.

   Platform truths (researched + field-tested):
   - iOS/Android suspend a backgrounded/locked page's JS -> screen must stay ON
     (Wake Lock + Auto-Lock Never) and the app foreground. Clock-poll scheduler.
   - audioSession 'playback' routes to the media channel (audible through
     iOS mute/Focus); silent <audio> loop is the iOS-16 fallback; a second loud
     <audio> loop + a watchdog that rebuilds a frozen AudioContext.
   - We CANNOT block the home gesture/app switcher/power button. Keep a native
     Clock alarm as failsafe.
   --------------------------------------------------------------------------- */
(function () {
  'use strict';
  var C = OVERRIDE_CORE;
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function qs(name) { var m = location.search.match(new RegExp('[?&]' + name + '=([^&]*)')); return m ? decodeURIComponent(m[1]) : ''; }

  /* ------------------------ platform + version ------------------------ */
  var APPV = (function () {
    var m = location.pathname.match(/\/(v\d+)\//); return m ? m[1] : 'v7';
  })();
  var PLAT = (function () {
    // v10 UNIVERSAL: desktop browsers must NOT read as phones (desktop Chrome HAS navigator.vibrate,
    // so detect Android by UA). iPadOS 13+ masquerades as Macintosh but has touch points.
    try {
      var ua = navigator.userAgent || '';
      if (/iPad/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)) return 'ipad';
      if (/iPhone|iPod/.test(ua)) return 'iphone';
      if (/Android/.test(ua)) return 'android';
      return 'desktop';                             // Windows / Mac / Linux browser
    } catch (e) { return 'desktop'; }
  })();
  var PNAME = { android: 'Android', ipad: 'iPad', iphone: 'iPhone', desktop: 'Desktop' }[PLAT];

  /* ----------------------------- settings ----------------------------- */
  var LS = 'override_web_cfg_' + APPV;
  var OLD_LS = 'override_v7_cfg';                     // pre-overhaul single-alarm config
  var SUBJECTS = C.CAT_KEYS;                          // stays in sync with the engine
  function newAlarm() {
    return {
      id: 'a' + Math.random().toString(36).slice(2, 8),
      time: '07:00', label: 'WAKE UP', enabled: true, repeat: true,
      theme: 'red', difficulty: 'hard', numQuestions: 3,
      soften: false, matrixRain: true, cats: { arithmetic: true }
    };
  }
  function loadCfg() {
    try {
      var s = JSON.parse(localStorage.getItem(LS));
      if (s && s.alarms && s.alarms.length) return s;
    } catch (e) {}
    // migrate the old single-alarm config if present
    try {
      var o = JSON.parse(localStorage.getItem(OLD_LS));
      if (o && o.time) {
        var a = newAlarm();
        a.time = o.time; a.theme = o.theme || a.theme;
        a.difficulty = o.difficulty || a.difficulty;
        a.numQuestions = o.numQuestions || a.numQuestions;
        a.repeat = (o.repeat !== false); a.matrixRain = (o.matrixRain !== false);
        if (o.cats) a.cats = o.cats;
        return { alarms: [a] };
      }
    } catch (e2) {}
    return { alarms: [newAlarm()] };
  }
  function saveCfg() { try { localStorage.setItem(LS, JSON.stringify(cfg)); } catch (e) {} }
  var cfg = loadCfg();

  /* --------------------------- diagnostics ---------------------------- */
  var DLOG = 'override_web_diag_' + APPV;
  function dlog(m) {
    try {
      var a = JSON.parse(localStorage.getItem(DLOG) || '[]');
      a.push({ t: Date.now(), m: m });
      if (a.length > 300) a = a.slice(a.length - 300);
      localStorage.setItem(DLOG, JSON.stringify(a));
    } catch (e) {}
  }
  function dlogText() {
    try {
      var a = JSON.parse(localStorage.getItem(DLOG) || '[]');
      if (!a.length) return '(empty - arm the alarm or run a test, then check back)';
      return a.map(function (x) {
        var d = new Date(x.t); function p(n) { return (n < 10 ? '0' : '') + n; }
        return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds()) + '  ' + x.m;
      }).join('\n');
    } catch (e) { return '(log unreadable)'; }
  }
  function showDiag() {
    var ov = document.createElement('div');
    ov.style.cssText = 'position:fixed;inset:0;z-index:99999;background:rgba(0,0,0,0.94);padding:14px;box-sizing:border-box;display:flex;flex-direction:column';
    var h = document.createElement('div'); h.textContent = 'OVERRIDE diagnostics (' + APPV + '/' + PLAT + ') - screenshot this & send it';
    h.style.cssText = 'color:#ff8d94;font:13px Consolas,monospace;margin-bottom:8px';
    var ta = document.createElement('textarea'); ta.readOnly = true; ta.value = dlogText();
    ta.style.cssText = 'flex:1;width:100%;box-sizing:border-box;background:#140002;color:#9fe9c0;border:1px solid #7a1018;font:12px Consolas,monospace;white-space:pre;overflow:auto;padding:8px';
    var row = document.createElement('div'); row.style.cssText = 'display:flex;gap:8px;margin-top:8px';
    var cl = document.createElement('button'); cl.textContent = 'CLOSE'; cl.className = 'btn ghost'; cl.style.flex = '1';
    cl.addEventListener('click', function () { if (ov.parentNode) ov.parentNode.removeChild(ov); });
    var clr = document.createElement('button'); clr.textContent = 'CLEAR'; clr.className = 'btn ghost'; clr.style.flex = '1';
    clr.addEventListener('click', function () { try { localStorage.removeItem(DLOG); } catch (e) {} ta.value = dlogText(); });
    row.appendChild(cl); row.appendChild(clr);
    ov.appendChild(h); ov.appendChild(ta); ov.appendChild(row);
    document.body.appendChild(ov);
  }
  function beat() { return (Math.floor(Date.now() / 1000) % 2) ? '●' : '○'; }
  function wakeStatusText() {
    if (wakeState === 'on') return 'HELD';
    if (wakeState === 'unsupported') return 'n/a - use Auto-Lock=Never';
    if (wakeState === 'failed') return 'FAILED - use Auto-Lock=Never';
    return '...';
  }

  /* ------------------------------ state ------------------------------- */
  var state = 'setup';        // setup | armed | ringing | solved
  var targetMs = 0, nextAlarm = null, ringing = null, dues = {};   // ringing = alarm being rung; dues = per-alarm next-fire ms (transient)
  // survive an OS kill: remember that we WERE armed so a relaunch can warn (missed) or prompt re-arm
  var ARMKEY = 'override_web_armed_' + APPV, missedInfo = null, resumeInfo = null, armTz = null, lastWakeTry = 0;
  function saveArmed() { try { localStorage.setItem(ARMKEY, JSON.stringify({ t: targetMs, id: nextAlarm ? nextAlarm.id : '' })); } catch (e) {} }
  function clearArmed() { try { localStorage.removeItem(ARMKEY); } catch (e) {} }
  function fmtHM(ms) { var d = new Date(ms); function p(n) { return (n < 10 ? '0' : '') + n; } return p(d.getHours()) + ':' + p(d.getMinutes()); }
  var pollTimer = null, nagTimer = null, lastSpoke = 0;
  var editId = null;          // alarm id open in the editor overlay (null = none)

  /* ------------------------- audio (Web Audio) ------------------------ */
  var actx = null, masterGain = null, keepAlive = null;
  var silentEl = null, loudEl = null;
  var alarmTimer = null, watchTimer = null, beepHi = false;
  var lastCtxTime = -1;
  var softLevel = 100;        // decreasing-sound target (100 = full); engine drives via setVolume

  function setPlaybackSession() {
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}
  }
  function gainNow() { return (state === 'ringing') ? Math.max(0.01, softLevel / 100) : 0.00001; }
  function applyVolume() {
    try { if (masterGain) masterGain.gain.value = gainNow(); } catch (e) {}
    try { if (loudEl) loudEl.volume = Math.max(0.01, softLevel / 100); } catch (e) {}
  }
  function buildContext() {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    actx = new AC();
    masterGain = actx.createGain();
    masterGain.gain.value = 0.00001;
    masterGain.connect(actx.destination);
    var buf = actx.createBuffer(1, Math.max(1, Math.round(actx.sampleRate * 0.5)), actx.sampleRate);
    keepAlive = actx.createBufferSource();
    keepAlive.buffer = buf; keepAlive.loop = true;
    keepAlive.connect(masterGain); keepAlive.start(0);
    actx.onstatechange = function () { if (actx && actx.state !== 'running') { try { actx.resume(); } catch (e) {} } };
  }
  function primeAudio() {   // MUST run inside a user gesture (ARM / TEST tap)
    try {
      setPlaybackSession();
      if (!actx) buildContext();
      if (actx && actx.state !== 'running') actx.resume();
      if (!silentEl) {
        silentEl = document.createElement('audio');
        silentEl.loop = true; silentEl.setAttribute('playsinline', ''); silentEl.preload = 'auto';
        silentEl.src = 'silence.wav';
      }
      try { var sp = silentEl.play(); if (sp && sp.catch) sp.catch(function () {}); } catch (e) {}
      if (!loudEl) {
        loudEl = document.createElement('audio');
        loudEl.loop = true; loudEl.setAttribute('playsinline', ''); loudEl.preload = 'auto';
        loudEl.src = 'alarm.wav'; loudEl.volume = 1;
      }
      try { var lp = loudEl.play(); if (lp && lp.then) lp.then(function () { if (state !== 'ringing') { loudEl.pause(); loudEl.currentTime = 0; } }).catch(function () {}); } catch (e) {}
      try { var u = new SpeechSynthesisUtterance(' '); u.volume = 0.01; speechSynthesis.cancel(); speechSynthesis.speak(u); } catch (e) {}
    } catch (e) {}
  }
  function oneBeep() {
    if (!actx) return;
    try {
      var t = actx.currentTime;
      var o = actx.createOscillator(), g = actx.createGain();
      o.type = 'square';
      o.frequency.setValueAtTime(beepHi ? 1120 : 760, t); beepHi = !beepHi;
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.9, t + 0.012);
      g.gain.setValueAtTime(0.9, t + 0.26);
      g.gain.exponentialRampToValueAtTime(0.0001, t + 0.33);
      o.connect(g); g.connect(masterGain);
      o.start(t); o.stop(t + 0.35);
    } catch (e) {}
  }

  /* vibration (Android only; navigator.vibrate is absent on iOS = no-op) */
  var vibeTimer = null;
  function vibeOnce() { try { if (navigator.vibrate) navigator.vibrate([500, 250, 500, 250, 700]); } catch (e) {} }
  function startVibe() { vibeOnce(); if (!vibeTimer) vibeTimer = setInterval(function () { if (state === 'ringing') vibeOnce(); }, 2400); }
  function stopVibe() { if (vibeTimer) { clearInterval(vibeTimer); vibeTimer = null; } try { if (navigator.vibrate) navigator.vibrate(0); } catch (e) {} }

  function startAlarm() {
    setPlaybackSession();
    if (actx) { try { if (actx.state !== 'running') actx.resume(); } catch (e) {} }
    applyVolume();
    if (!alarmTimer) { oneBeep(); alarmTimer = setInterval(oneBeep, 420); }
    try { if (loudEl) { var p = loudEl.play(); if (p && p.catch) p.catch(function () {}); } } catch (e) {}
    startVibe();
    startWatchdog();
  }
  function stopAlarm() {
    if (alarmTimer) { clearInterval(alarmTimer); alarmTimer = null; }
    if (watchTimer) { clearInterval(watchTimer); watchTimer = null; }
    stopVibe();
    try { if (masterGain) masterGain.gain.value = 0.00001; } catch (e) {}
    try { if (loudEl) { loudEl.pause(); loudEl.currentTime = 0; loudEl.volume = 1; } } catch (e) {}
  }
  function recreateAudio() {
    try { if (alarmTimer) { clearInterval(alarmTimer); alarmTimer = null; } } catch (e) {}
    try { if (actx) actx.close(); } catch (e) {}
    actx = null; masterGain = null; keepAlive = null; lastCtxTime = -1;
    setPlaybackSession();
    buildContext();
    if (state === 'ringing') startAlarm();
  }
  function startWatchdog() {
    if (watchTimer) return;
    lastCtxTime = actx ? actx.currentTime : -1;
    watchTimer = setInterval(function () {
      if (state !== 'ringing') return;
      try { if (loudEl && loudEl.paused) loudEl.play().catch(function () {}); } catch (e) {}
      if (!actx) { if (window.AudioContext || window.webkitAudioContext) recreateAudio(); return; }   // no-AC device: <audio> loop carries the alarm
      if (actx.state !== 'running') { try { actx.resume(); } catch (e) {} }
      var now = actx.currentTime;
      if (now <= lastCtxTime + 0.0005) { recreateAudio(); return; }
      lastCtxTime = now;
      if (!alarmTimer) startAlarm();
    }, 1000);
  }
  function ensureAlarm() {
    if (state !== 'ringing') return;
    setPlaybackSession();
    try { if (actx && actx.state !== 'running') actx.resume(); } catch (e) {}
    try { if (silentEl && silentEl.paused) silentEl.play().catch(function () {}); } catch (e) {}
    try { if (loudEl && loudEl.paused) loudEl.play().catch(function () {}); } catch (e) {}
    if (!alarmTimer) startAlarm();
    startWatchdog();
  }

  /* ----------------------------- narrator ----------------------------- */
  function speak(text, force) {
    var now = Date.now();
    if (!force && now - lastSpoke < 4000) return;
    lastSpoke = now;
    try {
      var u = new SpeechSynthesisUtterance(text);
      var vs = speechSynthesis.getVoices();
      if (vs && vs.length) u.voice = vs[(Math.random() * vs.length) | 0];
      u.volume = Math.max(0.2, softLevel / 100);
      speechSynthesis.cancel(); speechSynthesis.speak(u);
    } catch (e) {}
  }
  function startNag() {
    stopNag();
    nagTimer = setInterval(function () {
      if (state !== 'ringing') return;
      ensureAlarm();
      speak(C.pick(C.LINES.nag));
    }, 17000);
  }
  function stopNag() { if (nagTimer) { clearInterval(nagTimer); nagTimer = null; } }

  /* ---------------------------- wake lock ----------------------------- */
  var wakeLock = null, wakeWanted = false, wakeState = 'off', releaseTimer = null;
  function acquireWake() {
    wakeWanted = true;
    if (releaseTimer) { clearTimeout(releaseTimer); releaseTimer = null; }   // a re-arm cancels any pending release
    try {
      if (!('wakeLock' in navigator) || !navigator.wakeLock || !navigator.wakeLock.request) {
        if (wakeState !== 'unsupported') { wakeState = 'unsupported'; dlog('wakeLock UNSUPPORTED - rely on Auto-Lock=Never'); }
        return;
      }
      if (wakeLock) return;
      navigator.wakeLock.request('screen').then(function (wl) {
        wakeLock = wl; wakeState = 'on'; dlog('wakeLock acquired');
        wakeLock.addEventListener('release', function () { wakeLock = null; if (wakeState === 'on') wakeState = 'off'; dlog('wakeLock released by OS'); });
      }).catch(function (err) { if (wakeState !== 'failed') dlog('wakeLock FAILED: ' + (err && err.name ? err.name : 'error')); wakeState = 'failed'; });
    } catch (e) { wakeState = 'failed'; dlog('wakeLock threw'); }
  }
  function releaseWake() { wakeWanted = false; wakeState = 'off'; try { if (wakeLock) { wakeLock.release(); wakeLock = null; } } catch (e) {} }

  /* ---------------------------- scheduler ----------------------------- */
  function nextOccurrence(hhmm) {
    var p = String(hhmm).split(':'), h = parseInt(p[0], 10) || 0, m = parseInt(p[1], 10) || 0;
    h = Math.max(0, Math.min(23, h)); m = Math.max(0, Math.min(59, m));   // "730" typed in a no-picker browser must never schedule a month out
    var now = new Date();
    var t = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0, 0);
    if (t.getTime() <= now.getTime()) t.setDate(t.getDate() + 1);
    return t.getTime();
  }
  function scheduleAll() {   // stamp each enabled alarm's next fire time (transient; recomputed at arm)
    dues = {};
    for (var i = 0; i < cfg.alarms.length; i++) { var a = cfg.alarms[i]; if (a.enabled) dues[a.id] = nextOccurrence(a.time); }
  }
  function soonest() {       // {alarm,t} of the earliest-due enabled alarm (also sets nextAlarm/targetMs), or null
    var best = null, bt = 0, i, a, t;
    for (i = 0; i < cfg.alarms.length; i++) {
      a = cfg.alarms[i]; if (!a.enabled) continue;
      t = dues[a.id]; if (t == null) { t = nextOccurrence(a.time); dues[a.id] = t; }
      if (!best || t < bt) { best = a; bt = t; }
    }
    if (!best) { nextAlarm = null; targetMs = 0; return null; }
    nextAlarm = best; targetMs = bt; return { alarm: best, t: bt };
  }
  function dueNow(now) {      // an enabled alarm whose stored due time has already passed, or null.
    // Uses the STORED due (not a fresh nextOccurrence) so an alarm whose time passed while another
    // was being solved still fires, and two alarms at the same minute both fire (one, then the next).
    for (var i = 0; i < cfg.alarms.length; i++) { var a = cfg.alarms[i]; if (a.enabled && dues[a.id] != null && dues[a.id] <= now) return a; }
    return null;
  }
  function catsArray(a) {
    var out = [], k; for (k in a.cats) { if (a.cats[k]) out.push(k); }
    if (out.length === 0) out = ['arithmetic'];
    return out;
  }
  function fmtLeft(ms) {
    if (ms < 0) ms = 0;
    var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = s % 60;
    function p2(n) { return (n < 10 ? '0' : '') + n; }
    return (h > 0 ? h + 'h ' : '') + p2(m) + 'm ' + p2(ss) + 's';
  }

  function arm() {
    scheduleAll();
    if (!soonest()) { dlog('ARM refused: no enabled alarms'); return; }
    primeAudio();
    acquireWake();
    state = 'armed'; lastTickT = 0; armTz = new Date().getTimezoneOffset();
    missedInfo = null; resumeInfo = null; saveArmed();
    dlog('ARM ' + APPV + '/' + PLAT + ' next=' + nextAlarm.time + ' "' + nextAlarm.label + '" in ' + Math.round((targetMs - Date.now()) / 1000) + 's; wakeLock=' + ('wakeLock' in navigator));
    renderArmed();
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(tick, 250);
  }
  function disarm() {
    state = 'setup'; ringing = null; clearArmed();
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    stopAlarm(); stopNag(); releaseWake();
    try { document.documentElement.className = ''; } catch (e) {}
    renderSetup();
  }
  var lastTickT = 0;
  function tick() {
    var now = Date.now();
    if (lastTickT && (now - lastTickT) > 1500 && state === 'armed') {
      dlog('TIMER FROZE ~' + Math.round((now - lastTickT) / 1000) + 's (screen slept or app backgrounded)');
    }
    lastTickT = now;
    if (wakeWanted && !wakeLock && document.visibilityState === 'visible' && (now - lastWakeTry > 5000)) { lastWakeTry = now; acquireWake(); }
    if (state !== 'armed') return;
    if (armTz !== null && new Date().getTimezoneOffset() !== armTz) {   // travel/TZ change: recompute all due times
      armTz = new Date().getTimezoneOffset(); dlog('timezone changed -> rescheduling');
      scheduleAll(); soonest(); saveArmed();
    }
    var due = dueNow(now);
    if (due) { var late = now - dues[due.id]; dlog('FIRE "' + due.label + '"' + (late > 2000 ? ' LATE by ' + Math.round(late / 1000) + 's (page had been asleep)' : '')); fire(due); return; }
    if (!soonest()) { disarm(); return; }   // all alarms got disabled -> back to setup
    var left = targetMs - now;
    var n = document.getElementById('cdNum'); if (n) n.textContent = fmtLeft(left);
    var hb = document.getElementById('cdHb'); if (hb) hb.innerHTML = beat() + ' live &nbsp;·&nbsp; screen-lock: ' + wakeStatusText();
  }

  /* ------------------------------- fire ------------------------------- */
  function fire(alarm) {
    if (state === 'ringing') return;
    state = 'ringing'; ringing = alarm;
    softLevel = 100;
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    acquireWake();
    setPlaybackSession();
    try { if (actx && actx.state !== 'running') actx.resume(); } catch (e) {}
    startAlarm();
    goFullscreen();
    OVERRIDE_UI.init({
      label: (alarm.label || 'WAKE PROTOCOL') + ' · ' + alarm.time,
      numQuestions: alarm.numQuestions,
      difficulty: alarm.difficulty,
      cats: catsArray(alarm),
      matrixRain: !!alarm.matrixRain,
      deadlineMs: 0,                     // no auto-end: only SOLVING stops it
      theme: alarm.theme,
      user: '',
      soften: !!alarm.soften,
      setVolume: function (lvl) {        // engine's decreasing-sound curve drives our gain
        softLevel = Math.max(1, Math.min(100, parseInt(lvl, 10) || 100));
        dlog('vol -> ' + softLevel + '%');
        applyVolume();
      },
      speak: speak,
      unlock: onSolved,
      engineGone: function () { return false; },
      closeWin: afterVictory             // engine calls this ~9.5s after the win
    });
    speak(C.pick(C.LINES.start), true);
    startNag();
  }

  function onSolved() {
    if (state === 'solved') return;
    dlog('SOLVED "' + (ringing ? ringing.label : '?') + '" -> silenced');
    state = 'solved';
    stopAlarm(); stopNag();
    softLevel = 100;
    if (ringing) {
      if (ringing.repeat) { dues[ringing.id] = nextOccurrence(ringing.time); }   // this one -> tomorrow
      else { ringing.enabled = false; delete dues[ringing.id]; saveCfg(); }        // one-time -> off
    }
    if (soonest()) {   // another alarm may already be due (both fired this minute) -> tick fires it next
      state = 'armed'; saveArmed();
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = setInterval(tick, 250);
    } else {
      state = 'setup'; clearArmed();
      if (releaseTimer) clearTimeout(releaseTimer);
      releaseTimer = setTimeout(function () { releaseTimer = null; if (state === 'setup') releaseWake(); }, 60000);
    }
  }
  function afterVictory() {   // leave the victory screen -> back to the countdown / list
    if (state === 'ringing') return;   // a NEW ring started during the 9.5s victory window - never clobber it
    ringing = null;
    try { document.documentElement.className = ''; } catch (e) {}
    if (state === 'armed') renderArmed(); else if (state !== 'ringing') renderSetup();
  }

  function testSound(seconds) {
    primeAudio();
    if (state === 'ringing') return;          // never touch a live ring
    softLevel = 100;
    var was = state; state = 'ringing'; startAlarm(); state = was;
    // startAlarm saw 'ringing' so gain is audible; schedule the stop, but never kill a REAL ring
    setTimeout(function () { if (state !== 'ringing') stopAlarm(); }, (seconds || 5) * 1000);
  }
  function testRing() {
    primeAudio(); acquireWake();
    var t = newAlarm();
    var src = cfg.alarms[0] || t;
    t.label = 'TEST'; t.theme = src.theme; t.difficulty = 'easy'; t.numQuestions = 1;
    t.soften = !!src.soften; t.cats = { arithmetic: true };
    setTimeout(function () { if (state !== 'ringing') fire(t); }, 800);
  }

  /* ---------------------- inescapable re-assertion -------------------- */
  function goFullscreen() {
    try {
      var el = document.documentElement;
      if (el.requestFullscreen) { var p = el.requestFullscreen(); if (p && p.catch) p.catch(function () {}); }
      else if (el.webkitRequestFullscreen) el.webkitRequestFullscreen();
    } catch (e) {}
  }
  document.addEventListener('visibilitychange', function () {
    dlog('visibility ' + document.visibilityState + (state !== 'setup' ? ' [' + state + ']' : ''));
    if (document.visibilityState !== 'visible') return;
    if (state === 'armed' || state === 'ringing') acquireWake();
    if (state === 'armed') tick();
    if (state === 'ringing') { ensureAlarm(); speak(C.pick(C.LINES.nag), true); }
  });
  window.addEventListener('pageshow', function () { if (state === 'ringing') ensureAlarm(); });
  window.addEventListener('focus', function () { if (state === 'ringing') ensureAlarm(); });
  window.addEventListener('beforeunload', function (e) {
    if (state === 'ringing' || state === 'armed') { e.preventDefault(); e.returnValue = ''; return ''; }
  });
  // first interaction while ringing PRIMES audio too (gate mode fires with no prior gesture, so
  // actx/loudEl may not exist yet - touch/click are user activations, so build them right here)
  function wakeTheSiren() { if (state !== 'ringing') return; primeAudio(); ensureAlarm(); }
  document.addEventListener('touchstart', wakeTheSiren, { passive: true });
  document.addEventListener('mousedown', wakeTheSiren);
  document.addEventListener('keydown', wakeTheSiren);

  /* ------------------------------- views ------------------------------ */
  function root() {
    var r = document.getElementById('ovr');
    if (!r) { r = document.createElement('div'); r.id = 'ovr'; document.body.innerHTML = ''; document.body.appendChild(r); }
    r.className = (state === 'armed' ? 'armed' : '');
    return r;
  }
  function chips(into, items, getOn, onPick) {
    var seg = document.createElement('div'); seg.className = 'seg';
    items.forEach(function (it) {
      var b = document.createElement('div'); b.className = 'chip' + (getOn(it[0]) ? ' on' : ''); b.textContent = it[1];
      b.addEventListener('click', function () { onPick(it[0]); });
      seg.appendChild(b);
    });
    into.appendChild(seg);
  }
  function alarmById(id) {
    for (var i = 0; i < cfg.alarms.length; i++) { if (cfg.alarms[i].id === id) return cfg.alarms[i]; }
    return null;
  }
  function summary(a) {
    var n = catsArray(a).length;
    return a.difficulty + ' ×' + a.numQuestions + ' · ' + n + ' subject' + (n === 1 ? '' : 's') +
      ' · ' + a.theme + (a.soften ? ' · ↓sound' : '') + (a.repeat ? ' · daily' : ' · once');
  }

  function renderSetup() {
    var r = root(); r.innerHTML = '';
    if (missedInfo) {   // the OS killed the app while armed and the alarm time passed silently
      var mc = document.createElement('div'); mc.className = 'card';
      mc.style.borderColor = '#ff2233';
      mc.innerHTML = '<h2 style="color:#ff2233">&#9888; ALARM DID NOT RING</h2><div style="font-size:13px;line-height:1.6;color:#ffd6d9">The system closed this app while it was armed for <b>' + fmtHM(missedInfo.t) + '</b>. A web app cannot ring once closed - keep it open, foreground, screen on; and always set the native Clock failsafe.</div>';
      var mb = document.createElement('button'); mb.className = 'btn ghost'; mb.textContent = 'UNDERSTOOD';
      mb.addEventListener('click', function () { missedInfo = null; renderSetup(); });
      mc.appendChild(mb); r.appendChild(mc);
    } else if (resumeInfo) {
      var rc = document.createElement('div'); rc.className = 'card';
      rc.innerHTML = '<h2>&#9888; RE-ARM NEEDED</h2><div style="font-size:13px;line-height:1.6;color:#ffd6d9">You were armed (next: <b>' + fmtHM(resumeInfo.t) + '</b>) but the app was closed and reopened. Tap <b>ARM</b> below to re-arm (a tap is required to re-enable sound).</div>';
      r.appendChild(rc);
    }
    var brand = document.createElement('div'); brand.className = 'brandrow';
    brand.innerHTML = '<div class="logo">OVERRIDE</div><div class="tag">WAKE PROTOCOL // ' + APPV + '.2 - ' + PNAME + ' (universal)</div>';
    r.appendChild(brand);

    // ---- alarm list ----
    var c1 = document.createElement('div'); c1.className = 'card';
    c1.innerHTML = '<h2>ALARMS</h2>';
    cfg.alarms.forEach(function (a) {
      var row = document.createElement('div'); row.className = 'alarm-row' + (a.enabled ? '' : ' off');
      var left = document.createElement('div'); left.className = 'ar-left';
      left.innerHTML = '<div class="ar-time">' + esc(a.time) + '</div><div class="ar-lbl">' + esc(a.label || 'WAKE UP') + '</div><div class="ar-sum">' + summary(a) + '</div>';
      left.addEventListener('click', function () { editId = a.id; renderSetup(); });
      var right = document.createElement('div'); right.className = 'ar-right';
      var tgl = document.createElement('div'); tgl.className = 'chip' + (a.enabled ? ' on' : ''); tgl.textContent = a.enabled ? 'ON' : 'OFF';
      tgl.addEventListener('click', function () { a.enabled = !a.enabled; saveCfg(); renderSetup(); });
      var del = document.createElement('div'); del.className = 'chip del'; del.textContent = '✕';
      del.addEventListener('click', function () {
        cfg.alarms = cfg.alarms.filter(function (x) { return x.id !== a.id; });
        if (editId === a.id) editId = null;
        saveCfg(); renderSetup();
      });
      right.appendChild(tgl); right.appendChild(del);
      row.appendChild(left); row.appendChild(right);
      c1.appendChild(row);
    });
    var add = document.createElement('button'); add.className = 'btn ghost'; add.textContent = '+ ADD ALARM';
    add.addEventListener('click', function () { var a = newAlarm(); cfg.alarms.push(a); editId = a.id; saveCfg(); renderSetup(); });
    c1.appendChild(add);
    r.appendChild(c1);

    // ---- editor (inline, for the alarm being edited) ----
    var ed = editId ? alarmById(editId) : null;
    if (ed) {
      var c2 = document.createElement('div'); c2.className = 'card';
      c2.innerHTML = '<h2>EDIT · ' + esc(ed.time) + '</h2>';
      var trow = document.createElement('div'); trow.className = 'timewrap';
      var tin = document.createElement('input'); tin.type = 'time'; tin.value = ed.time;
      tin.addEventListener('change', function (e) {
        var v = String(e.target.value || '').trim();
        if (/^([01]?\d|2[0-3]):[0-5]\d$/.test(v)) { ed.time = v; saveCfg(); }
        else { e.target.value = ed.time; }          // reject junk from no-picker browsers, keep the old value
      });
      trow.appendChild(tin); c2.appendChild(trow);
      var lrow = document.createElement('div'); lrow.className = 'row'; lrow.innerHTML = '<label>label</label>';
      var lin = document.createElement('input'); lin.type = 'text'; lin.value = ed.label; lin.maxLength = 24;
      lin.style.cssText = 'font-family:inherit;font-size:16px;background:#170003;color:#ffd6d9;border:1px solid #7a1018;border-radius:8px;padding:8px 10px;width:55%';
      lin.addEventListener('change', function (e) { ed.label = e.target.value || 'WAKE UP'; saveCfg(); });
      lrow.appendChild(lin); c2.appendChild(lrow);
      var rrow = document.createElement('div'); rrow.className = 'row'; rrow.innerHTML = '<label>repeat</label>'; c2.appendChild(rrow);
      chips(rrow, [['daily', 'daily'], ['once', 'once']], function (k) { return (k === 'daily') === !!ed.repeat; }, function (k) { ed.repeat = (k === 'daily'); saveCfg(); renderSetup(); });
      var drow = document.createElement('div'); drow.className = 'row'; drow.innerHTML = '<label>difficulty</label>'; c2.appendChild(drow);
      chips(drow, [['easy', 'easy'], ['medium', 'medium'], ['hard', 'hard']], function (k) { return ed.difficulty === k; }, function (k) { ed.difficulty = k; saveCfg(); renderSetup(); });
      var nrow = document.createElement('div'); nrow.className = 'row'; nrow.innerHTML = '<label>questions</label>'; c2.appendChild(nrow);
      chips(nrow, [['1','1'],['2','2'],['3','3'],['5','5'],['10','10'],['15','15'],['20','20'],['30','30'],['50','50']], function (k) { return String(ed.numQuestions) === k; }, function (k) { ed.numQuestions = parseInt(k, 10); saveCfg(); renderSetup(); });
      var throw_ = document.createElement('div'); throw_.className = 'row'; throw_.innerHTML = '<label>theme</label>'; c2.appendChild(throw_);
      chips(throw_, [['red','red'],['green','green'],['cyber','cyber'],['1890','1890'],['boring','boring']], function (k) { return ed.theme === k; }, function (k) { ed.theme = k; saveCfg(); renderSetup(); });
      var frow = document.createElement('div'); frow.className = 'row'; frow.innerHTML = '<label>features</label>'; c2.appendChild(frow);
      chips(frow, [['soften', '↓ decreasing sound'], ['rain', 'matrix rain']], function (k) { return k === 'soften' ? !!ed.soften : !!ed.matrixRain; }, function (k) { if (k === 'soften') { ed.soften = !ed.soften; } else { ed.matrixRain = !ed.matrixRain; } saveCfg(); renderSetup(); });
      var srow = document.createElement('div'); srow.className = 'row'; srow.innerHTML = '<label>subjects</label>'; c2.appendChild(srow);
      var subWrap = document.createElement('div'); c2.appendChild(subWrap);
      chips(subWrap, SUBJECTS.map(function (k) { return [k, k]; }), function (k) { return !!ed.cats[k]; }, function (k) {
        ed.cats[k] = !ed.cats[k];
        if (catsArray(ed).length === 0) ed.cats.arithmetic = true;
        saveCfg(); renderSetup();
      });
      var done = document.createElement('button'); done.className = 'btn'; done.textContent = 'DONE';
      done.addEventListener('click', function () { editId = null; renderSetup(); });
      c2.appendChild(done);
      r.appendChild(c2);
    }

    // ---- arm + tests ----
    var c3 = document.createElement('div'); c3.className = 'card';
    var anyOn = cfg.alarms.some(function (a) { return a.enabled; });
    var armBtn = document.createElement('button'); armBtn.className = 'btn arm';
    armBtn.textContent = anyOn ? 'ARM ' + cfg.alarms.filter(function (a) { return a.enabled; }).length + ' ALARM(S)' : 'NO ALARMS ENABLED';
    if (anyOn) armBtn.addEventListener('click', arm);
    c3.appendChild(armBtn);
    var t1 = document.createElement('button'); t1.className = 'btn ghost'; t1.textContent = 'TEST SOUND (5s)';
    t1.addEventListener('click', function () { testSound(5); }); c3.appendChild(t1);
    var t2 = document.createElement('button'); t2.className = 'btn ghost'; t2.textContent = 'TEST FULL ALARM (rings in ~1s)';
    t2.addEventListener('click', testRing); c3.appendChild(t2);
    var t3 = document.createElement('button'); t3.className = 'btn ghost'; t3.textContent = 'DIAGNOSTICS LOG';
    t3.addEventListener('click', showDiag); c3.appendChild(t3);
    r.appendChild(c3);

    // ---- per-platform checklist ----
    var c4 = document.createElement('div'); c4.className = 'card';
    var items;
    if (PLAT === 'android') {
      items = [
        'Chrome menu (&#8942;) &gt; <b>Add to Home screen / Install</b>, open from the icon.',
        '<b>Media volume UP</b> (volume key &gt; dropdown &gt; raise <i>Media</i>).',
        'Settings &gt; Battery: <b>OFF "Put unused apps to sleep"</b>; app battery = <b>Unrestricted</b>.',
        '<b>Plug in</b>; Power saving OFF; keep the <b>screen on</b>.',
        'Tap <b>ARM</b>, leave it open, don&#39;t swipe it from Recents.',
        '<b>Failsafe:</b> set a Clock-app alarm at the same time.'
      ];
    } else if (PLAT === 'desktop') {
      items = [
        'Chrome/Edge: menu &gt; <b>Install OVERRIDE</b> (or keep this tab open &amp; foreground).',
        '<b>Volume UP</b>, speakers on.',
        'Disable sleep: Windows &gt; Power &gt; <b>Screen &amp; sleep = Never</b> · Mac &gt; Lock Screen &gt; <b>Never</b> · keep it <b>plugged in</b>.',
        'Tap <b>ARM</b>, leave this window open &amp; visible.',
        '<b>Windows:</b> the native OVERRIDE engine (v10/windows in the repo) rings even from SLEEP - strictly better than a browser tab.',
        '<b>Failsafe:</b> set a phone Clock alarm at the same time.'
      ];
    } else {
      items = [
        '<b>Add to Home Screen</b> (Share &gt; Add to Home Screen), open from the icon.',
        (PLAT === 'iphone' ? 'Side switch to <b>RING</b> (no orange) + ' : '') + '<b>Volume UP</b>, not muted.',
        'Settings &gt; Display &amp; Brightness &gt; <b>Auto-Lock = Never</b> (critical: a locked screen freezes the alarm).',
        '<b>Plug in</b>, Low Power Mode OFF.',
        'Tap <b>ARM</b>, leave this open. Don&#39;t switch apps or lock the screen.',
        '<b>Failsafe:</b> set a Clock-app alarm at the same time.'
      ];
    }
    var lis = '';
    items.forEach(function (it, i) { lis += '<li><span class="k">' + (i + 1) + '.</span> ' + it + '</li>'; });
    c4.innerHTML = '<h2>BEFORE YOU SLEEP (' + PNAME + ')</h2><ul class="check">' + lis + '</ul>';
    r.appendChild(c4);

    // ---- DEEP SLEEP (v10.2): closed phone / sleeping laptop ----
    var c5 = document.createElement('div'); c5.className = 'card';
    var gateUrl = location.origin + location.pathname + '?gate=1';
    var ds;
    if (PLAT === 'iphone' || PLAT === 'ipad') {
      ds = '<li><span class="k">1.</span> <b>Clock app:</b> set a normal alarm at your wake time (rings even locked - guaranteed by iOS).</li>' +
           '<li><span class="k">2.</span> <b>Shortcuts &gt; Automation &gt; New &gt; Alarm &gt; "When my alarm is stopped"</b> &gt; add action <b>Open URL</b>: <code style="font-size:11px;word-break:break-all">' + gateUrl + '</code> &gt; turn <b>Ask Before Running OFF</b>.</li>' +
           '<li><span class="k">3.</span> Result: stopping the alarm force-opens OVERRIDE in <b>gate mode</b> - the quiz appears instantly and your first tap turns the siren on until you solve it.</li>';
    } else if (PLAT === 'android') {
      ds = '<li><span class="k">1.</span> <b>Clock app:</b> set a normal alarm at your wake time (rings even locked).</li>' +
           '<li><span class="k">2.</span> Samsung: <b>Modes &amp; Routines &gt; Add routine &gt; If: Alarm is dismissed &gt; Then: Open link</b>: <code style="font-size:11px;word-break:break-all">' + gateUrl + '</code> (other Androids: MacroDroid/Tasker "alarm dismissed" trigger).</li>' +
           '<li><span class="k">3.</span> Dismissing the alarm force-opens OVERRIDE in <b>gate mode</b> - quiz on screen, first tap = siren until solved.</li>';
    } else {
      ds = '<li><span class="k">1.</span> <b>Windows:</b> use the native engine (v10/windows) - it wakes the PC from SLEEP by itself. This page is only the fallback.</li>' +
           '<li><span class="k">2.</span> <b>Mac/Linux:</b> v10/unix in the repo - override.sh (alarm) + wake.sh (schedules a hardware wake via pmset / rtcwake; sudo required). Supervised first run!</li>';
    }
    c5.innerHTML = '<h2>DEEP SLEEP - phone closed / laptop asleep</h2><ul class="check">' + ds + '</ul>';
    r.appendChild(c5);

    var note = document.createElement('div'); note.className = 'note';
    note.innerHTML = 'honest limit: a website can&#39;t ring a CLOSED phone by itself (physics of iOS/Android) - deep sleep = native Clock alarm wakes you, OVERRIDE gates the dismissal. Foreground mode above stays the strongest web option.';
    r.appendChild(note);
  }

  function renderArmed() {
    var r = root(); r.innerHTML = '';
    var cd = document.createElement('div'); cd.className = 'cd';
    var when = nextAlarm ? (fmtHM(targetMs) + ' · ' + esc(nextAlarm.label || 'WAKE UP')) : '--';   // from the real epoch, so DST-normalized times display truthfully
    var upcoming = cfg.alarms.filter(function (a) { return a.enabled; })
      .map(function (a) { return esc(a.time) + ' ' + esc(a.label || ''); }).join('&nbsp;&nbsp;|&nbsp;&nbsp;');
    cd.innerHTML =
      '<div class="lbl">ARMED · ' + PNAME + '</div>' +
      '<div class="time">next: ' + when + '</div>' +
      '<div class="num" id="cdNum">--</div>' +
      '<div class="sub" id="cdHb" style="margin-bottom:8px">...</div>' +
      '<div class="sub"><span class="warn">Screen stays ON (don&#39;t lock it) &amp; keep it plugged in.</span><br>' +
      'If the ● stops blinking the OS froze the page - tap the screen.<br>' +
      (nextAlarm ? ('Solve ' + nextAlarm.numQuestions + ' question' + (nextAlarm.numQuestions === 1 ? '' : 's') + ' to silence it' + (nextAlarm.soften ? ' (each answer softens the sound; stalling resets it)' : '') + '.') : '') +
      '</div>' +
      '<div class="sub" style="margin-top:10px;opacity:.8">' + upcoming + '</div>';
    r.appendChild(cd);
    var dis = document.createElement('button'); dis.className = 'btn ghost'; dis.style.maxWidth = '320px';
    dis.textContent = 'DISARM / EDIT'; dis.addEventListener('click', disarm); cd.appendChild(dis);
    tick();
  }

  /* --------------------------- service worker ------------------------- */
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () { navigator.serviceWorker.register('sw.js').catch(function () {}); });
  }

  /* ------------------------------- boot ------------------------------- */
  window.addEventListener('storage', function (ev) {   // another tab wrote the config -> reload, don't clobber
    if (ev.key === LS && state === 'setup') { cfg = loadCfg(); renderSetup(); }
  });
  dlog('app loaded ' + APPV + '/' + PLAT + ' (' + (window.navigator.standalone ? 'home-screen PWA' : 'browser tab') + ')');
  try {
    var prev = JSON.parse(localStorage.getItem(ARMKEY));
    if (prev && prev.t) {
      if (prev.t <= Date.now()) { missedInfo = prev; dlog('MISSED ALARM: app was closed while armed; target ' + fmtHM(prev.t) + ' passed ' + Math.round((Date.now() - prev.t) / 60000) + ' min ago'); }
      else { resumeInfo = prev; dlog('found live armed record (target ' + fmtHM(prev.t) + ') after relaunch -> prompting re-arm'); }
      clearArmed();
    }
  } catch (e) {}
  if (qs('gate') === '1') {
    // DEEP SLEEP GATE (v10.2): opened by an automation right after the native Clock alarm was
    // dismissed. Fire the quiz IMMEDIATELY. Audio is gesture-locked until the first tap - the
    // existing touchstart->ensureAlarm hook turns the siren on the moment they touch the screen.
    var ga = null, gi;
    for (gi = 0; gi < cfg.alarms.length; gi++) { if (cfg.alarms[gi].enabled) { ga = cfg.alarms[gi]; break; } }
    var gsrc = ga || newAlarm();
    missedInfo = null; resumeInfo = null;
    dlog('GATE opened by automation (' + PLAT + ')');
    fire({ id: 'gate', time: gsrc.time, label: 'DEEP SLEEP GATE', enabled: true, repeat: true,
           theme: gsrc.theme, difficulty: gsrc.difficulty, numQuestions: gsrc.numQuestions,
           soften: gsrc.soften, matrixRain: gsrc.matrixRain, cats: gsrc.cats });
  } else {
    renderSetup();
  }
})();
