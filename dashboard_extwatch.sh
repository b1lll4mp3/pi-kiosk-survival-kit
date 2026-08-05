#!/usr/bin/env bash
# Dashboard EXTERNAL watchdog (layer 4) — runs on a server, NOT on the boards. Cron: */5.
#
# Covers the failure class the on-Pi dashboard_watchdog.sh can NEVER fix: the board is
# alive-but-unrecoverable (wedged past its own cron, WiFi stack dead in a way NetworkManager
# restarts + reboots don't fix) or hard-frozen. Original incident (2026-08-02): a board sat dark
# 8 hours with power on — every Pi-side layer blind or dead, and the previous external layer (a
# home-automation ping-recovery rule) had been disabled weeks earlier for false cross-VLAN-ping
# triggers. This replaces it with a trustworthy signal: the board's OWN render heartbeat
# (client-truth — it only beats if the page JS is actually running), NOT ping. On segmented
# networks ICMP is commonly filtered between VLANs; ping was the old false-trigger bug.
#
# Escalation per board (only boards with a smart-plug entity can be cycled):
#   heartbeat ago_s > DEAD_AFTER (default 30 min — the Pi-side watchdog gets its full
#     T1..T3 / N1..N2 run first) -> Home Assistant power-cycles the board's plug (off, 8 s, on)
#   ago_s null/absent (heartbeat server restarted while the board was dark) -> fall back to a
#     TCP :22 probe of the board (cross-VLAN TCP is usually allowed; never ICMP cross-VLAN)
#   rate limit: max MAX_CYCLES power-cycles per WINDOW per board; when exhausted -> alert-only.
#     Guards the SD card and avoids a cycle-loop on a board that can't boot (dead card/PSU).
#   Heartbeat server itself unreachable -> abstain entirely (no board can be judged; cycling
#     a board won't fix the server).
#
# Optional: pushes to an Uptime-Kuma-style push monitor every healthy run (PUSH_URL) so the
# watchdog itself is monitored — a silently dead cron shows up as an alert within minutes.
#
# Hard-won table lesson (2026-08-01): a board left commented out of the table after its install
# went dark and STAYED dark 36 h with no alert, while the page monitor (which probes the server,
# not the Pi) stayed green the whole time. If a board renders a dashboard, it belongs in BOARDS —
# alert-only if it has no plug.
#
# Deploy: this file + a config file on any always-on Linux box; cron: */5 * * * *.
# Secrets: HA_TOKEN comes from ENV_FILE (a long-lived Home Assistant token). Never inline it.
set -u

# ---------------------------------------------------------------- configuration
ENV_FILE="${ENV_FILE:-$HOME/.config/dashboard_extwatch.env}"   # must export HA_TOKEN
STATE_DIR="${STATE_DIR:-$HOME/.dashboard_extwatch}"
DASHBOARD_SERVER="${DASHBOARD_SERVER:-http://192.0.2.10:1880}" # heartbeat/endpoint server
NR="$DASHBOARD_SERVER/endpoint"
HA="${HA_URL:-http://192.0.2.30:8123}"                         # Home Assistant base URL
DEAD_AFTER=1800          # s stale before a board is declared beyond self-help
MAX_CYCLES=2             # power-cycles per window before alert-only
WINDOW=21600             # 6 h rate-limit window
CYCLE_GAP=900            # min s between cycles — a cycled board needs a few ticks to boot + beat
OFF_SECS=8
LOCK=/tmp/dashboard_extwatch.lock

# board|heartbeat endpoint|HA plug entity (empty = alert-only)|board IP (for :22 fallback probe)
# Boards without a dedicated smart plug still belong here: they get alert-only coverage.
BOARDS="
family|dashboard-heartbeat|switch.family_board_plug|192.0.2.51
bedroom|dashboard-heartbeat-bedroom||192.0.2.52
basement|dashboard-heartbeat-basement||192.0.2.53
"
# ------------------------------------------------------------------------------

exec 200>"$LOCK"; flock -n 200 || exit 0
set -a; . "$ENV_FILE"; set +a
mkdir -p "$STATE_DIR"
# Kuma push URL lives outside the repo (it embeds the push token): one line in $STATE_DIR/pushurl
PUSH_URL=""
[ -f "$STATE_DIR/pushurl" ] && PUSH_URL=$(head -1 "$STATE_DIR/pushurl")
log(){ logger -t dashboard_extwatch "$*"; echo "$(date -Is) $*" >> "$STATE_DIR/log"; }

ha_call(){ # service_path json
  curl -s -m 10 -X POST -H "Authorization: Bearer $HA_TOKEN" -H 'Content-Type: application/json' \
    -d "$2" "$HA/api/services/$1" >/dev/null
}
notify(){ ha_call notify/notify "{\"title\":\"Dashboard watchdog\",\"message\":$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}"; }
tcp22(){ timeout 4 bash -c "echo > /dev/tcp/$1/22" 2>/dev/null; }

# Heartbeat server alive at all? If not, abstain — no board can be judged.
curl -s -m 8 "$NR/dashboard-heartbeat" >/dev/null || { log "heartbeat server unreachable, abstain"; exit 0; }

now=$(date +%s)
echo "$BOARDS" | while IFS='|' read -r NAME EP PLUG IP; do
  [ -z "$NAME" ] && continue
  J=$(curl -s -m 8 "$NR/$EP?t=$now") || J=""
  AGO=$(printf '%s' "$J" | sed -n 's/.*"ago_s"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')

  DEAD=0
  if [ -n "$AGO" ]; then
    [ "$AGO" -gt "$DEAD_AFTER" ] && DEAD=1
  else
    # no beat on record (server restarted while board dark) — TCP :22 is the tiebreaker
    tcp22 "$IP" || DEAD=1
  fi

  SF="$STATE_DIR/$NAME"
  if [ "$DEAD" -eq 0 ]; then
    # healthy (or at least reachable): clear any alert-latch so the next incident alerts again
    [ -f "$SF" ] && { read -r C WS ALERTED < "$SF" || true; [ "${C:-0}" -gt 0 ] && log "$NAME recovered (ago=${AGO:-tcp-ok})"; }
    rm -f "$SF"
    continue
  fi

  C=0; WS=$now; ALERTED=0; LC=0
  [ -f "$SF" ] && read -r C WS ALERTED LC < "$SF"
  : "${C:=0}"; : "${WS:=$now}"; : "${ALERTED:=0}"; : "${LC:=0}"
  [ $((now - WS)) -gt "$WINDOW" ] && { C=0; WS=$now; ALERTED=0; LC=0; }

  if [ -z "$PLUG" ]; then
    if [ "$ALERTED" -eq 0 ]; then
      log "$NAME dead (ago=${AGO:-none}, no plug) -> alert only"
      notify "$NAME board dark (heartbeat ${AGO:-gone}s, no smart plug to cycle) — needs hands."
      echo "$C $WS 1 $LC" > "$SF"
    fi
    continue
  fi

  if [ "$C" -ge "$MAX_CYCLES" ]; then
    if [ "$ALERTED" -eq 0 ]; then
      log "$NAME still dead after $C cycles -> giving up until window reset, alerting"
      notify "$NAME board STILL dark after $C power-cycles — not booting on its own (SD card / PSU / WiFi?). Manual check needed."
      echo "$C $WS 1 $LC" > "$SF"
    fi
    continue
  fi

  if [ "$LC" -gt 0 ] && [ $((now - LC)) -lt "$CYCLE_GAP" ]; then
    log "$NAME still dead but last cycle $((now - LC))s ago (<${CYCLE_GAP}s) -> waiting"
    continue
  fi

  C=$((C + 1))
  log "$NAME dead (ago=${AGO:-none}) -> power-cycle $PLUG (attempt $C/$MAX_CYCLES)"
  ha_call switch/turn_off "{\"entity_id\":\"$PLUG\"}"
  sleep "$OFF_SECS"
  ha_call switch/turn_on "{\"entity_id\":\"$PLUG\"}"
  notify "$NAME board was dark ${AGO:-?}s past self-heal — power-cycled its plug (attempt $C/$MAX_CYCLES)."
  echo "$C $WS 0 $now" > "$SF"
done

# heartbeat for the watchdog itself
[ -n "$PUSH_URL" ] && curl -s -m 8 "$PUSH_URL?status=up&msg=ok" >/dev/null
exit 0
