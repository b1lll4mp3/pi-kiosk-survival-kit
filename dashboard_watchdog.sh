#!/usr/bin/env bash
# Dashboard render watchdog (family-room board, Pi 3B). Cron: */2 * * * *.
#
# Recovers a WEDGED renderer (Chromium alive, page JS frozen) — kiosk.sh's crash-respawn can't catch
# it and the in-page self-heal can't fix it (needs the frozen JS to run). Detection = the display
# heartbeat age from Node-RED. 3-tier escalation because a 1 GB board eventually leaks over multi-day
# uptime and a soft reload isn't always enough:
#   T1  stale        -> xdotool ctrl+r on the chromium window (browser-level reload; works if JS frozen)
#   T2  still stale   -> pkill -9 chromium  (kiosk.sh respawns fresh in ~2s)
#   T3  still stale ~10 min after T2 -> guarded `sudo reboot` (rate-limited; flushes the 1 GB)
#
# ALSO handles the 2026-08-01 failure mode: the Pi's OWN WiFi dies in place (power stays on, board
# drops off the network, heartbeat endpoint unreachable). The old rule was "unreachable => never
# act" — correct for a backend outage, blind to a dead wlan0. Unreachable now splits on wlan0 state:
#   wlan0 connected      -> second-opinion probe (see below); only abstain if the network is
#                           genuinely alive (backend down — reload/reboot can't fix Node-RED)
#   wlan0 NOT connected  -> N1 3 strikes (~6 min)  -> sudo systemctl restart NetworkManager
#                           N2 6 strikes (~12 min) -> guarded `sudo reboot`, same cooldown as T3
#                           (reboot reloads brcmfmac firmware, which an NM restart can't)
#
# 2026-08-02 LESSON: NM can report wlan0 "connected" while the client is gone from the AP (assoc
# stale, no traffic passes) — the board sat dark 8 h because this branch abstained on NM's word
# alone. "connected" is now only trusted if a second-opinion probe passes: gateway ping (same-VLAN
# ICMP is allowed) OR TCP to Pi-hole DNS (cross-VLAN TCP is allowed; cross-VLAN ICMP is NOT — never
# use ping for the cross-VLAN leg). Both probes failing while NM says connected => net-dead, take
# the N-branch.
#
# NOT set -e / pipefail on purpose: this script's normal flow runs commands that return non-zero
# (curl timing out is the trigger; pkill returns 1 when nothing matches). set -e would exit exactly
# when it should be recovering. Uses set -u + explicit || guards instead.
set -u

# flock: never let two instances overlap (a hung curl + the */2 cron could otherwise stack).
exec 200>/var/lock/dashboard_watchdog.lock
/usr/bin/flock -n 200 || exit 0

DASHBOARD_SERVER="${DASHBOARD_SERVER:-http://192.0.2.10:1880}"   # base URL of the server that stores heartbeats
DNS_PROBE_HOST="${DNS_PROBE_HOST:-192.0.2.53}"                   # any TCP:53 responder on another subnet (e.g. your DNS server)
BEAT_URL="${BEAT_URL:-$DASHBOARD_SERVER/endpoint/dashboard-heartbeat}"
STALE=120                    # seconds; page beats every 30s, so >120 = ~4 missed
REBOOT_AFTER=600             # seconds stale (since first detection) before T3 reboot is allowed
REBOOT_COOLDOWN=1800         # min seconds between watchdog reboots (shared by T3 and N2)
NET_NM_STRIKES=3             # consecutive unreachable+wifi-down runs before NetworkManager restart
NET_REBOOT_STRIKES=6         # ... before reboot
STATE=/tmp/dashboard_wd.state      # "level since lastreboot"
NET_STATE=/tmp/dashboard_wd_net.state  # "strikes lastreboot"
export DISPLAY=:0
log(){ /usr/bin/logger -t dashboard_watchdog "$*"; }
# Temp+throttle context on every acted-on event: a hot/throttled SoC stretches JS execution and can
# masquerade as a wedge — this pins or rules that out from the log alone.
soc(){ printf '%s %s' "$(/usr/bin/vcgencmd measure_temp 2>/dev/null)" "$(/usr/bin/vcgencmd get_throttled 2>/dev/null)"; }

# WD_TEST_WIFI_STATE lets a test force this branch without killing real WiFi.
wifi_state(){
  if [ -n "${WD_TEST_WIFI_STATE:-}" ]; then printf '%s' "$WD_TEST_WIFI_STATE"; return; fi
  /usr/bin/nmcli -t -f DEVICE,STATE dev 2>/dev/null | /bin/sed -n 's/^wlan0:\(.*\)$/\1/p'
}

# Second opinion when NM claims "connected": is traffic actually passing? Gateway ping (same-VLAN
# ICMP OK) or TCP to Pi-hole :53 (cross-VLAN TCP OK). WD_TEST_NET_DEAD=1 forces failure in tests.
net_alive(){
  [ -n "${WD_TEST_NET_DEAD:-}" ] && return 1
  GW=$(/usr/bin/ip route 2>/dev/null | /bin/sed -n 's/^default via \([0-9.]*\).*/\1/p' | /usr/bin/head -1)
  [ -n "$GW" ] && /usr/bin/ping -c1 -W2 "$GW" >/dev/null 2>&1 && return 0
  /usr/bin/timeout 3 /bin/bash -c "echo > /dev/tcp/${DNS_PROBE_HOST}/53" 2>/dev/null && return 0
  return 1
}

J=$(/usr/bin/curl -s -m 8 "$BEAT_URL?t=$(date +%s)") || {
  now=$(date +%s)
  W=$(wifi_state)
  if [ "$W" = "connected" ] && net_alive; then
    log "node-red unreachable, wlan0 connected, net alive -> backend down, skip"
    /bin/rm -f "$STATE" "$NET_STATE"; exit 0
  fi
  [ "$W" = "connected" ] && log "wlan0 claims connected but gw+dns probes FAIL -> treating as net-dead"
  STRIKES=0; NLASTREBOOT=0
  [ -f "$NET_STATE" ] && read -r STRIKES NLASTREBOOT < "$NET_STATE" 2>/dev/null || true
  : "${STRIKES:=0}"; : "${NLASTREBOOT:=0}"
  STRIKES=$((STRIKES + 1))
  echo "$STRIKES $NLASTREBOOT" > "$NET_STATE"
  log "unreachable + wlan0 '${W:-missing}' (strike $STRIKES) [$(soc)]"
  if [ "$STRIKES" -ge "$NET_REBOOT_STRIKES" ]; then
    if [ $((now - NLASTREBOOT)) -ge "$REBOOT_COOLDOWN" ]; then
      log "N2 wifi still dead after NM restart -> sudo reboot"
      echo "0 $now" > "$NET_STATE"
      /usr/bin/sudo /sbin/reboot || /sbin/reboot || true
    else
      log "N2 due but in reboot cooldown"
    fi
  elif [ "$STRIKES" -eq "$NET_NM_STRIKES" ]; then
    log "N1 wifi dead ${STRIKES} strikes -> restart NetworkManager"
    /usr/bin/sudo /usr/bin/systemctl restart NetworkManager || true
  fi
  exit 0
}
/bin/rm -f "$NET_STATE"
[ -z "$J" ] && { log "empty heartbeat resp, skip"; /bin/rm -f "$STATE"; exit 0; }
AGO=$(printf '%s' "$J" | /bin/sed -n 's/.*"ago_s"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')
[ -z "$AGO" ] && { log "ago_s null (grace), skip"; /bin/rm -f "$STATE"; exit 0; }

now=$(date +%s)
LEVEL=ok; SINCE=0; LASTREBOOT=0
[ -f "$STATE" ] && read -r LEVEL SINCE LASTREBOOT < "$STATE" 2>/dev/null || true
: "${LEVEL:=ok}"; : "${SINCE:=0}"; : "${LASTREBOOT:=0}"

if [ "$AGO" -le "$STALE" ]; then
  [ "$LEVEL" != "ok" ] && log "recovered (ago=${AGO}s)"
  /bin/rm -f "$STATE"; exit 0
fi

case "$LEVEL" in
  ok)
    log "T1 stale (ago=${AGO}s) -> ctrl+r [$(soc)]"
    /usr/bin/xdotool search --class chromium key --window %@ ctrl+r 2>/dev/null || /usr/bin/xdotool key ctrl+r || true
    echo "soft $now $LASTREBOOT" > "$STATE" ;;
  soft)
    log "T2 still stale (ago=${AGO}s) -> pkill chromium (respawn) [$(soc)]"
    /usr/bin/pkill -9 -f 'chromium-browser' 2>/dev/null || /usr/bin/pkill -9 chromium 2>/dev/null || true
    echo "killed $SINCE $LASTREBOOT" > "$STATE" ;;
  killed)
    if [ $((now - SINCE)) -ge "$REBOOT_AFTER" ] && [ $((now - LASTREBOOT)) -ge "$REBOOT_COOLDOWN" ]; then
      log "T3 still stale ${AGO}s, $((now-SINCE))s since first -> sudo reboot [$(soc)]"
      echo "rebooted $SINCE $now" > "$STATE"
      /usr/bin/sudo /sbin/reboot || /sbin/reboot || true
    else
      log "post-kill, awaiting respawn (ago=${AGO}s, $((now-SINCE))s stale)"
    fi ;;
  rebooted)
    log "post-reboot, awaiting boot (ago=${AGO}s)" ;;
esac
exit 0
