/* OVERRIDE v7 // iOS / web wake-alarm shell.
   ---------------------------------------------------------------------------
   Wraps the shared, selftested quiz engine (core.js -> OVERRIDE_UI) in a
   leave-it-open foreground PWA alarm. The engine is reused verbatim; we only
   hand it an unlock() that silences the alarm.

   Design + honest limits (see v7/README.md). Verified against current iPadOS
   (research workflow, 2026-06): a foreground, screen-on, plugged-in PWA is the
   most reliable web-only path. Key facts baked in below:
   - AUDIO THROUGH MUTE: navigator.audioSession.type='playback' (iOS 16.4+/
     reliable 17+) routes to the MEDIA channel, which Control-Center mute AND
     Focus/DND do NOT silence. Set it early, inside the ARM gesture. A silent
     <audio> loop is the iOS-16 fallback. JS cannot raise volume from zero.
   - AUDIOCONTEXT can go 'interrupted' / "running but frozen" hours in; resume()
     may never recover -> a watchdog recreates the context if currentTime stalls.
     A SECOND independent loud <audio loop> runs in parallel as a backstop.
   - WAKE LOCK: iPad Safari 16.4+ (installed PWA 18.4+); iOS releases it on every
     hide -> re-acquire (ungated) on visibilitychange-to-visible.
   - SCHEDULER: clock-poll (compare Date.now() to target every 250ms), never one
     long setTimeout -> immune to drift/throttle.
   - We CANNOT block the home gesture / app switcher / power button. So we also
     recommend a native Clock alarm at the same time as a dumb failsafe.
   --------------------------------------------------------------------------- */
(function () {
  'use strict';
  var C = OVERRIDE_CORE;

  /* ----------------------------- settings ----------------------------- */
  var LS = 'override_v7_cfg';
  var SUBJECTS = [
    ['arithmetic', 'arithmetic'], ['equations', 'equations'], ['percentages', 'percent'],
    ['powers', 'powers'], ['sequences', 'sequences'], ['derivatives', 'calculus'],
    ['vectors', 'vectors'], ['matrices', 'matrices'], ['capitals', 'capitals'],
    ['elements', 'chemistry'], ['binary', 'binary/hex'], ['integrals', 'integrals']
  ];
  var DEFAULTS = {
    time: '07:00', theme: 'red', difficulty: 'hard', numQuestions: 3,
    repeat: true, matrixRain: true, cats: { arithmetic: true }
  };
  function loadCfg() {
    try { var s = JSON.parse(localStorage.getItem(LS)) || {}; return merge(clone(DEFAULTS), s); }
    catch (e) { return clone(DEFAULTS); }
  }
  function clone(o) { return JSON.parse(JSON.stringify(o)); }
  function merge(a, b) { for (var k in b) { if (b.hasOwnProperty(k)) a[k] = b[k]; } return a; }
  function saveCfg() { try { localStorage.setItem(LS, JSON.stringify(cfg)); } catch (e) {} }
  var cfg = loadCfg();

  /* --------------------------- diagnostics ---------------------------- */
  // A persistent ring-buffer log in localStorage so we can SEE what happened overnight
  // (iOS freezes a backgrounded/locked page's JS; this captures freezes, visibility
  // changes, wake-lock state and fire/solve so a morning screenshot tells the whole story).
  var DLOG = 'override_v7_diag';
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
    var h = document.createElement('div'); h.textContent = 'OVERRIDE diagnostics - screenshot this & send it';
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
  var targetMs = 0, pollTimer = null, nagTimer = null, lastSpoke = 0;

  /* ------------------------- audio (Web Audio) ------------------------ */
  var actx = null, masterGain = null, keepAlive = null;
  var silentEl = null, loudEl = null;            // <audio> session-primer + loud backstop
  var alarmTimer = null, watchTimer = null, beepHi = false;
  var lastCtxTime = -1, audioPrimed = false;

  function setPlaybackSession() {
    try { if (navigator.audioSession) navigator.audioSession.type = 'playback'; } catch (e) {}
  }

  function buildContext() {
    var AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    actx = new AC();
    masterGain = actx.createGain();
    masterGain.gain.value = 0.00001;             // near-silent idle
    masterGain.connect(actx.destination);
    // keep-alive: a silent looping buffer so iOS keeps the graph from being torn down
    var buf = actx.createBuffer(1, Math.max(1, Math.round(actx.sampleRate * 0.5)), actx.sampleRate);
    keepAlive = actx.createBufferSource();
    keepAlive.buffer = buf; keepAlive.loop = true;
    keepAlive.connect(masterGain); keepAlive.start(0);
    actx.onstatechange = function () { if (actx && actx.state !== 'running') { try { actx.resume(); } catch (e) {} } };
  }

  // MUST be called from a user gesture (the ARM / TEST tap). Unlocks + keeps alive.
  function primeAudio() {
    try {
      setPlaybackSession();                       // EARLY: media channel before context
      if (!actx) buildContext();
      if (actx && actx.state !== 'running') actx.resume();
      // audio-session nudge / iOS-16 fallback: a silent looping <audio> primed on the gesture
      if (!silentEl) {
        silentEl = document.createElement('audio');
        silentEl.loop = true; silentEl.setAttribute('playsinline', ''); silentEl.preload = 'auto';
        silentEl.src = 'silence.wav';
      }
      try { var sp = silentEl.play(); if (sp && sp.catch) sp.catch(function () {}); } catch (e) {}
      // independent loud backstop (kept paused until fire) — second sound engine
      if (!loudEl) {
        loudEl = document.createElement('audio');
        loudEl.loop = true; loudEl.setAttribute('playsinline', ''); loudEl.preload = 'auto';
        loudEl.src = 'alarm.wav'; loudEl.volume = 1;
      }
      // prime it (play+immediately pause) so a later .play() needs no gesture
      try { var lp = loudEl.play(); if (lp && lp.then) lp.then(function () { loudEl.pause(); loudEl.currentTime = 0; }).catch(function () {}); } catch (e) {}
      // unlock SpeechSynthesis with a near-silent utterance so the narrator can speak later
      try { var u = new SpeechSynthesisUtterance(' '); u.volume = 0.01; speechSynthesis.cancel(); speechSynthesis.speak(u); } catch (e) {}
      audioPrimed = true;
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

  function startAlarm() {
    setPlaybackSession();
    if (actx) { try { if (actx.state !== 'running') actx.resume(); } catch (e) {} try { masterGain.gain.value = 1.0; } catch (e) {} }
    if (!alarmTimer) { oneBeep(); alarmTimer = setInterval(oneBeep, 420); }
    // second engine: loud media-element loop
    try { if (loudEl) { loudEl.volume = 1; var p = loudEl.play(); if (p && p.catch) p.catch(function () {}); } } catch (e) {}
    startWatchdog();
  }
  function stopAlarm() {
    if (alarmTimer) { clearInterval(alarmTimer); alarmTimer = null; }
    if (watchTimer) { clearInterval(watchTimer); watchTimer = null; }
    try { if (masterGain) masterGain.gain.value = 0.00001; } catch (e) {}
    try { if (loudEl) { loudEl.pause(); loudEl.currentTime = 0; } } catch (e) {}
  }

  // recreate a dead/frozen context (resume() can be deferred forever in 'interrupted')
  function recreateAudio() {
    try { if (alarmTimer) { clearInterval(alarmTimer); alarmTimer = null; } } catch (e) {}
    try { if (actx) actx.close(); } catch (e) {}
    actx = null; masterGain = null; keepAlive = null; lastCtxTime = -1;
    setPlaybackSession();
    buildContext();
    if (state === 'ringing') startAlarm();
  }

  // watchdog: while ringing, every 1s ensure the context is actually producing sound;
  // if state isn't 'running' or currentTime has stalled (the "running but frozen" bug),
  // resume then, if still stalled, rebuild the whole context. Also keep the loud loop alive.
  function startWatchdog() {
    if (watchTimer) return;
    lastCtxTime = actx ? actx.currentTime : -1;
    watchTimer = setInterval(function () {
      if (state !== 'ringing') return;
      try { if (loudEl && loudEl.paused) loudEl.play().catch(function () {}); } catch (e) {}
      if (!actx) { recreateAudio(); return; }
      if (actx.state !== 'running') { try { actx.resume(); } catch (e) {} }
      var now = actx.currentTime;
      if (now <= lastCtxTime + 0.0005) { recreateAudio(); return; }  // frozen -> rebuild
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
      u.volume = 1;
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
  // Keeping the screen ON is THE thing that stops iOS suspending our JS. Re-acquire
  // aggressively (iOS drops the lock on every hide) and record state so the armed
  // screen + diagnostics show whether it's actually holding.
  var wakeLock = null, wakeWanted = false, wakeState = 'off';   // off | on | unsupported | failed
  function acquireWake() {
    wakeWanted = true;
    try {
      if (!('wakeLock' in navigator) || !navigator.wakeLock || !navigator.wakeLock.request) {
        if (wakeState !== 'unsupported') { wakeState = 'unsupported'; dlog('wakeLock UNSUPPORTED - rely on Auto-Lock=Never'); }
        return;
      }
      if (wakeLock) return;
      navigator.wakeLock.request('screen').then(function (wl) {
        wakeLock = wl; wakeState = 'on'; dlog('wakeLock acquired');
        wakeLock.addEventListener('release', function () { wakeLock = null; if (wakeState === 'on') wakeState = 'off'; dlog('wakeLock released by OS'); });
      }).catch(function (err) { wakeState = 'failed'; dlog('wakeLock FAILED: ' + (err && err.name ? err.name : 'error')); });
    } catch (e) { wakeState = 'failed'; dlog('wakeLock threw'); }
  }
  function releaseWake() { wakeWanted = false; wakeState = 'off'; try { if (wakeLock) { wakeLock.release(); wakeLock = null; } } catch (e) {} }

  /* ---------------------------- scheduler ----------------------------- */
  function nextOccurrence(hhmm) {
    var p = String(hhmm).split(':'), h = parseInt(p[0], 10) || 0, m = parseInt(p[1], 10) || 0;
    var now = new Date();
    var t = new Date(now.getFullYear(), now.getMonth(), now.getDate(), h, m, 0, 0);
    if (t.getTime() <= now.getTime()) t.setDate(t.getDate() + 1);
    return t.getTime();
  }
  function catsArray() {
    var a = [], k; for (k in cfg.cats) { if (cfg.cats[k]) a.push(k); }
    if (a.length === 0) a = ['arithmetic'];
    return a;
  }
  function fmtLeft(ms) {
    if (ms < 0) ms = 0;
    var s = Math.floor(ms / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = s % 60;
    function p2(n) { return (n < 10 ? '0' : '') + n; }
    return (h > 0 ? h + 'h ' : '') + p2(m) + 'm ' + p2(ss) + 's';
  }

  function arm() {
    primeAudio();              // gesture-bound: unlock audio NOW
    acquireWake();
    targetMs = nextOccurrence(cfg.time);
    state = 'armed'; lastTickT = 0;
    dlog('ARM ' + cfg.time + ' -> fires in ' + Math.round((targetMs - Date.now()) / 1000) + 's; wakeLock support=' + ('wakeLock' in navigator));
    renderArmed();
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(tick, 250);
  }
  function disarm() {
    state = 'setup';
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    stopAlarm(); stopNag(); releaseWake();
    renderSetup();
  }
  var lastTickT = 0;
  function tick() {
    var now = Date.now();
    // suspension detector: ticks are 250ms apart; a big gap means iOS froze the page
    if (lastTickT && (now - lastTickT) > 1500 && state === 'armed') {
      dlog('TIMER FROZE ~' + Math.round((now - lastTickT) / 1000) + 's (screen slept or app backgrounded)');
    }
    lastTickT = now;
    // re-grab the screen lock if we lost it and we're visible (cheap, idempotent)
    if (wakeWanted && !wakeLock && document.visibilityState === 'visible') acquireWake();
    if (state !== 'armed') return;
    var left = targetMs - now;
    if (left <= 0) { dlog('FIRE' + (left < -2000 ? ' LATE by ' + Math.round(-left / 1000) + 's (page had been asleep)' : '')); fire(); return; }
    var n = document.getElementById('cdNum'); if (n) n.textContent = fmtLeft(left);
    var hb = document.getElementById('cdHb'); if (hb) hb.innerHTML = beat() + ' live &nbsp;·&nbsp; screen-lock: ' + wakeStatusText();
  }

  /* ------------------------------- fire ------------------------------- */
  function fire() {
    if (state === 'ringing') return;
    state = 'ringing';
    if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    acquireWake();
    setPlaybackSession();
    try { if (actx && actx.state !== 'running') actx.resume(); } catch (e) {}
    startAlarm();
    goFullscreen();
    // hand off to the shared quiz engine — it replaces <body> with the themed quiz
    OVERRIDE_UI.init({
      label: 'WAKE PROTOCOL',
      numQuestions: cfg.numQuestions,
      difficulty: cfg.difficulty,
      cats: catsArray(),
      matrixRain: !!cfg.matrixRain,
      deadlineMs: 0,                 // 0 = no auto-end: the alarm only stops when SOLVED
      theme: cfg.theme,
      user: cfg.user || '',
      speak: speak,
      unlock: onSolved,              // <- the seam: solved => silence the alarm
      engineGone: function () { return false; },  // the page IS the engine here
      closeWin: function () {}       // never close; stay on the victory screen
    });
    speak(C.pick(C.LINES.start), true);
    startNag();
  }

  function onSolved() {
    if (state === 'solved') return;
    dlog('SOLVED -> alarm silenced');
    state = 'solved';
    stopAlarm(); stopNag();
    if (cfg.repeat) {
      // silently re-arm for tomorrow; the engine keeps showing its victory screen
      targetMs = nextOccurrence(cfg.time);
      state = 'armed';
      if (pollTimer) clearInterval(pollTimer);
      pollTimer = setInterval(tick, 250);
    } else {
      setTimeout(releaseWake, 60000);
    }
  }

  function testSound(seconds) { primeAudio(); startAlarm(); setTimeout(stopAlarm, (seconds || 5) * 1000); }
  function testRing() {
    primeAudio(); acquireWake();
    state = 'armed'; targetMs = Date.now() + 1200;  // fire in ~1.2s, full real flow
    if (pollTimer) clearInterval(pollTimer);
    pollTimer = setInterval(tick, 200);
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
    if (state === 'armed' || state === 'ringing') acquireWake();   // iOS released it on hide
    if (state === 'armed') tick();                                  // catch up immediately if we slept past target
    if (state === 'ringing') { ensureAlarm(); speak(C.pick(C.LINES.nag), true); }
  });
  window.addEventListener('pageshow', function () { if (state === 'ringing') ensureAlarm(); });
  window.addEventListener('focus', function () { if (state === 'ringing') ensureAlarm(); });
  window.addEventListener('beforeunload', function (e) {
    if (state === 'ringing' || state === 'armed') { e.preventDefault(); e.returnValue = ''; return ''; }
  });
  document.addEventListener('touchstart', function () { if (state === 'ringing') ensureAlarm(); }, { passive: true });

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

  function renderSetup() {
    var r = root(); r.innerHTML = '';
    var brand = document.createElement('div'); brand.className = 'brandrow';
    brand.innerHTML = '<div class="logo">OVERRIDE</div><div class="tag">WAKE PROTOCOL // v9.1 - iPhone</div>';
    r.appendChild(brand);

    var c1 = document.createElement('div'); c1.className = 'card';
    c1.innerHTML = '<h2>ALARM TIME</h2><div class="timewrap"><input type="time" id="tIn" value="' + cfg.time + '"></div>';
    r.appendChild(c1);
    c1.querySelector('#tIn').addEventListener('change', function (e) { cfg.time = e.target.value || '07:00'; saveCfg(); });

    var c2 = document.createElement('div'); c2.className = 'card';
    c2.innerHTML = '<h2>QUIZ</h2>';
    var rowD = document.createElement('div'); rowD.className = 'row'; rowD.innerHTML = '<label>difficulty</label>'; c2.appendChild(rowD);
    chips(rowD, [['easy', 'easy'], ['medium', 'medium'], ['hard', 'hard']], function (k) { return cfg.difficulty === k; }, function (k) { cfg.difficulty = k; saveCfg(); renderSetup(); });
    var rowN = document.createElement('div'); rowN.className = 'row'; rowN.innerHTML = '<label>questions to solve</label>'; c2.appendChild(rowN);
    chips(rowN, [['1', '1'], ['2', '2'], ['3', '3'], ['4', '4'], ['5', '5']], function (k) { return String(cfg.numQuestions) === k; }, function (k) { cfg.numQuestions = parseInt(k, 10); saveCfg(); renderSetup(); });
    var rowT = document.createElement('div'); rowT.className = 'row'; rowT.innerHTML = '<label>theme</label>'; c2.appendChild(rowT);
    chips(rowT, [['red', 'red'], ['green', 'green'], ['cyber', 'cyber'], ['crt', 'crt']], function (k) { return cfg.theme === k; }, function (k) { cfg.theme = k; saveCfg(); renderSetup(); });
    var subLbl = document.createElement('div'); subLbl.className = 'row'; subLbl.innerHTML = '<label>subjects</label>'; c2.appendChild(subLbl);
    var subWrap = document.createElement('div'); c2.appendChild(subWrap);
    chips(subWrap, SUBJECTS, function (k) { return !!cfg.cats[k]; }, function (k) {
      cfg.cats[k] = !cfg.cats[k];
      var any = false, kk; for (kk in cfg.cats) { if (cfg.cats[kk]) any = true; }
      if (!any) cfg.cats.arithmetic = true;
      saveCfg(); renderSetup();
    });
    r.appendChild(c2);

    var c3 = document.createElement('div'); c3.className = 'card';
    var armBtn = document.createElement('button'); armBtn.className = 'btn arm'; armBtn.textContent = 'ARM ALARM';
    armBtn.addEventListener('click', arm); c3.appendChild(armBtn);
    var t1 = document.createElement('button'); t1.className = 'btn ghost'; t1.textContent = 'TEST SOUND (5s)';
    t1.addEventListener('click', function () { testSound(5); }); c3.appendChild(t1);
    var t2 = document.createElement('button'); t2.className = 'btn ghost'; t2.textContent = 'TEST FULL ALARM (rings in ~1s)';
    t2.addEventListener('click', testRing); c3.appendChild(t2);
    var t3 = document.createElement('button'); t3.className = 'btn ghost'; t3.textContent = 'DIAGNOSTICS LOG';
    t3.addEventListener('click', showDiag); c3.appendChild(t3);
    r.appendChild(c3);

    var c4 = document.createElement('div'); c4.className = 'card';
    c4.innerHTML = '<h2>BEFORE YOU SLEEP - do these once (iPhone)</h2><ul class="check">' +
      '<li><span class="k">1.</span> <b>Add to Home Screen</b> (Share &gt; Add to Home Screen), then open it from the icon.</li>' +
      '<li><span class="k">2.</span> Flip the <b>side switch to RING</b> (no orange), and turn <b>Volume UP</b>.</li>' +
      '<li><span class="k">3.</span> Settings &gt; Display &amp; Brightness &gt; <b>Auto-Lock = Never</b> (critical - if the screen locks, iOS freezes the alarm).</li>' +
      '<li><span class="k">4.</span> <b>Plug it in</b>, and turn <b>Low Power Mode OFF</b>.</li>' +
      '<li><span class="k">5.</span> Tap <b>ARM</b>, leave this open. Don&#39;t switch apps or lock the screen.</li>' +
      '<li><span class="k">6.</span> <b>Failsafe:</b> set a normal <b>Clock app alarm</b> at the same time too.</li></ul>';
    r.appendChild(c4);

    var note = document.createElement('div'); note.className = 'note';
    note.innerHTML = 'honest limit: a website can&#39;t lock iPhone like a real app - it stays loud &amp; quiz-gated, but keep it open &amp; foreground (do not lock the screen).';
    r.appendChild(note);
  }

  function renderArmed() {
    var r = root(); r.innerHTML = '';
    var cd = document.createElement('div'); cd.className = 'cd';
    cd.innerHTML =
      '<div class="lbl">ALARM ARMED</div>' +
      '<div class="time">wake at ' + cfg.time + (cfg.repeat ? ' - daily' : '') + '</div>' +
      '<div class="num" id="cdNum">--</div>' +
      '<div class="sub" id="cdHb" style="margin-bottom:8px">...</div>' +
      '<div class="sub"><span class="warn">Screen must stay ON (do not let it lock) &amp; the iPhone plugged in.</span><br>' +
      'If the ● above stops blinking, iOS froze the page - tap the screen to wake it.<br>' +
      'When it fires you must solve ' + cfg.numQuestions + ' question' + (cfg.numQuestions === 1 ? '' : 's') + ' to silence it.</div>';
    r.appendChild(cd);
    var dis = document.createElement('button'); dis.className = 'btn ghost'; dis.style.maxWidth = '320px';
    dis.textContent = 'DISARM'; dis.addEventListener('click', disarm); cd.appendChild(dis);
    tick();
  }

  /* --------------------------- service worker ------------------------- */
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', function () { navigator.serviceWorker.register('sw.js').catch(function () {}); });
  }

  /* ------------------------------- boot ------------------------------- */
  dlog('app loaded (' + (window.navigator.standalone ? 'home-screen PWA' : 'browser tab') + ')');
  renderSetup();
})();
