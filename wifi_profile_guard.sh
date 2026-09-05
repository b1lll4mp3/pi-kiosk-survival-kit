#!/bin/sh
# wifi_profile_guard.sh -- restore lost/truncated network credential files from a local backup.
#
# WHY (2026-08-18): a board dropped off WiFi at 07:08 and stayed dark 13 h. The
# radio was fine, the AP was fine, the credentials were gone -- both /etc/netplan/90-NM-*.yaml
# files sat at 0 BYTES with mtime 07:15, the incident minute. The board browns out chronically
# (throttled=0x50000 on a fresh boot; PSU swap deferred), and a truncate-for-rewrite that loses
# power before the contents land leaves exactly that: an empty file where the SSID+PSK were.
# Every self-heal layer then did its designed job -- NM restarts, a watchdog reboot every
# ~12 min all day -- and none of it can reconstruct a credential. The reboot loop even rotated
# the pre-incident journal past its size cap.
#
# WHAT IT DOES: keeps a root-owned copy of every credential file in $BACKUP (a directory nothing
# rewrites at runtime, so no brownout-mid-write can hit it) and restores any live file that goes
# MISSING or is TRUNCATED TO ZERO while its backup is non-empty -- zero-byte is the observed
# failure shape, not a hypothetical. Covers both stores because fleets are usually split: one board's
# live profile is /etc/NetworkManager/system-connections/*.nmconnection; others
# persist theirs as netplan YAML that regenerates the NM profile into /run each boot.
#
# It only ever restores -- an intact live file is never touched, so a deliberate credential
# rotation is safe; refresh the backup afterwards with --snapshot.
#
# INSTALL (as root):
#   wifi_profile_guard.sh --snapshot     # once, while wifi is up and correct
#   cron: @reboot + */10 * * * *  /usr/local/bin/wifi_profile_guard.sh
#
# POSIX sh, no deps beyond nmcli/netplan/logger. Every branch logs a dated line, including
# refusing an empty snapshot -- a guard whose backup is empty must say so loudly, not sit quiet.
BACKUP=/var/lib/nm-profile-backup
NM_LIVE=/etc/NetworkManager/system-connections
NP_LIVE=/etc/netplan

log(){ logger -t wifi_profile_guard "$*"; }

if [ "$(id -u)" != 0 ]; then echo "must run as root" >&2; exit 2; fi

if [ "${1:-}" = "--snapshot" ]; then
  n=0
  mkdir -p "$BACKUP/nm" "$BACKUP/netplan"; chmod -R 700 "$BACKUP"
  for f in "$NM_LIVE"/*.nmconnection; do
    [ -s "$f" ] || continue                    # -s: skip missing AND zero-byte
    cp -p "$f" "$BACKUP/nm/" && n=$((n+1))
  done
  for f in "$NP_LIVE"/*.yaml; do
    [ -s "$f" ] || continue
    cp -p "$f" "$BACKUP/netplan/" && n=$((n+1))
  done
  if [ "$n" = 0 ]; then
    log "snapshot: NOTHING non-empty to back up -- refusing to leave an empty backup"
    exit 1
  fi
  log "snapshot: $n credential file(s) backed up to $BACKUP"
  exit 0
fi

[ -d "$BACKUP" ] || { log "no backup dir $BACKUP -- run --snapshot once first"; exit 1; }

# restore <backup-file> <live-dir> -> 0 if restored
restore_if_lost(){
  b=$1; dir=$2; base=$(basename "$b")
  if [ ! -s "$dir/$base" ]; then              # missing or zero-byte
    [ -e "$dir/$base" ] && log "live $base is ZERO BYTES (truncated) -- restoring over it"
    cp -p "$b" "$dir/$base" && chmod 600 "$dir/$base" && chown root:root "$dir/$base"
    log "RESTORED $base into $dir"
    return 0
  fi
  return 1
}

nm_restored=0; np_restored=0
for f in "$BACKUP"/nm/*.nmconnection; do
  [ -e "$f" ] || continue
  restore_if_lost "$f" "$NM_LIVE" && nm_restored=$((nm_restored+1))
done
for f in "$BACKUP"/netplan/*.yaml; do
  [ -e "$f" ] || continue
  restore_if_lost "$f" "$NP_LIVE" && np_restored=$((np_restored+1))
done

if [ "$np_restored" -gt 0 ]; then
  # regenerate the /run NM profiles from the restored YAML, then make NM act on them.
  netplan generate 2>/dev/null && log "netplan generate ok" || log "netplan generate FAILED"
fi
if [ "$nm_restored" -gt 0 ] || [ "$np_restored" -gt 0 ]; then
  nmcli connection reload && log "nmcli reload ok ($nm_restored nm, $np_restored netplan restored)" \
    || log "nmcli reload FAILED -- files on disk but NM may not see them"
else
  # date every decision, including the decision to do nothing (Obs 284) -- otherwise
  # "did the @reboot run happen" is unprovable, which is the Rule-15 trap this guard exists for.
  log "check ok -- all backed-up credential files present and non-empty"
fi
exit 0
