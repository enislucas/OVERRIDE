#!/usr/bin/env bash
# OVERRIDE v10.2 // DEEP-SLEEP WAKE HELPER — macOS / Linux
# =====================================================================================
# Schedules a HARDWARE wake a few minutes BEFORE each enabled alarm, so the machine is
# awake when launchd/systemd/cron fires the ring. This is the one thing an unprivileged
# process cannot do on its own — it needs sudo, ONCE, to talk to the power controller.
#
#   ./wake.sh              schedule a one-shot wake before each enabled alarm (mac: pmset
#                          schedule wake ; linux: rtcwake for the SOONEST alarm only)
#   ./wake.sh 5            same, but wake 5 minutes early (default is 3)
#   ./wake.sh repeat       (macOS) set a DAILY repeating wakeorpoweron at the earliest
#                          daily alarm's lead time — idempotent, and wakes even from OFF
#   ./wake.sh cancel       remove OVERRIDE's scheduled/repeating wakes
#   ./wake.sh help
#
# HONEST LIMITS — read these:
#   - macOS `pmset schedule wake` is a ONE-SHOT: it wakes from sleep ONCE. Re-run daily,
#     or use `./wake.sh repeat` (pmset repeat wakeorpoweron) which is idempotent AND can
#     power the Mac on from a full shutdown. Only ONE `repeat` schedule can exist, so it
#     covers the EARLIEST daily alarm's time; later same-day alarms rely on the machine
#     staying awake (or on display-only sleep, where timers fire fine).
#   - Linux `rtcwake -m no` programs the SINGLE RTC alarm and OVERWRITES any earlier RTC
#     wake. There is only one RTC alarm, so this schedules ONLY THE SOONEST alarm. Re-run
#     after it fires (or from a @reboot/cron hook) to arm the next one. It CANNOT power a
#     powered-off machine on for you (that is firmware/BIOS "wake on RTC" territory).
#   - HIBERNATE / full power-off: cannot be woken by these except macOS wakeorpoweron.
#   - Safe to re-run. `repeat`/rtcwake overwrite in place; the one-shot `schedule` path
#     APPENDS pmset events (same timestamps are harmless) — use `cancel` to clear.
#   - Requires python3 (to compute next-fire times from ../config.json) and sudo.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
CFG="$ROOT/config.json"
OS="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }
die() { echo "ERROR: $*" >&2; exit 1; }

have python3 || die "python3 is required (to read ../config.json). Install it and re-run."
[ -f "$CFG" ] || die "no config.json in $ROOT — nothing to schedule. Arm some alarms first."

MODE="schedule"; LEAD=3
for a in "$@"; do
  case "$a" in
    repeat)          MODE="repeat" ;;
    cancel)          MODE="cancel" ;;
    schedule)        MODE="schedule" ;;
    help|-h|--help)  MODE="help" ;;
    [0-9]|[0-9][0-9]) LEAD="$a" ;;
    *) echo "warn: ignoring unknown arg '$a'" >&2 ;;
  esac
done

if [ "$MODE" = "help" ]; then
  sed -n '2,30p' "$HERE/wake.sh"
  exit 0
fi

# python emits, sorted soonest-first, one enabled alarm per line:
#   wakeEpoch|wakePmsetStr|isDaily|wakeHH:MM:SS|label
emit_wakes() {
  python3 - "$CFG" "$LEAD" <<'PYEOF'
import json,sys,time,datetime
cfg=json.load(open(sys.argv[1],encoding="utf-8-sig"))
lead=int(sys.argv[2])
now=datetime.datetime.now()
rows=[]
for a in cfg.get("alarms",[]):
    if not a.get("enabled",True): continue
    t=str(a.get("time","")).strip()
    try:
        hh,mm=[int(x) for x in t.split(":")]
        assert 0<=hh<=23 and 0<=mm<=59
    except Exception:
        continue
    date=str(a.get("date","")).strip()
    daily=bool(a.get("rhythm",False))
    if date and not daily:
        try:
            d=datetime.datetime.strptime(date,"%Y-%m-%d")
            fire=d.replace(hour=hh,minute=mm,second=0,microsecond=0)
        except Exception:
            continue
        if fire<=now:   # a dated one-shot already in the past — nothing to wake for
            continue
    else:
        fire=now.replace(hour=hh,minute=mm,second=0,microsecond=0)
        if fire<=now:
            fire=fire+datetime.timedelta(days=1)
    wake=fire-datetime.timedelta(minutes=lead)
    we=int(time.mktime(wake.timetuple()))
    rows.append((we, wake.strftime("%m/%d/%y %H:%M:%S"), 1 if daily else 0,
                 wake.strftime("%H:%M:%S"), str(a.get("label","")).replace("|"," ")))
rows.sort(key=lambda r: r[0])
for r in rows:
    print("|".join(str(x) for x in r))
PYEOF
}

# --------------------------------------------------------------------- macOS
if [ "$OS" = "Darwin" ]; then
  have pmset || die "pmset not found (are you on macOS?)."

  if [ "$MODE" = "cancel" ]; then
    echo "Clearing OVERRIDE wake schedules (sudo required)..."
    echo "+ sudo pmset repeat cancel"
    sudo pmset repeat cancel 2>/dev/null || echo "  (no repeat schedule to cancel)"
    echo "+ sudo pmset schedule cancelall"
    echo "  NOTE: cancelall clears ALL pmset one-shot events, including any you set by hand."
    sudo pmset schedule cancelall 2>/dev/null || echo "  (nothing to cancel)"
    echo "Done. Current power schedule:"; pmset -g sched
    exit 0
  fi

  rows="$(emit_wakes)"
  [ -n "$rows" ] || die "no enabled alarms with a valid time in config.json."

  if [ "$MODE" = "repeat" ]; then
    # earliest DAILY alarm -> a single idempotent repeating wakeorpoweron
    daily_line="$(printf '%s\n' "$rows" | awk -F'|' '$3=="1"{print; exit}')"
    if [ -z "$daily_line" ]; then
      echo "No daily (rhythm) alarms found. 'repeat' only makes sense for daily alarms."
      echo "Use ./wake.sh (one-shot) for dated alarms instead."
      exit 1
    fi
    whms="$(printf '%s' "$daily_line" | cut -d'|' -f4)"
    lbl="$(printf '%s' "$daily_line" | cut -d'|' -f5)"
    echo "Setting a DAILY repeating wake (wakes even from a full shutdown):"
    echo "  earliest daily alarm '$lbl' -> wake at $whms every day, ${LEAD} min early"
    echo "+ sudo pmset repeat wakeorpoweron MTWRFSU $whms"
    sudo pmset repeat wakeorpoweron MTWRFSU "$whms" \
      && echo "OK. Re-running is safe (it replaces the previous repeat)." \
      || echo "FAILED — check the sudo password / pmset output above."
    echo "Current schedule:"; pmset -g sched
    exit 0
  fi

  # MODE = schedule : one-shot wake before EACH enabled alarm
  echo "Scheduling one-shot hardware wakes, ${LEAD} min before each enabled alarm (sudo required)."
  echo "TIP: for daily use, ./wake.sh repeat is idempotent and also powers on from OFF."
  n=0
  while IFS='|' read -r we pmstr daily whms lbl; do
    [ -n "$pmstr" ] || continue
    echo "+ sudo pmset schedule wake \"$pmstr\"   ($lbl)"
    sudo pmset schedule wake "$pmstr" || echo "  FAILED for $lbl"
    n=$((n+1))
  done <<EOF
$rows
EOF
  echo "$n wake event(s) scheduled. Re-run daily, or use cancel/repeat."
  echo "Current schedule:"; pmset -g sched
  exit 0
fi

# --------------------------------------------------------------------- Linux
have rtcwake || die "rtcwake not found (package: util-linux). Without it, deep-sleep wake
       is unavailable — leave the lid open / display-sleep only, where timers still fire."

if [ "$MODE" = "cancel" ]; then
  echo "Clearing the RTC wake alarm (sudo required)..."
  for r in /sys/class/rtc/rtc0/wakealarm /sys/class/rtc/rtc1/wakealarm; do
    if [ -e "$r" ]; then echo "+ echo 0 > $r"; echo 0 | sudo tee "$r" >/dev/null 2>&1; fi
  done
  echo "Done (any single RTC wake alarm is cleared)."
  exit 0
fi

if [ "$MODE" = "repeat" ]; then
  echo "Linux has no 'repeat' RTC wake — the RTC holds ONE alarm. Falling back to one-shot"
  echo "for the SOONEST alarm. Re-run after it fires (e.g. from a cron @reboot hook)."
fi

rows="$(emit_wakes)"
[ -n "$rows" ] || die "no enabled alarms with a valid time in config.json."

# ONLY the soonest — the RTC has a single alarm slot and rtcwake overwrites it
first="$(printf '%s\n' "$rows" | head -n1)"
we="$(printf '%s' "$first" | cut -d'|' -f1)"
whms="$(printf '%s' "$first" | cut -d'|' -f4)"
lbl="$(printf '%s' "$first" | cut -d'|' -f5)"
total="$(printf '%s\n' "$rows" | grep -c .)"

echo "The RTC holds a SINGLE wake alarm; rtcwake OVERWRITES any earlier one."
echo "Scheduling ONLY the soonest alarm ($total enabled total):"
echo "  '$lbl' -> hardware wake at $whms (epoch $we), ${LEAD} min before it fires"
echo "+ sudo rtcwake -m no -t $we"
if sudo rtcwake -m no -t "$we"; then
  echo "OK. The machine will wake (not sleep-now: '-m no' just programs the alarm)."
  echo "Re-run this after it fires to arm the next alarm."
else
  echo "FAILED — check the rtcwake output above (RTC in local vs UTC can differ; try"
  echo "  'sudo hwclock --systohc --localtime' or consult your distro's rtcwake notes)."
fi
