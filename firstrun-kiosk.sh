#!/bin/bash
# Unattended FIRST-BOOT provisioning for a Raspberry Pi wall-kiosk (genericized from a
# Pi 5 8 GB production kit, 2026-08-04). Turns a fresh Raspberry Pi OS Lite (64-bit) card
# into a self-healing portrait dashboard: X + openbox + chromium kiosk, display self-config,
# remote screen/reboot/halt control, and the layer-3 watchdog wired into cron.
#
# HOW IT RUNS: flash Pi OS Lite (64-bit) with Imager OS-customization (hostname, SSH pubkey,
# WiFi), then copy this file AND the kit's dashboard_watchdog.sh to /boot/firmware/ and hook
# this script into the image's first-boot mechanism (cloud-init runcmd / firstrun hook).
# Progress logs to /boot/firmware/kiosk-firstboot.log.
#
# WHY SO MUCH VERIFICATION: cloud-init runcmd fires ONCE. A half-configured board that gets
# the done-flag never retries — so every step that can fail loud does, and the done-flag is
# only written after the full stack verifies.
set -u

# ---------------------------------------------------------------- configuration
DASHBOARD_SERVER="${DASHBOARD_SERVER:-http://192.0.2.10:1880}"  # your dashboard/heartbeat server
BOARD="${BOARD:-family}"                                        # this board's name (endpoint suffixes)
URL="$DASHBOARD_SERVER/endpoint/dashboard-$BOARD"               # the page the kiosk renders
ROTATE="right"                                                  # portrait rotation; "" for landscape
# ------------------------------------------------------------------------------

LOG=/boot/firmware/kiosk-firstboot.log
DONE=/boot/firmware/.kiosk-firstboot-done
exec >>"$LOG" 2>&1
echo "=== kiosk firstboot ($BOARD) $(date) ==="
[ -f "$DONE" ] && { echo "already done, skip"; exit 0; }

U=pi; H=/home/pi
APT_OPTS="-o DPkg::Lock::Timeout=600 -y"

echo "--- wait for network (wifi up + dashboard server reachable), up to 5 min ---"
for i in $(seq 1 30); do
  if curl -s -m 6 -o /dev/null "$DASHBOARD_SERVER/"; then echo "network up ($i)"; break; fi
  sleep 10
done

echo "--- wait for CLOCK SYNC before apt (2026-08-04 first-boot failure) ---"
# A Pi has no battery-backed RTC: first boot starts at the image's build date. Hit for real:
# the clock said mid-June, so every repo signature was "not live until" a future date,
# apt-get update failed signature verification, the stale index pointed at superseded package
# versions, and the pool fetches 404'd:
#   OpenPGP signature verification failed: ... Not live until <future date>
#   E: Failed to fetch .../libgraphite2-3_..._arm64.deb  404  Not Found
# Result: no chromium, no X, no kiosk. Waiting for network reachability is NOT enough — wait
# for time sync specifically, and refuse to proceed on a clock that is obviously wrong.
for i in $(seq 1 30); do
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = "yes" ] && { echo "clock synced ($i): $(date)"; break; }
  sleep 10
done
YEAR=$(date +%Y)
if [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" != "yes" ] && [ "$YEAR" -lt 2026 ]; then
  echo "VERIFY FAIL: clock not synced and year=$YEAR — apt signature checks will fail; no done-flag"
  exit 1
fi

echo "--- apt install kiosk stack ---"
# DPkg::Lock::Timeout: runcmd races cloud-init's own packages: job and the apt-daily timers;
# without it apt-get fails outright instead of waiting.
export DEBIAN_FRONTEND=noninteractive
# apt-get update must SUCCEED. It failing used to be non-fatal, which is how a bad index reached
# the install step and 404'd. Retry, then refuse the done-flag rather than install from a stale index.
UPD_OK=0
for i in 1 2 3; do
  if apt-get $APT_OPTS update; then UPD_OK=1; break; fi
  echo "apt-get update failed (attempt $i) — retrying in 20s"; sleep 20
done
[ "$UPD_OK" = "1" ] || { echo "VERIFY FAIL: apt-get update failed 3x — check clock/signatures; no done-flag"; exit 1; }
apt-get $APT_OPTS install --no-install-recommends xserver-xorg x11-xserver-utils xinit openbox \
  unclutter scrot xdotool
apt-get $APT_OPTS install --no-install-recommends chromium-browser || apt-get $APT_OPTS install --no-install-recommends chromium
command -v chromium-browser >/dev/null 2>&1 || ln -sf "$(command -v chromium)" /usr/local/bin/chromium-browser

echo "--- $H/kiosk.sh (layer 2: crash-respawn + self-healing reconnect splash) ---"
cat > $H/kiosk.sh <<KIOSK
#!/bin/bash
URL="$URL"
PREF="\$HOME/.config/chromium/Default/Preferences"
# Self-healing splash (2026-07-31): a kiosk respawn during a server outage used to strand the
# board on a Chromium error page no watchdog tier could fix (the watchdog correctly skips while
# the heartbeat endpoint is down). If the dashboard is unreachable at (re)launch, load a local
# data-URL "Reconnecting" page that polls the endpoint every 5s and replaces itself with the real
# dashboard the moment the server answers.
SPLASH="data:text/html,<body style='background:%23181410;margin:0'><div style='height:100vh;display:flex;align-items:center;justify-content:center;font-family:Georgia,serif;color:%238a6a33;font-size:5vw'>Reconnecting&hellip;</div><script>var U='$URL';function p(){var x=new XMLHttpRequest();x.open('GET',U+'?t='+Date.now());x.timeout=4000;x.onload=function(){if(x.status==200)location.replace(U)};x.send()}setInterval(p,5000);p()</script></body>"
while true; do
  [ -f "\$PREF" ] && sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "\$PREF" 2>/dev/null
  mkdir -p /dev/shm/cchr
  if curl -s -m 5 -o /dev/null "\$URL"; then TARGET="\$URL"; else TARGET="\$SPLASH"; fi
  chromium-browser --kiosk --disable-component-update --font-render-hinting=none "\$TARGET" --incognito --noerrdialogs --disable-infobars --no-first-run     --disable-session-crashed-bubble --ozone-platform=x11 --disable-translate     --disable-features=TranslateUI --disable-ipc-flooding-protection --disable-background-networking     --disable-background-timer-throttling --disable-renderer-backgrounding --disable-sync     --disable-dev-shm-usage --disk-cache-dir=/dev/shm/cchr --disk-cache-size=536870912 --media-cache-size=536870912
  sleep 2
done
KIOSK
chmod +x $H/kiosk.sh

echo "--- $H/dashboard_output.sh (shared display-output detection with fallback) ---"
# 2026-08-04 audit lesson: an autostart that resolved its output with a bare connected-only
#   OUT=$(xrandr | awk '/ connected/{print $1; exit}')
# had NO fallback. When X starts while the panel is asleep/powered off, every connector reads
# 'disconnected', OUT comes back EMPTY, and the rotate silently no-ops — a portrait wall board
# comes back LANDSCAPE. Fall back to the first HDMI connector so rotation is always applied.
cat > $H/dashboard_output.sh <<'OUTS'
#!/bin/sh
# Echo the display output to drive. Prefers a truly-connected one; falls back to the first HDMI
# connector so a sleeping panel can never leave callers with an empty output name.
# POSIX sh ON PURPOSE, and sourced with '.' by openbox's autostart and the display watch.
# Openbox runs autostart under /bin/sh (dash) — a bash-ism here (BASH_SOURCE, arrays) is a hard
# parse error that kills the whole autostart, i.e. no rotate, no kiosk, black board.
dashboard_output(){
  o=$(xrandr 2>/dev/null | awk '$2=="connected"{print $1; exit}')
  [ -z "$o" ] && o=$(xrandr 2>/dev/null | awk '/^HDMI/{print $1; exit}')
  printf '%s' "$o"
}
# Print when executed directly; stay silent when sourced ($0 is the caller's path, not this file).
case "$0" in *dashboard_output.sh) dashboard_output; echo ;; esac
OUTS
chmod +x $H/dashboard_output.sh

echo "--- $H/dashboard_display_watch.sh (mode re-apply on panel return + RGB range) ---"
# The fallback above stops the output NAME coming back empty, but xrandr cannot set a MODE on a
# genuinely disconnected output. Proven 2026-08-04: X started with the panel powered off, the
# framebuffer sat at 320x200, and nothing re-applied the mode when the monitor came back — dark
# board until a reboot. This loop is the other half of the fix. It also re-asserts full-range
# RGB (Pi 4/Pi 5 KMS ignores hdmi_pixel_encoding; limited-range on a PC monitor = crushed
# blacks + washed whites) and self-heals a landscape board (xrandr --auto resets rotation).
cat > $H/dashboard_display_watch.sh <<DW
#!/bin/sh
export DISPLAY=\${DISPLAY:-:0}
. /home/pi/dashboard_output.sh
set_range(){ xrandr --output "\$1" --set "Broadcast RGB" "Full" 2>/dev/null || true; }
connected(){ [ -n "\$1" ] && xrandr 2>/dev/null | grep -qE "^\${1} connected"; }
O=\$(dashboard_output)
connected "\$O" && set_range "\$O"
while true; do
  O=\$(dashboard_output)
  if connected "\$O"; then
    G=\$(xrandr 2>/dev/null | sed -nE "s/^\${O} connected (primary )?([0-9]+x[0-9]+)\+.*/\2/p")
    W=\${G%x*}; Ht=\${G#*x}
    if [ -z "\$G" ]; then
      logger -t dashboard_display "\$O connected with no active mode -> --auto --rotate $ROTATE + full RGB"
      xrandr --output "\$O" --auto ${ROTATE:+--rotate $ROTATE} 2>/dev/null
      set_range "\$O"
    elif [ -n "$ROTATE" ] && [ "\$W" -gt "\$Ht" ] 2>/dev/null; then
      logger -t dashboard_display "\$O is landscape (\$G) -> re-applying --rotate $ROTATE + full RGB"
      xrandr --output "\$O" --rotate $ROTATE 2>/dev/null
      set_range "\$O"
    fi
  fi
  sleep 20
done
DW
chmod +x $H/dashboard_display_watch.sh

echo "--- $H/force_display_mode.sh (Pi 5 black-glass escape hatch) ---"
# Pi 5 has no fkms overlay and ignores hdmi_group/hdmi_mode, so legacy config.txt mode forcing
# does not exist there. The Pi 5 way to force a mode is the kernel cmdline. Run if the panel
# stays dark while SSH is alive:
#   sudo /home/pi/force_display_mode.sh                  -> 1920x1080@60, forced digital
#   sudo /home/pi/force_display_mode.sh off              -> remove the override
cat > $H/force_display_mode.sh <<'FDM'
#!/bin/bash
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
CMD=/boot/firmware/cmdline.txt
CONN="${DISPLAY_CONNECTOR:-HDMI-A-1}"
MODE="${1:-1920x1080@60D}"
cp -a "$CMD" "$CMD.bak.$(date +%s)"
# cmdline.txt must stay ONE line — strip any existing video= for this connector first.
NEW=$(tr -d '\n' < "$CMD" | sed -E "s/[[:space:]]*video=${CONN}:[^[:space:]]*//g")
if [ "$MODE" = off ]; then
  printf '%s\n' "$NEW" > "$CMD"
  echo "removed video= override for $CONN; reboot to apply"
else
  printf '%s video=%s:%s\n' "$NEW" "$CONN" "$MODE" > "$CMD"
  echo "set video=$CONN:$MODE ; reboot to apply"
fi
echo "cmdline is now:"; cat "$CMD"
FDM
chmod +x $H/force_display_mode.sh

echo "--- $H/screen_poll.sh (remote screen on/off + NONCE-based reboot/halt pull-control) ---"
# Remote control WITHOUT opening any inbound port on the board: the board POLLS the server.
# Screen on/off is a plain 0/1 state. Reboot/halt use a MONOTONIC NONCE: the server increments a
# counter when the button is pressed; the board acts on CHANGE, and SEEDS on first read (so a
# freshly booted board never re-executes the reboot that preceded its boot — acting on the
# nonce's VALUE instead of its change is a reboot loop).
cat > $H/screen_poll.sh <<POLL
#!/bin/bash
exec 9>/tmp/screen_poll.lock
flock -n 9 || exit 0
. /home/pi/dashboard_output.sh
SCREEN_URL="$DASHBOARD_SERVER/endpoint/dashboard-$BOARD-screen"
REBOOT_URL="$DASHBOARD_SERVER/endpoint/dashboard-reboot-nonce?board=$BOARD"
HALT_URL="$DASHBOARD_SERVER/endpoint/dashboard-halt-nonce?board=$BOARD"
OUT=\$(dashboard_output)
[ -n "\$OUT" ] && xrandr --output "\$OUT" ${ROTATE:+--rotate $ROTATE} >/dev/null 2>&1
LAST_SCREEN=""; LAST_REBOOT=""; LAST_HALT=""
while true; do
  V=\$(curl -s --max-time 5 "\$SCREEN_URL" | grep -o '"screen":[01]' | grep -o '[01]')
  if [ -n "\$V" ] && [ "\$V" != "\$LAST_SCREEN" ]; then
    O=\$(dashboard_output); [ -z "\$O" ] && O="\$OUT"
    if [ "\$V" = "0" ]; then xrandr --output "\$O" --off >/dev/null 2>&1
    else xrandr --output "\$O" --auto ${ROTATE:+--rotate $ROTATE} >/dev/null 2>&1; fi
    LAST_SCREEN="\$V"
  fi
  RN=\$(curl -s --max-time 5 "\$REBOOT_URL" | grep -o '"nonce":[0-9]*' | grep -o '[0-9]*\$')
  if [ -n "\$RN" ]; then
    if [ -z "\$LAST_REBOOT" ]; then LAST_REBOOT="\$RN"          # seed, never act on first read
    elif [ "\$RN" != "\$LAST_REBOOT" ]; then LAST_REBOOT="\$RN"; sudo /sbin/reboot; fi
  fi
  HN=\$(curl -s --max-time 5 "\$HALT_URL" | grep -o '"nonce":[0-9]*' | grep -o '[0-9]*\$')
  if [ -n "\$HN" ]; then
    if [ -z "\$LAST_HALT" ]; then LAST_HALT="\$HN"
    elif [ "\$HN" != "\$LAST_HALT" ]; then LAST_HALT="\$HN"; sudo /sbin/poweroff; fi
  fi
  sleep 2
done
POLL
chmod +x $H/screen_poll.sh

echo "--- openbox autostart (blank off + rotate with fallback + cursor hide + kiosk + pollers) ---"
mkdir -p $H/.config/openbox
cat > $H/.config/openbox/autostart <<OB
xset s off
xset -dpms
xset s noblank
# Port-agnostic portrait rotate. Two lessons baked in:
#  2026-07-31: a monitor on the far micro-HDMI port shows as HDMI-2, so an HDMI-1-only rotate
#    silently no-ops.
#  2026-08-04: when X starts while the panel is asleep, EVERY connector reads 'disconnected'
#    and a connected-only match yields an empty output — dashboard_output.sh falls back to the
#    first HDMI connector; dashboard_display_watch.sh re-applies the mode when the panel returns.
. /home/pi/dashboard_output.sh
OUT=\$(dashboard_output)
[ -n "\$OUT" ] && xrandr --output "\$OUT" ${ROTATE:+--rotate $ROTATE} 2>/dev/null
/home/pi/dashboard_display_watch.sh &
unclutter -idle 0 &
/home/pi/screen_poll.sh &
/home/pi/kiosk.sh &
OB
echo 'exec openbox-session' > $H/.xinitrc

echo "--- dashboard_watchdog.sh (layer 3) from the boot partition ---"
# The kit's watchdog is copied to /boot/firmware/ at flash time so this provisioner and the
# watchdog can never drift apart (the previous design embedded a verbatim copy with a
# "RE-SYNC THIS BLOCK" comment — a reflash from a stale kit reverted post-deploy fixes).
if [ -f /boot/firmware/dashboard_watchdog.sh ]; then
  sed "s|^DASHBOARD_SERVER=.*|DASHBOARD_SERVER=\"\${DASHBOARD_SERVER:-$DASHBOARD_SERVER}\"|" \
    /boot/firmware/dashboard_watchdog.sh > $H/dashboard_watchdog.sh
  chmod +x $H/dashboard_watchdog.sh
else
  echo "WARN: /boot/firmware/dashboard_watchdog.sh missing — layer 3 not installed"
fi
chown -R $U:$U $H/kiosk.sh $H/screen_poll.sh $H/dashboard_output.sh \
  $H/dashboard_display_watch.sh $H/force_display_mode.sh $H/.config $H/.xinitrc
[ -f $H/dashboard_watchdog.sh ] && chown $U:$U $H/dashboard_watchdog.sh

echo "--- Xorg blank-off snippet ---"
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-blanking.conf <<'XB'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
XB

echo "--- Xorg: force vc4 as the PRIMARY GPU (Pi 5 — REQUIRED, 2026-08-04) ---"
cat > /etc/X11/xorg.conf.d/20-vc4-primary.conf <<'VC4'
# Pi 5: without this X does not start AT ALL. Its autodetection reports
#   (II) no primary bus or device found
# and picks card0 = v3d, which is RENDER-ONLY and owns no display outputs. card1 (vc4, owns
# HDMI-A-1) is demoted to a secondary GPU, fbdev takes the primary, and X dies with:
#   (EE) Cannot run in framebuffer mode. Please specify busIDs for all framebuffer devices
# The same card0=v3d / card1=vc4-drm layout exists on Pi 4, where X autodetects correctly —
# so this is Pi 5 behaviour. Harmless on Pi 3B/Pi 4.
Section "OutputClass"
    Identifier "vc4 primary"
    MatchDriver "vc4"
    Driver "modesetting"
    Option "PrimaryGPU" "true"
EndSection
VC4

echo "--- config.txt display (full KMS, EDID-native mode, NO legacy hdmi_* forcing) ---"
CFG=/boot/firmware/config.txt
# Pi 4/Pi 5 KMS deltas — deliberately NOT set here: dtoverlay=vc4-fkms-v3d (no such overlay on
# Pi 5), hdmi_group/hdmi_mode/hdmi_pixel_encoding/hdmi_force_hotplug (legacy firmware options,
# ignored under KMS — verified inert on a Pi 4), gpu_mem (legacy split). If the panel will not
# sync, the fix is /home/pi/force_display_mode.sh (kernel cmdline), not this file.
grep -q "^dtoverlay=vc4-kms-v3d" $CFG || echo "dtoverlay=vc4-kms-v3d" >> $CFG
grep -q "^disable_overscan=1" $CFG || echo "disable_overscan=1" >> $CFG

echo "--- resilience: journald capped-persistent, tmpfs chromium profile, wifi powersave off ---"
# Journald: capped-persistent, NOT volatile. LESSON 2026-08-02: volatile journald destroyed the
# pre-incident evidence in BOTH freeze root-cause hunts. Raspberry Pi OS ships
# /usr/lib/systemd/journald.conf.d/40-rpi-volatile-storage.conf forcing volatile — drop-ins
# override journald.conf, so editing the main file silently no-ops. Use an /etc drop-in.
mkdir -p /etc/systemd/journald.conf.d /var/log/journal
printf '[Journal]\nStorage=persistent\nSystemMaxUse=512M\nMaxRetentionSec=30day\n' > /etc/systemd/journald.conf.d/99-persistent.conf
# tmpfs chromium profile: an SD-wear and crash-cleanliness measure — SD corruption is what has
# actually killed boards in this fleet. Size to taste for your RAM.
grep -q '/home/pi/.config/chromium' /etc/fstab || echo 'tmpfs /home/pi/.config/chromium tmpfs defaults,noatime,size=256M 0 0' >> /etc/fstab
# Powersave off — LESSON 2026-07-31: the NM connection is NOT named after your SSID
# (Imager/cloud-init names it e.g. "netplan-wlan0-<SSID>"), so targeting the SSID by name
# silently no-ops and powersave stays on — which dropped a board off wifi within hours.
# Resolve the real wifi connection name instead of assuming it.
WIFI_CON=$(nmcli -t -f NAME,TYPE connection show | awk -F: '$2 ~ /wireless/ {print $1; exit}')
[ -n "$WIFI_CON" ] && nmcli connection modify "$WIFI_CON" 802-11-wireless.powersave 2 connection.autoconnect yes || true

echo "--- SoC hardware watchdog via systemd ---"
sed -i 's/^#\?RuntimeWatchdogSec=.*/RuntimeWatchdogSec=14/' /etc/systemd/system.conf
grep -q '^RuntimeWatchdogSec=14' /etc/systemd/system.conf || echo 'RuntimeWatchdogSec=14' >> /etc/systemd/system.conf

echo "--- cron: layer-3 watchdog every 2 min ---"
( crontab -u $U -l 2>/dev/null | grep -v 'dashboard_watchdog.sh'; echo "*/2 * * * * /home/pi/dashboard_watchdog.sh" ) | crontab -u $U -

echo "--- console autologin on tty1 + startx ---"
raspi-config nonint do_boot_behaviour B2 || true
grep -q 'startx' $H/.bash_profile 2>/dev/null || cat >> $H/.bash_profile <<'BP'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then startx -- -nocursor; fi
BP
chown $U:$U $H/.bash_profile

echo "--- verify critical stack before done-flag ---"
# A half-configured board must NOT get the done-flag: first-boot hooks only fire once, so a
# flagged-but-broken install would never retry. On failure: no flag, no reboot — SSH is already
# up, fix remotely and re-run this script by hand.
VFAIL=0
for bin in chromium-browser startx openbox-session xdotool unclutter; do
  command -v "$bin" >/dev/null 2>&1 || { echo "VERIFY FAIL: $bin missing"; VFAIL=1; }
done
for f in $H/kiosk.sh $H/screen_poll.sh $H/dashboard_output.sh $H/dashboard_display_watch.sh $H/force_display_mode.sh; do
  [ -x "$f" ] || { echo "VERIFY FAIL: $f missing or not executable"; VFAIL=1; }
done
[ "$VFAIL" = "1" ] && { echo "=== firstboot INCOMPLETE $(date) — no done-flag, no reboot; ssh in, fix, re-run ==="; exit 1; }

echo "--- done; flag + reboot into the kiosk ---"
touch "$DONE"
echo "=== kiosk firstboot complete $(date) ==="
reboot
