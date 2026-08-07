#!/bin/sh
# dashboard_display_watch.sh -- keep the panel correctly configured: mode, portrait rotation, RGB range.
#
# WHY THE MODE/ROTATION HALF (2026-08-04, basement): the openbox autostart configures the display
# ONCE, at X start. If X starts while the monitor is off, asleep or unplugged, every connector
# reads 'disconnected', no mode is set (framebuffer sits at 320x200), and NOTHING re-applies it
# when the panel is powered back on -- the board stays dark until someone reboots it. A
# rotate-with-fallback fixes the empty output name but cannot set a mode on a disconnected output;
# this loop is the other half. It also self-heals a landscape board: if the active geometry is
# wider than it is tall, rotation was lost (xrandr --auto resets it) and gets re-applied.
#
# WHY THE RGB-RANGE HALF (2026-08-04, family Pi 5): the Pi 3B kits forced full-range RGB at the
# firmware level with hdmi_pixel_encoding=2. That option is IGNORED on Pi 4 / Pi 5 KMS, so the
# family board silently lost it in the hardware swap and came up on "Broadcast RGB: Automatic".
# On a 1080p60 CEA timing that commonly means Limited 16:235; a PC monitor renders limited-range
# input with crushed blacks and washed whites, which reads as a soft, low-contrast picture. The
# property has to be set through xrandr now. Harmless where a connector doesn't expose it.
#
# POSIX sh: started from the openbox autostart, which runs under dash.
export DISPLAY=${DISPLAY:-:0}
. /home/pi/dashboard_output.sh

set_range(){ xrandr --output "$1" --set "Broadcast RGB" "Full" 2>/dev/null || true; }

connected(){ [ -n "$1" ] && xrandr 2>/dev/null | grep -qE "^${1} connected"; }

# --- mode-escalation guard (2026-08-06) ---------------------------------------------------------
# WHAT THIS CANNOT DO: detect that the panel is dark. A monitor refusing to sync reports nothing
# back -- the framebuffer keeps rendering, the page keeps beating, and every remote check says
# healthy. That is why the standing rule is that only human eyes close a glass case.
#
# WHAT IT CAN DO: catch the TRIGGER. Basement went dark for 7.5 h on 2026-08-05 because raising the
# core clock (hdmi_enable_4kp60, needed to bring the 311 MHz 75 Hz mode in-envelope) also unlocked
# 120/144 Hz modes, and X auto-selects the highest preferred one -- landing on 1440p144, which that
# link cannot carry. Geometry still read 1440x2560 and looked perfectly healthy; the REFRESH RATE
# was the only thing that changed. So record the first known-good mode+rate and shout if it moves.
MODE_FILE=/home/pi/.dashboard_mode

current_mode(){   # -> "2560x1440 75.00"
  xrandr 2>/dev/null | awk -v o="$1" '
    $1==o { inb=1; next }
    inb && /^[A-Za-z]/ { inb=0 }
    inb { for(i=2;i<=NF;i++) if ($i ~ /\*/) { r=$i; gsub(/[*+]/,"",r); print $1, r; exit } }'
}

check_mode(){
  cm=$(current_mode "$1")
  [ -z "$cm" ] && return 0
  if [ ! -f "$MODE_FILE" ]; then
    printf '%s\n' "$cm" > "$MODE_FILE"
    logger -t dashboard_display "baseline mode recorded: $cm"
    return 0
  fi
  want=$(cat "$MODE_FILE" 2>/dev/null)
  [ "$cm" = "$want" ] && return 0
  logger -t dashboard_display "MODE CHANGED on $1: expected '$want', active '$cm' -- a mode this link cannot carry is invisible from here (framebuffer still renders, heartbeat still beats). Restoring."
  xrandr --output "$1" --mode "${want% *}" --rate "${want#* }" --rotate right 2>/dev/null \
    && logger -t dashboard_display "restored $want" \
    || logger -t dashboard_display "RESTORE FAILED for $want -- check the glass with your eyes"
}

# Assert the range once at start, then only after a reconfigure -- re-asserting every pass would
# write a KMS property (and risk a visible flicker) three times a minute for no reason.
O=$(dashboard_output)
connected "$O" && set_range "$O"

while true; do
  O=$(dashboard_output)
  if connected "$O"; then
    G=$(xrandr 2>/dev/null | sed -nE "s/^${O} connected (primary )?([0-9]+x[0-9]+)\+.*/\2/p")
    W=${G%x*}; H=${G#*x}
    if [ -z "$G" ]; then
      logger -t dashboard_display "$O connected with no active mode -> --auto --rotate right + full RGB"
      xrandr --output "$O" --auto --rotate right 2>/dev/null
      set_range "$O"
    elif [ "$W" -gt "$H" ] 2>/dev/null; then
      logger -t dashboard_display "$O is landscape ($G) -> re-applying --rotate right + full RGB"
      xrandr --output "$O" --rotate right 2>/dev/null
      set_range "$O"
    else
      check_mode "$O"
    fi
  fi
  sleep 20
done
