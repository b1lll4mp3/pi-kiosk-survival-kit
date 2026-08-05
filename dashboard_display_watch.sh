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
    fi
  fi
  sleep 20
done
