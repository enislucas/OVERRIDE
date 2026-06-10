#!/usr/bin/env bash
# OVERRIDE v3 // WAKE PROTOCOL — macOS / Linux engine
# =====================================================================
# STATUS: written + syntax-checked on Windows (bash -n); NOT yet run on a
# real Mac/Linux box. Treat the first run as a supervised test:
#   ./override.sh test        (45s ring, you are awake and watching)
# =====================================================================
# Same architecture as Windows: 0 CPU between alarms.
#   - macOS: launchd user agents (~/Library/LaunchAgents/com.override.v3.*)
#   - Linux: systemd --user timers (override-v3-*.timer)
#   - At fire time ONE ephemeral ring process runs: sound loop + narrator
#     (`say` / espeak-ng) + the shared quiz (quiz/quiz.html) in a browser
#     kiosk window + a tiny localhost listener for SOLVED/heartbeat.
# Honest limits vs Windows (documented, not hidden):
#   - waking the machine FROM SLEEP needs `sudo pmset schedule` (mac) or
#     rtcwake (linux) -> not done automatically. Keep the lid open / display
#     sleep only, or run `./override.sh wake-help`.
#   - no keyboard lockdown (no low-level hooks for unprivileged processes);
#     the ring RELAUNCHES the quiz if you close it, until solve/deadline.
# Requires: bash, python3 (config parsing + localhost listener).
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"                 # v3 root (config.json, session files)
CFG="$ROOT/config.json"
QUIZ="$ROOT/quiz/quiz.html"
OS="$(uname -s)"                          # Darwin | Linux
PORT_BASE=8741

py() { python3 "$@"; }
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }

[ -x "$(command -v python3)" ] || die "python3 is required (config parsing + unlock listener)"

# ---------- config helpers (python3 does the JSON) ----------
cfg_get_alarm() {  # $1=alarm id -> prints: label|time|date|rhythm|enabled|diff|nq|durmin|narrator|rain|cats_csv
  py - "$CFG" "$1" <<'PYEOF'
import json,sys
cfg=json.load(open(sys.argv[1])) if len(sys.argv)>1 else {}
d=cfg.get("defaults",{})
a=next((x for x in cfg.get("alarms",[]) if x.get("id")==sys.argv[2]), {})
def g(k,dv): return a.get(k, d.get(k, dv))
cats=g("categories",{"arithmetic":True})
csv=",".join(k for k,v in cats.items() if v) or "arithmetic"
print("|".join(str(x) for x in [a.get("label","WAKE UP"),a.get("time","07:00"),a.get("date",""),
  int(bool(a.get("rhythm",False))),int(bool(a.get("enabled",True))),g("difficulty","hard"),
  g("numQuestions",3),g("durationMin",3),int(bool(g("narrator",True))),int(bool(g("matrixRain",False))),csv]))
PYEOF
}
cfg_list() {
  py - "$CFG" <<'PYEOF'
import json,sys,os
if not os.path.exists(sys.argv[1]): print("(no config.json yet — copy one from windows or create alarms there)"); raise SystemExit
cfg=json.load(open(sys.argv[1]))
for a in cfg.get("alarms",[]):
    print("%-9s %-5s %-12s %-8s %s" % (a.get("id","?"), a.get("time","?"),
        ("daily" if a.get("rhythm") else a.get("date","next")),
        ("ON" if a.get("enabled",True) else "off"), a.get("label","")))
PYEOF
}

# ---------- ring ----------
urlenc() { py -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }

start_listener() {  # $1=port $2=key — writes UNLOCK in $ROOT when the right key arrives
  py - "$1" "$2" "$ROOT" <<'PYEOF' &
import sys,http.server,socketserver,urllib.parse,os
port,key,root=int(sys.argv[1]),sys.argv[2],sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_GET(self):
        u=urllib.parse.urlparse(self.path); q=urllib.parse.parse_qs(u.query)
        if u.path=="/unlock" and q.get("key",[""])[0]==key:
            open(os.path.join(root,"UNLOCK"),"w").write(key)
        self.send_response(200); self.send_header("Content-Type","image/gif")
        self.send_header("Access-Control-Allow-Origin","*"); self.end_headers()
        self.wfile.write(b"GIF89a")
socketserver.TCPServer.allow_reuse_address=True
with socketserver.TCPServer(("127.0.0.1",port),H) as s: s.serve_forever()
PYEOF
  LISTENER_PID=$!
}

open_quiz() {  # $1=url — best-effort kiosk; falls back to a normal browser window
  if [ "$OS" = "Darwin" ]; then
    if [ -d "/Applications/Google Chrome.app" ]; then
      open -na "Google Chrome" --args --kiosk --noerrdialogs --disable-session-crashed-bubble "$1" && return
    fi
    open "$1" && return
  else
    for b in google-chrome chromium chromium-browser brave-browser microsoft-edge; do
      if have "$b"; then "$b" --kiosk --noerrdialogs --disable-session-crashed-bubble "$1" >/dev/null 2>&1 & return; fi
    done
    if have firefox; then firefox --kiosk "$1" >/dev/null 2>&1 & return; fi
    have xdg-open && xdg-open "$1" >/dev/null 2>&1 &
  fi
}

pick_sound_dir() {
  for d in "$ROOT/sounds" "$(dirname "$ROOT")/v2/sounds"; do
    if [ -d "$d" ] && ls "$d"/*.wav >/dev/null 2>&1; then echo "$d"; return; fi
  done
  echo ""
}

sound_loop() {  # background: cycle the wavs forever; fallback = spoken klaxon
  local dir; dir="$(pick_sound_dir)"
  while :; do
    if [ -n "$dir" ]; then
      for f in "$dir"/*.wav; do
        if [ "$OS" = "Darwin" ]; then afplay "$f" 2>/dev/null
        elif have paplay; then paplay "$f" 2>/dev/null
        elif have aplay; then aplay -q "$f" 2>/dev/null
        elif have ffplay; then ffplay -nodisp -autoexit -loglevel quiet "$f" 2>/dev/null
        else sleep 2; fi
      done
    else
      narrate "WAKE UP. WAKE UP. WAKE UP."; sleep 2
    fi
  done
}

narrate() {  # one spoken line, random voice where the OS offers them
  if [ "$OS" = "Darwin" ]; then
    have say && say "$1" 2>/dev/null
  else
    if have spd-say; then spd-say -w "$1" 2>/dev/null
    elif have espeak-ng; then espeak-ng "$1" 2>/dev/null
    elif have espeak; then espeak "$1" 2>/dev/null; fi
  fi
}

force_volume() {
  if [ "$OS" = "Darwin" ]; then
    osascript -e "set volume output volume 100" -e "set volume without output muted" 2>/dev/null
  elif have pactl; then
    pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null
    pactl set-sink-volume @DEFAULT_SINK@ 100% 2>/dev/null
  elif have amixer; then
    amixer set Master 100% unmute >/dev/null 2>&1
  fi
}

NAGS=("Solve it. Wake up." "Still horizontal? Pathetic." "Your blanket will not save you."
  "The snooze button does not exist. I made sure of it." "Coffee is on the other side of this quiz."
  "I can do this all morning." "Math now. Existential dread later." "You installed me. Think about that."
  "The bed is lava. The bed has always been lava." "I believe in you. Unfortunately for you.")

ring() {  # $1 = alarm id | "TEST"
  local id="$1" label time date rhythm enabled diff nq durmin narrator rain cats
  if [ "$id" = "TEST" ]; then
    label="TEST"; diff="hard"; nq=3; durmin=1; narrator=1; rain=0; cats="arithmetic"
  else
    IFS='|' read -r label time date rhythm enabled diff nq durmin narrator rain cats < <(cfg_get_alarm "$id")
    [ "$enabled" = "1" ] || exit 0
    # launchd/systemd daily triggers + a one-time date => date guard here
    if [ -n "$date" ] && [ "$rhythm" = "0" ] && [ "$date" != "$(date +%F)" ]; then exit 0; fi
  fi
  # single instance
  local lock="$ROOT/.ring.lock"
  if ! mkdir "$lock" 2>/dev/null; then exit 0; fi
  trap 'cleanup' EXIT INT TERM

  rm -f "$ROOT/UNLOCK" "$ROOT/PANIC"
  local key; key="$( (uuidgen 2>/dev/null || echo "k$$$RANDOM$RANDOM") | tr -d '-' )"
  local deadline=$(( $(date +%s) + durmin*60 ))
  local dlms=$(( deadline * 1000 ))
  local port=$PORT_BASE
  start_listener "$port" "$key"
  [ "$OS" = "Darwin" ] && have caffeinate && { caffeinate -d -t $((durmin*60)) & CAFF_PID=$!; }

  local url="file://$QUIZ?key=$key&port=$port&label=$(urlenc "$label")&n=$nq&diff=$diff&cats=$cats&rain=$rain&deadline=$dlms"
  open_quiz "$url"
  sound_loop & SOUND_PID=$!
  [ "$narrator" = "1" ] && narrate "Wake up. Solve to disable the alarm." &

  local nag_at=$(( $(date +%s) + 20 ))
  while :; do
    local now; now=$(date +%s)
    [ -f "$ROOT/UNLOCK" ] && [ "$(cat "$ROOT/UNLOCK" 2>/dev/null)" = "$key" ] && break
    [ -f "$ROOT/PANIC" ] && break
    [ "$now" -ge "$deadline" ] && break
    force_volume
    if [ "$narrator" = "1" ] && [ "$now" -ge "$nag_at" ]; then
      narrate "${NAGS[$((RANDOM % ${#NAGS[@]}))]}" &
      nag_at=$(( now + 22 ))
    fi
    sleep 2
  done
  # one-time alarm fired -> disable it so the daily trigger won't re-fire tomorrow
  if [ "$id" != "TEST" ] && [ -n "${date:-}" ] && [ "${rhythm:-0}" = "0" ]; then
    py - "$CFG" "$id" <<'PYEOF'
import json,sys
cfg=json.load(open(sys.argv[1]))
for a in cfg.get("alarms",[]):
    if a.get("id")==sys.argv[2]: a["enabled"]=False
json.dump(cfg,open(sys.argv[1],"w"),indent=2)
PYEOF
  fi
}

cleanup() {
  [ -n "${SOUND_PID:-}" ] && kill "$SOUND_PID" 2>/dev/null
  [ -n "${LISTENER_PID:-}" ] && kill "$LISTENER_PID" 2>/dev/null
  [ -n "${CAFF_PID:-}" ] && kill "$CAFF_PID" 2>/dev/null
  pkill -f "afplay $ROOT" 2>/dev/null
  rm -f "$ROOT/UNLOCK" "$ROOT/PANIC"
  rmdir "$ROOT/.ring.lock" 2>/dev/null
}

# ---------- arming ----------
arm() {
  [ -f "$CFG" ] || die "no config.json in $ROOT (create alarms on Windows or write one by hand)"
  disarm quiet
  local count=0
  while IFS='|' read -r id time rhythm enabled; do
    [ "$enabled" = "1" ] || continue
    local hh="${time%%:*}" mm="${time##*:}"
    if [ "$OS" = "Darwin" ]; then
      local plist="$HOME/Library/LaunchAgents/com.override.v3.$id.plist"
      cat > "$plist" <<PLEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.override.v3.$id</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$HERE/override.sh</string><string>ring</string><string>$id</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$((10#$hh))</integer><key>Minute</key><integer>$((10#$mm))</integer>
  </dict>
</dict></plist>
PLEOF
      launchctl unload "$plist" 2>/dev/null; launchctl load "$plist" || echo "  launchctl load failed for $id"
    else
      local sysd="$HOME/.config/systemd/user"; mkdir -p "$sysd"
      cat > "$sysd/override-v3-$id.service" <<SVEOF
[Unit]
Description=OVERRIDE v3 alarm $id
[Service]
Type=oneshot
ExecStart=/bin/bash $HERE/override.sh ring $id
SVEOF
      cat > "$sysd/override-v3-$id.timer" <<TMEOF
[Unit]
Description=OVERRIDE v3 alarm $id timer
[Timer]
OnCalendar=*-*-* $hh:$mm:00
Persistent=false
[Install]
WantedBy=timers.target
TMEOF
      systemctl --user daemon-reload
      systemctl --user enable --now "override-v3-$id.timer" || echo "  systemd enable failed for $id"
    fi
    echo "  armed  $id  daily at $time (one-time dates are guarded inside the ring)"
    count=$((count+1))
  done < <(py - "$CFG" <<'PYEOF'
import json,sys
cfg=json.load(open(sys.argv[1]))
for a in cfg.get("alarms",[]):
    print("|".join([a.get("id","x"),a.get("time","07:00"),
      str(int(bool(a.get("rhythm",False)))),str(int(bool(a.get("enabled",True))))]))
PYEOF
  )
  echo "$count alarm(s) armed."
  echo "NOTE: waking from full sleep needs 'sudo pmset schedule wake' (mac) / rtcwake (linux) — see: $0 wake-help"
}

disarm() {
  if [ "$OS" = "Darwin" ]; then
    for p in "$HOME"/Library/LaunchAgents/com.override.v3.*.plist; do
      [ -e "$p" ] || continue
      launchctl unload "$p" 2>/dev/null; rm -f "$p"
      [ "${1:-}" = "quiet" ] || echo "  removed $(basename "$p")"
    done
  else
    for t in "$HOME"/.config/systemd/user/override-v3-*.timer; do
      [ -e "$t" ] || continue
      local unit; unit="$(basename "$t")"
      systemctl --user disable --now "$unit" 2>/dev/null
      rm -f "$t" "${t%.timer}.service"
      [ "${1:-}" = "quiet" ] || echo "  removed $unit"
    done
    systemctl --user daemon-reload 2>/dev/null
  fi
  [ "${1:-}" = "quiet" ] || echo "disarmed."
}

wake_help() {
  cat <<'WHEOF'
Waking the machine from SLEEP (the one thing a user process cannot do alone):
  macOS : sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00     (a few min before your alarm)
          sudo pmset repeat cancel                              (to remove)
  Linux : sudo rtcwake -m no -t "$(date -d 'tomorrow 03:55' +%s)"   (one-shot RTC wake)
Alternative: leave the laptop plugged in with the lid open and only the display
asleep — launchd/systemd timers fire fine in that state.
WHEOF
}

case "${1:-help}" in
  ring)      ring "${2:-TEST}" ;;
  test)      ring TEST ;;
  arm)       arm ;;
  disarm)    disarm ;;
  list)      cfg_list; echo "---"; if [ "$OS" = "Darwin" ]; then ls "$HOME/Library/LaunchAgents" 2>/dev/null | grep com.override.v3 || echo "(nothing armed)"; else systemctl --user list-timers 'override-v3-*' --no-pager 2>/dev/null || echo "(nothing armed)"; fi ;;
  wake-help) wake_help ;;
  *) cat <<USEOF
OVERRIDE v3 (macOS/Linux) — usage:
  $0 test        supervised 45s test ring (browser quiz + sound)
  $0 arm         arm every enabled alarm in ../config.json
  $0 disarm      remove all OVERRIDE timers/agents
  $0 list        show configured alarms + armed timers
  $0 wake-help   how to wake the machine from real sleep
USEOF
  ;;
esac
