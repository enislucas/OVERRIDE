# OVERRIDE v3 — idea log (NOT built; captured for later)

Logged at the user's request on 2026-06-08. These are concepts only. Each has a feasibility
and a privacy/ethics note, because they involve the camera and personal/religious activity.

## Guiding shift
v1/v2 prove wakefulness with **math**. v3 explores proving wakefulness with a **real-world
action** — getting up and doing something — which is much harder to fake while half-asleep.

---

## Idea 1 — Photo of wudu to stop the alarm (instead of math)
Stop the alarm by submitting a photo of yourself making **wudu** (ablution).

- **Flow:** alarm rings → camera capture UI → you take the photo → app accepts → alarm stops.
- **Feasibility:** capture is trivial (Windows camera APIs / a WinForms+MediaCapture or a small
  HTML getUserMedia page). "Is this actually wudu?" requires a vision model — doable via a local
  model or a cloud vision API, but reliability/false-rejection at 3am is the real risk.
- **Anti-cheat:** must avoid accepting an old saved photo (see metadata note in Idea 3).
- **Privacy/ethics (important):** this is a photo of the user + a religious act. Strong default
  to **on-device** processing, no upload, no retention beyond the check, explicit consent, and a
  fallback (e.g., math) if the camera/model fails so you're never trapped awake-but-locked.

## Idea 2 — Interactive "show me 5 things" video check
A short interactive video session where the app asks you to **show 5 specific things from around
the house** (e.g., "show the kitchen sink", "show a green object"), proving you physically moved.

- **Flow:** alarm rings → live camera prompt → app names items one by one → vision model confirms
  each → after 5 confirmations the alarm stops.
- **Feasibility:** needs live frames + a vision model doing object/scene checks; prompt list can be
  randomized so it can't be pre-recorded. Heavier than Idea 1; latency and false-negatives matter.
- **Privacy/ethics:** live home video — on-device strongly preferred; randomization helps anti-cheat;
  always keep a safety fallback.

## Idea 3 — Tiered: math to dim, then verified wudu video
A graduated escalation:
1. Solve **1 math question** → lowers the alarm volume for **3 minutes** of grace.
2. Within that window, submit a **video of making wudu**.
3. App **analyzes the video + its metadata** (timestamp, and optionally location) to check the
   clip is **fresh/sincere**, not a replay.

- **Feasibility:** the tiered logic is easy. Volume dimming reuses the existing volume control.
  Video capture is fine. "Analyze for sincerity" = vision model (is this wudu?) + metadata checks
  (EXIF/container `CreationTime` within the last few minutes; GPS if you opt in).
- **Honest limitation on metadata "sincerity":** capture timestamps/EXIF are **spoofable** by a
  determined user, and absent on some capture paths. The robust anti-replay signal is to have the
  **app itself capture live** (so it controls the timestamp) rather than trusting a supplied file.
  Frame liveness (movement, a spoken/random nonce shown on screen) beats metadata alone.
- **Privacy/ethics:** most sensitive of the three (video + religious act + possibly location).
  On-device only by default; capture-and-discard; explicit opt-in for any location use; never
  upload without clear consent; always a fallback so a camera failure can't strand you.

---

## Cross-cutting notes for whoever builds v3
- Keep v2's guarantees: **0 CPU idle**, **no crash/respawn**, **3-min hard cap**, and a **fallback**
  unlock path so a failed camera/model never locks the user out (especially while half-asleep).
- Prefer **local/on-device** vision; if a cloud model is ever used, get explicit per-use consent.
- Anti-cheat that actually works: **app-controlled live capture + on-screen random nonce**, not
  trusting user-supplied files or metadata.
- Decide the data policy up front: capture → check → **discard** by default.
