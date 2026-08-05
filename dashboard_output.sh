#!/bin/sh
# Echo the display output to drive. Prefers a truly-connected one; falls back to the first HDMI
# connector so a sleeping panel can never leave callers with an empty output name.
#
# WHY (2026-08-04 basement audit): the autostart resolved its output with a bare connected-only
# match and NO fallback. When X starts while the panel is asleep or powered off, EVERY connector
# reads 'disconnected', the output name comes back empty, and the portrait rotate silently no-ops
# -- a wall-mounted portrait board comes up LANDSCAPE.
#
# POSIX sh ON PURPOSE, and sourced with '.' by openbox's autostart, dashboard_display_watch.sh and (on
# the family board) family_screen_poll.sh. Openbox runs autostart under /bin/sh (dash) -- a
# bash-ism here (BASH_SOURCE, arrays) is a hard parse error that kills the whole autostart, i.e.
# no rotate, no kiosk, black board.
dashboard_output(){
  o=$(xrandr 2>/dev/null | awk '$2=="connected"{print $1; exit}')
  [ -z "$o" ] && o=$(xrandr 2>/dev/null | awk '/^HDMI/{print $1; exit}')
  printf '%s' "$o"
}
# Print when executed directly; stay silent when sourced ($0 is the caller's path, not this file).
case "$0" in *dashboard_output.sh) dashboard_output; echo ;; esac
