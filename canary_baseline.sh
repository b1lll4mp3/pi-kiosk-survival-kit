#!/usr/bin/env bash
# canary_baseline.sh -- capture the bedroom board's exact payload + memory fingerprint.
#
# WHY: after the 2026-08-04 Pi 5 swap the fleet is mixed-vintage. Family (Pi 5 8 GB) and basement
# (Pi 4 4 GB) are getting progressively-enhanced payloads; bedroom (Pi 3B, 1 GB, already ~80 MB
# into swap, throttled=0x70000) must stay byte-for-byte identical. Per-board identity is gated by
# whitelist layers that fall back SILENTLY -- a missed layer produces no error, just crossed state.
# So "did we regress bedroom?" has to be answered with bytes, not with a 200.
#
# Run before any phase and after every phase; diff the two. ANY delta is stop-the-line.
#
# NOTE ON WHAT IS TRUSTWORTHY HERE: payload bytes and RSS/swap are clock-independent and valid
# even while bedroom is browning out (under-voltage flagged, PSU swap deferred). TIMING is NOT --
# under-voltage causes ARM frequency scaling, so do not use this board for latency comparisons
# until its supply is replaced.
set -u
NR="${DASHBOARD_SERVER:-http://192.0.2.10:1880}/endpoint"
BOARD_IP="${BOARD_IP:-192.0.2.52}"
KEY="${KEY:-$HOME/.ssh/id_ed25519}"

echo "=== canary baseline: bedroom ($BOARD_IP) $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

echo
echo "--- payload bytes (the primary signal) ---"
for e in \
  "dashboard-bedroom" \
  "dashboard-photo?board=bedroom" \
  "dashboard-extras?board=bedroom" \
  "dashboard-agenda" \
  "dashboard-header" \
  "dashboard-cams" \
  "dashboard-garage" \
  "dashboard-fonts.css" \
; do
  n=$(curl -s -m 20 "$NR/$e" | wc -c)
  printf '%-32s %s\n' "$e" "$n"
done

echo
echo "--- board memory + thermal ---"
ssh -o BatchMode=yes -o ConnectTimeout=8 -i "$KEY" "pi@$BOARD_IP" '
  free -m | awk "/Mem:/{printf \"mem_total=%s mem_avail=%s\n\", \$2, \$7} /Swap:/{printf \"swap_used=%s swap_total=%s\n\", \$3, \$2}"
  printf "chromium_rss_mb=%s\n" "$(ps -eo rss,comm | awk "/chromium/{s+=\$1} END{print int(s/1024)}")"
  printf "chromium_procs=%s\n" "$(pgrep -xc chromium)"
  vcgencmd measure_temp
  vcgencmd get_throttled
' 2>&1

echo
echo "=== end baseline ==="
