#!/usr/bin/env bash
# OVERRIDE v10 // WAKE PROTOCOL — macOS / Linux engine (THEMED, shares quiz with v10/web)
# =====================================================================================
# STATUS: written + syntax-checked on Windows (bash -n). NOT yet run on real Mac/Linux
# hardware. Treat the FIRST run as a SUPERVISED TEST — you awake and watching:
#     ./override.sh test        (45s ring: browser quiz + sound + narrator)
# =====================================================================================
# Architecture (identical philosophy to the Windows engine): 0% CPU between alarms.
#   - Alarms are NATIVE scheduler entries, written by `arm`:
#       * macOS: launchd user agents  ~/Library/LaunchAgents/com.override.v10.<id>.plist
#       * Linux: systemd --user timers (override-v10-<id>.timer)  OR  a crontab line
#         tagged '# OVERRIDE_V10 <id>' when no user-systemd is available.
#   - At fire time ONE ephemeral `ring` process runs and exits when solved/expired:
#       * a tiny localhost listener (python3) on the first free port 8741-8749 that
#         serves a real 1x1 GIF to every /beat, writes UNLOCK on /unlock?key=<match>,
#         and records the soften volume target (session.vol) on /vol?level=N;
#       * a looping alarm sound (afplay on mac; paplay/aplay/ffplay on linux; a spoken
#         "klaxon" if no sound files exist) from ../sounds or ../../v3/sounds;
#       * the shared quiz (quiz/quiz.html) opened in a Chrome/Chromium KIOSK window
#         (its OWN --user-data-dir so we NEVER touch your real browser profile);
#       * the narrator (`say` on mac, `spd-say`/`espeak` on linux) at start + nags.
#   - Ends on UNLOCK (correct key) OR the per-alarm deadline (durationMin) OR a PANIC
#     file (the escape hatch — `touch ../PANIC` from any terminal kills the ring).
#
# HONEST LIMITS (documented, not hidden):
#   - No keyboard lockdown. An unprivileged process cannot block Cmd-Tab / the app
#     switcher / power button. The ring stays loud + fullscreen + quiz-gated, but a
#     determined human can leave it. "Force yourself", not a true kiosk lock.
#   - Waking the machine FROM SLEEP needs `sudo pmset schedule` (mac) / `rtcwake`
#     (linux) — that is a SEPARATE helper: ./wake.sh   (see README). launchd/systemd
#     timers fire fine when only the DISPLAY is asleep (lid open, plugged in).
#   - REQUIRES python3 (config parsing + the unlock/heartbeat listener). jq is NOT
#     assumed. If python3 is missing the engine fails loudly with install hints.
#
# Safety invariants (mirrored from the Windows engine / v3 MAINTENANCE):
#   - The alarm must fire no matter what (bad config -> built-in defaults).
#   - NEVER rm -rf anything outside the project dir. Session files live in ../ (v10/).
#   - Lockdown/volume changes ALWAYS release on exit (trap cleanup).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"                 # v10 root: config.json + session files live here
CFG="$ROOT/config.json"
QUIZ="$ROOT/quiz/quiz.html"
OS="$(uname -s)"                          # Darwin | Linux
PORT_LO=8741; PORT_HI=8749
KIOSK_PROFILE="$ROOT/session.kioskprofile"   # dedicated Chrome profile so we never touch the real one
KIOSK_TAG="session.kioskprofile"             # unique substring for targeted pkill

py() { python3 "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }

if ! have python3; then
  die "python3 is required (JSON config parsing + the localhost unlock listener).
       Install it, then re-run:
         macOS  : it ships with the Xcode CLI tools -> xcode-select --install   (or: brew install python3)
         Debian : sudo apt install python3
         Fedora : sudo dnf install python3
       jq is NOT used — only python3."
fi

# ---------- config helpers (python3 does ALL the JSON; jq not assumed) ----------
# Field order emitted: label|time|date|rhythm|enabled|diff|nq|durmin|narrator|rain|theme|soften|cats_csv
cfg_get_alarm() {  # $1 = alarm id
  py - "$CFG" "$1" <<'PYEOF'
import json,sys,os
cfg={}
try:
    if os.path.exists(sys.argv[1]): cfg=json.load(open(sys.argv[1],encoding="utf-8-sig"))
except Exception: cfg={}
d=cfg.get("defaults",{}) if isinstance(cfg,dict) else {}
a=next((x for x in cfg.get("alarms",[]) if x.get("id")==sys.argv[2]), {}) if isinstance(cfg,dict) else {}
def g(k,dv): return a.get(k, d.get(k, dv))
cats=g("categories",{"arithmetic":True}) or {}
csv=",".join(k for k,v in cats.items() if v) or "arithmetic"
print("|".join(str(x) for x in [
  a.get("label","WAKE UP"), a.get("time","07:00"), a.get("date",""),
  int(bool(a.get("rhythm",False))), int(bool(a.get("enabled",True))),
  g("difficulty","hard"), g("numQuestions",3), g("durationMin",3),
  int(bool(g("narrator",True))), int(bool(g("matrixRain",True))),
  g("theme","green"), int(bool(g("softenVolume",False))), csv]))
PYEOF
}
# id|time|rhythm|enabled for every alarm (used by arm/status)
cfg_each() {
  py - "$CFG" <<'PYEOF'
import json,sys,os
try: cfg=json.load(open(sys.argv[1],encoding="utf-8-sig"))
except Exception: raise SystemExit
for a in cfg.get("alarms",[]):
    print("|".join([a.get("id","x"), a.get("time","07:00"),
      str(int(bool(a.get("rhythm",False)))), str(int(bool(a.get("enabled",True))))]))
PYEOF
}
cfg_list() {
  py - "$CFG" <<'PYEOF'
import json,sys,os
if not os.path.exists(sys.argv[1]):
    print("(no config.json in this folder yet — create alarms on Windows, or hand-write one)"); raise SystemExit
try: cfg=json.load(open(sys.argv[1],encoding="utf-8-sig"))
except Exception:
    print("(config.json is present but unreadable — the ring still falls back to defaults)"); raise SystemExit
al=cfg.get("alarms",[])
if not al: print("(config.json has no alarms yet)"); raise SystemExit
for a in al:
    print("  %-9s %-5s %-11s %-4s %s" % (a.get("id","?"), a.get("time","?"),
        ("daily" if a.get("rhythm") else (a.get("date") or "next")),
        ("ON" if a.get("enabled",True) else "off"), a.get("label","")))
PYEOF
}

urlenc() { py -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
file_uri() { py -c 'import sys,pathlib;print(pathlib.Path(sys.argv[1]).resolve().as_uri())' "$1"; }

# ---------- localhost listener (python3): serves GIF, catches /unlock + /vol ----------
# Binds the first free port in 8741-8749 and writes it to session.port so the ring can
# build the quiz URL. A REAL 43-byte 1x1 GIF is returned to every request so the browser
# <img> beacon fires onload (a bare "GIF89a" string fails to decode -> the quiz would
# wrongly conclude "engine gone" and close itself early). Runs as a child; killed on cleanup.
start_listener() {  # $1 = unlock key ; sets global PORT
  rm -f "$ROOT/session.port"
  py - "$1" "$ROOT" "$PORT_LO" "$PORT_HI" <<'PYEOF' &
import sys,os,http.server,socketserver,urllib.parse
key,root=sys.argv[1],sys.argv[2]; lo,hi=int(sys.argv[3]),int(sys.argv[4])
GIF=bytes([0x47,0x49,0x46,0x38,0x39,0x61,0x01,0x00,0x01,0x00,0x80,0x00,0x00,0x00,0x00,0x00,
           0xFF,0xFF,0xFF,0x21,0xF9,0x04,0x01,0x00,0x00,0x00,0x00,0x2C,0x00,0x00,0x00,0x00,
           0x01,0x00,0x01,0x00,0x00,0x02,0x02,0x44,0x01,0x00,0x3B])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query)
        try:
            if u.path=="/unlock" and q.get("key",[""])[0]==key:
                open(os.path.join(root,"UNLOCK"),"w").write(key)
            elif u.path=="/vol":
                lv=q.get("level",[""])[0]
                if lv.isdigit():
                    open(os.path.join(root,"session.vol"),"w").write(str(max(0,min(100,int(lv)))))
        except Exception: pass
        try:
            self.send_response(200); self.send_header("Content-Type","image/gif")
            self.send_header("Access-Control-Allow-Origin","*")
            self.send_header("Content-Length",str(len(GIF))); self.end_headers()
            self.wfile.write(GIF)
        except Exception: pass
socketserver.TCPServer.allow_reuse_address=True
srv=None
for p in range(lo,hi+1):
    try:
        srv=socketserver.TCPServer(("127.0.0.1",p),H)
        open(os.path.join(root,"session.port"),"w").write(str(p)); break
    except Exception: srv=None
if srv:
    try: srv.serve_forever()
    except Exception: pass
PYEOF
  LISTENER_PID=$!
  # wait (<=3s) for the child to publish its chosen port
  PORT=""; local i=0
  while [ "$i" -lt 30 ]; do
    if [ -f "$ROOT/session.port" ]; then
      PORT="$(cat "$ROOT/session.port" 2>/dev/null)"
      [ -n "$PORT" ] && break
    fi
    sleep 0.1; i=$((i+1))
  done
  [ -n "$PORT" ] || PORT="$PORT_LO"
}

# ---------- kiosk browser ----------
open_quiz() {  # $1 = url — Chrome/Chromium kiosk with an ISOLATED profile; graceful fallbacks
  if [ "$OS" = "Darwin" ]; then
    if [ -d "/Applications/Google Chrome.app" ]; then
      open -na "Google Chrome" --args \
        --user-data-dir="$KIOSK_PROFILE" --kiosk --noerrdialogs \
        --disable-session-crashed-bubble --no-first-run \
        --autoplay-policy=no-user-gesture-required "$1" && return
    fi
    # Safari has no kiosk flag reachable via `open`; it opens a normal window (still shows the quiz)
    open -a Safari "$1" 2>/dev/null && return
    open "$1"
  else
    local b
    for b in google-chrome google-chrome-stable chromium chromium-browser brave-browser microsoft-edge; do
      if have "$b"; then
        "$b" --user-data-dir="$KIOSK_PROFILE" --kiosk --noerrdialogs \
             --disable-session-crashed-bubble --no-first-run \
             --autoplay-policy=no-user-gesture-required "$1" >/dev/null 2>&1 &
        return
      fi
    done
    if have firefox; then firefox --kiosk "$1" >/dev/null 2>&1 & return; fi
    have xdg-open && { xdg-open "$1" >/dev/null 2>&1 & }
  fi
}

# ---------- sound ----------
pick_sound_dir() {  # first dir that actually has *.wav
  local d
  for d in "$ROOT/sounds" "$(dirname "$ROOT")/v3/sounds" "$(dirname "$ROOT")/v2/sounds"; do
    if [ -d "$d" ] && ls "$d"/*.wav >/dev/null 2>&1; then echo "$d"; return; fi
  done
  echo ""
}
sound_loop() {  # background: cycle the wavs forever; spoken klaxon if none exist
  local dir f; dir="$(pick_sound_dir)"
  while :; do
    if [ -n "$dir" ]; then
      for f in "$dir"/*.wav; do
        if   [ "$OS" = "Darwin" ]; then afplay "$f" 2>/dev/null
        elif have paplay;  then paplay "$f" 2>/dev/null
        elif have aplay;   then aplay -q "$f" 2>/dev/null
        elif have ffplay;  then ffplay -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null
        elif have play;    then play -q "$f" 2>/dev/null
        else narrate "WAKE UP. WAKE UP. WAKE UP."; sleep 2; fi
      done
    else
      narrate "WAKE UP. WAKE UP. WAKE UP."; sleep 2
    fi
  done
}

# ---------- narrator ----------
narrate() {  # one spoken line (best-effort; silently no-ops if no TTS is installed)
  if [ "$OS" = "Darwin" ]; then
    have say && say "$1" 2>/dev/null
  else
    if   have spd-say;   then spd-say -w "$1" 2>/dev/null
    elif have espeak-ng; then espeak-ng "$1" 2>/dev/null
    elif have espeak;    then espeak "$1" 2>/dev/null
    fi
  fi
}
NAGS=(
  "Solve it. Wake up." "Still horizontal? Pathetic." "Your blanket will not save you."
  "The snooze button does not exist. I made sure of it." "Coffee is on the other side of this quiz."
  "I can do this all morning." "Math now. Existential dread later." "You installed me. Think about that."
  "The bed is lava. The bed has always been lava." "I believe in you. Unfortunately for you."
  "Day not seized detected. Deploying countermeasures." "Your pillow is lying to you.")

# ---------- system volume ----------
get_volume() {  # echo current output volume 0-100 (empty if unknown)
  if [ "$OS" = "Darwin" ]; then
    osascript -e 'output volume of (get volume settings)' 2>/dev/null
  elif have pactl; then
    pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -o '[0-9]\+%' | head -n1 | tr -d '%'
  elif have amixer; then
    amixer get Master 2>/dev/null | grep -o '[0-9]\+%' | head -n1 | tr -d '%'
  fi
}
set_volume() {  # $1 = 0-100 (clamped; sane default 70 if garbage)
  local n="${1:-70}"
  case "$n" in ''|*[!0-9]*) n=70 ;; esac
  [ "$n" -gt 100 ] && n=100
  if [ "$OS" = "Darwin" ]; then
    osascript -e "set volume output volume $n" 2>/dev/null
  elif have pactl; then
    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null
    pactl set-sink-volume @DEFAULT_SINK@ "${n}%" 2>/dev/null
  elif have amixer; then
    amixer set Master "${n}%" unmute >/dev/null 2>&1
  fi
}
force_volume_max() {  # keep the alarm audible when NOT softening
  if [ "$OS" = "Darwin" ]; then
    osascript -e "set volume output volume 100" -e "set volume without output muted" 2>/dev/null
  elif have pactl; then
    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null
    pactl set-sink-volume @DEFAULT_SINK@ 100% 2>/dev/null
  elif have amixer; then
    amixer set Master 100% unmute >/dev/null 2>&1
  fi
}

# ---------- cleanup (ALWAYS runs via trap) ----------
cleanup() {
  [ -n "${SOUND_PID:-}" ]    && kill "$SOUND_PID"    2>/dev/null
  [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null
  [ -n "${CAFF_PID:-}" ]     && kill "$CAFF_PID"     2>/dev/null
  # stop only OUR kiosk (matched by the unique profile path) + our sound players
  if have pkill; then
    pkill -f "$KIOSK_TAG" 2>/dev/null
    for s in afplay paplay aplay ffplay play; do pkill -x "$s" 2>/dev/null; done
  fi
  # restore audio to where it was (or a sane 70% if we never learned the original)
  set_volume "${ORIG_VOL:-70}"
  # session files live INSIDE the project dir — never touch anything outside it
  rm -f "$ROOT/UNLOCK" "$ROOT/PANIC" "$ROOT/session.vol" "$ROOT/session.port"
  rmdir "$ROOT/.ring.lock" 2>/dev/null
}

# ---------- ring ----------
ring() {  # $1 = alarm id | "TEST"
  local id="$1"
  local label time date rhythm enabled diff nq durmin narrator rain theme soften cats
  local dl_sec
  if [ "$id" = "TEST" ]; then
    label="TEST"; time=""; date=""; rhythm=0; enabled=1; diff="hard"; nq=3; durmin=1
    narrator=1; rain=1; theme="green"; soften=0; cats="arithmetic"; dl_sec=45
  else
    IFS='|' read -r label time date rhythm enabled diff nq durmin narrator rain theme soften cats \
      < <(cfg_get_alarm "$id")
    [ "${enabled:-1}" = "1" ] || exit 0
    # one-time dated alarm: the launchd/systemd trigger fires daily, so guard the date here
    if [ -n "${date:-}" ] && [ "${rhythm:-0}" = "0" ] && [ "$date" != "$(date +%F)" ]; then exit 0; fi
    dl_sec=$(( durmin * 60 )); [ "$dl_sec" -lt 5 ] && dl_sec=5
  fi

  # single instance (mkdir is atomic) — a second trigger while one rings is a no-op
  local lock="$ROOT/.ring.lock"
  mkdir "$lock" 2>/dev/null || exit 0
  trap 'cleanup' EXIT INT TERM

  rm -f "$ROOT/UNLOCK" "$ROOT/PANIC" "$ROOT/session.vol"
  ORIG_VOL="$(get_volume)"                # remember to restore on exit
  local key; key="$( (uuidgen 2>/dev/null || echo "k$$$RANDOM$RANDOM") | tr -d '-' )"
  local deadline=$(( $(date +%s) + dl_sec ))
  local dlms=$(( deadline * 1000 ))

  start_listener "$key"                   # sets $PORT
  # keep the DISPLAY awake during the ring (mac); harmless if absent
  if [ "$OS" = "Darwin" ] && have caffeinate; then caffeinate -d -t "$dl_sec" & CAFF_PID=$!; fi

  local user="${USER:-$(id -un 2>/dev/null)}"
  local uri; uri="$(file_uri "$QUIZ")"
  local url="$uri?key=$key&port=$PORT&label=$(urlenc "$label")&n=$nq&diff=$diff&cats=$cats"
  url="$url&rain=$rain&deadline=$dlms&theme=$theme&soften=$soften&user=$(urlenc "$user")"
  open_quiz "$url"

  sound_loop & SOUND_PID=$!
  [ "${narrator:-1}" = "1" ] && narrate "Wake up. Solve to disable the alarm." &

  local nag_at=$(( $(date +%s) + 20 ))
  while :; do
    local now; now="$(date +%s)"
    [ -f "$ROOT/UNLOCK" ] && [ "$(cat "$ROOT/UNLOCK" 2>/dev/null)" = "$key" ] && break
    [ -f "$ROOT/PANIC" ] && break
    [ "$now" -ge "$deadline" ] && break
    if [ "${soften:-0}" = "1" ]; then
      # decreasing-sound: the quiz beacons a target to /vol -> listener writes session.vol
      local vt=100
      [ -f "$ROOT/session.vol" ] && vt="$(cat "$ROOT/session.vol" 2>/dev/null)"
      case "$vt" in ''|*[!0-9]*) vt=100 ;; esac
      set_volume "$vt"
    else
      force_volume_max
    fi
    if [ "${narrator:-1}" = "1" ] && [ "$now" -ge "$nag_at" ]; then
      narrate "${NAGS[$((RANDOM % ${#NAGS[@]}))]}" &
      nag_at=$(( now + 22 ))
    fi
    sleep 2
  done

  # one-time dated alarm fired -> disable it so tomorrow's daily trigger stays quiet
  if [ "$id" != "TEST" ] && [ -n "${date:-}" ] && [ "${rhythm:-0}" = "0" ]; then
    py - "$CFG" "$id" <<'PYEOF' 2>/dev/null || true
import json,sys
cfg=json.load(open(sys.argv[1],encoding="utf-8-sig"))
for a in cfg.get("alarms",[]):
    if a.get("id")==sys.argv[2]: a["enabled"]=False
json.dump(cfg,open(sys.argv[1],"w",encoding="utf-8"),indent=2)
PYEOF
  fi
}

# ---------- arming ----------
have_user_systemd() { have systemctl && systemctl --user list-units >/dev/null 2>&1; }

arm() {
  [ -f "$CFG" ] || die "no config.json in $ROOT (create alarms on Windows, or hand-write one)."
  disarm quiet
  local count=0 id time rhythm enabled hh mm
  while IFS='|' read -r id time rhythm enabled; do
    [ "$enabled" = "1" ] || continue
    hh="${time%%:*}"; mm="${time##*:}"
    if [ "$OS" = "Darwin" ]; then
      local plist="$HOME/Library/LaunchAgents/com.override.v10.$id.plist"
      mkdir -p "$HOME/Library/LaunchAgents"
      cat > "$plist" <<PLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.override.v10.$id</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$HERE/override.sh</string><string>ring</string><string>$id</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$((10#$hh))</integer><key>Minute</key><integer>$((10#$mm))</integer>
  </dict>
</dict></plist>
PLEOF
      launchctl unload "$plist" 2>/dev/null
      launchctl load "$plist" 2>/dev/null || echo "  launchctl load failed for $id"
      echo "  armed  $id  daily $time  (launchd)"
    elif have_user_systemd; then
      local sysd="$HOME/.config/systemd/user"; mkdir -p "$sysd"
      cat > "$sysd/override-v10-$id.service" <<SVEOF
[Unit]
Description=OVERRIDE v10 alarm $id
[Service]
Type=oneshot
ExecStart=/bin/bash $HERE/override.sh ring $id
SVEOF
      cat > "$sysd/override-v10-$id.timer" <<TMEOF
[Unit]
Description=OVERRIDE v10 alarm $id timer
[Timer]
OnCalendar=*-*-* $hh:$mm:00
Persistent=false
[Install]
WantedBy=timers.target
TMEOF
      systemctl --user daemon-reload 2>/dev/null
      systemctl --user enable --now "override-v10-$id.timer" 2>/dev/null || echo "  systemd enable failed for $id"
      echo "  armed  $id  daily $time  (systemd --user timer)"
    elif have crontab; then
      local line="$mm $hh * * * /bin/bash '$HERE/override.sh' ring $id # OVERRIDE_V10 $id"
      ( crontab -l 2>/dev/null | grep -v "# OVERRIDE_V10 $id\$"; echo "$line" ) | crontab -
      echo "  armed  $id  daily $time  (crontab)"
    else
      echo "  NO scheduler available for $id (need launchd, systemd --user, or crontab)"
    fi
    count=$((count+1))
  done < <(cfg_each)
  echo "$count alarm(s) armed."
  echo "NOTE: one-time dated alarms fire daily but self-guard by date inside the ring."
  echo "NOTE: waking from full SLEEP needs ./wake.sh (sudo, one-time) — timers alone only"
  echo "      fire when the machine is awake or merely display-asleep."
}

disarm() {
  local quiet="${1:-}"
  if [ "$OS" = "Darwin" ]; then
    local p
    for p in "$HOME"/Library/LaunchAgents/com.override.v10.*.plist; do
      [ -e "$p" ] || continue
      launchctl unload "$p" 2>/dev/null; rm -f "$p"
      [ "$quiet" = "quiet" ] || echo "  removed $(basename "$p")"
    done
  else
    local t unit
    if have_user_systemd; then
      for t in "$HOME"/.config/systemd/user/override-v10-*.timer; do
        [ -e "$t" ] || continue
        unit="$(basename "$t")"
        systemctl --user disable --now "$unit" 2>/dev/null
        rm -f "$t" "${t%.timer}.service"
        [ "$quiet" = "quiet" ] || echo "  removed $unit"
      done
      systemctl --user daemon-reload 2>/dev/null
    fi
    if have crontab && crontab -l 2>/dev/null | grep -q '# OVERRIDE_V10'; then
      crontab -l 2>/dev/null | grep -v '# OVERRIDE_V10' | crontab -
      [ "$quiet" = "quiet" ] || echo "  removed OVERRIDE_V10 crontab lines"
    fi
  fi
  [ "$quiet" = "quiet" ] || echo "disarmed."
}

# ---------- status ----------
status() {
  echo "config: $CFG"
  cfg_list
  echo "--- armed ---"
  if [ "$OS" = "Darwin" ]; then
    ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep 'com.override.v10' || echo "  (nothing armed via launchd)"
  else
    if have_user_systemd; then
      systemctl --user list-timers 'override-v10-*' --no-pager 2>/dev/null | grep -i override-v10 \
        || echo "  (no systemd --user timers)"
    fi
    if have crontab; then
      crontab -l 2>/dev/null | grep '# OVERRIDE_V10' || echo "  (no OVERRIDE_V10 crontab lines)"
    fi
  fi
  echo "--- deep-sleep wake --- run ./wake.sh to schedule hardware wake (sudo)."
}

# ---------- install ----------
install() {
  chmod +x "$HERE/override.sh" 2>/dev/null && echo "  chmod +x override.sh"
  [ -f "$HERE/wake.sh" ] && { chmod +x "$HERE/wake.sh" 2>/dev/null && echo "  chmod +x wake.sh"; }
  echo "Installed the OVERRIDE v10 engine in: $HERE"
  echo "Quiz         : $QUIZ  $( [ -f "$QUIZ" ] && echo '(found)' || echo '(MISSING!)')"
  echo "Config       : $CFG  $( [ -f "$CFG" ] && echo '(found)' || echo '(none yet — arm will refuse until one exists)')"
  echo "python3      : $(command -v python3)"
  echo "Sound dir    : $(pick_sound_dir 2>/dev/null || echo '(none — will speak a klaxon)')"
  echo
  echo "Next:"
  echo "  ./override.sh test     # SUPERVISED 45s test ring (do this first, awake)"
  echo "  ./override.sh arm      # arm every enabled alarm in ../config.json"
  echo "  ./override.sh status   # show alarms + what is armed"
  echo "  ./wake.sh              # (sudo) wake the machine from sleep before each alarm"
  echo "  ./override.sh disarm   # rollback: remove all OVERRIDE timers/agents"
}

case "${1:-help}" in
  ring)    ring "${2:-TEST}" ;;
  test)    ring TEST ;;
  arm)     arm ;;
  disarm)  disarm ;;
  status)  status ;;
  install) install ;;
  *) cat <<USEOF
OVERRIDE v10 (macOS / Linux) — usage:
  ./override.sh test         SUPERVISED 45s test ring (browser quiz + sound + narrator)
  ./override.sh ring <id>    fire one alarm now (what the scheduler calls)
  ./override.sh arm          arm every enabled alarm in ../config.json
  ./override.sh disarm       remove all OVERRIDE timers/agents (rollback)
  ./override.sh status       show configured alarms + what is armed
  ./override.sh install      chmod +x + print what was found / next steps
Deep-sleep wake (sudo, separate helper):  ./wake.sh
Escape hatch while ringing:  touch ../PANIC
USEOF
  ;;
esac
