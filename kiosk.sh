#!/bin/bash
DASHBOARD_SERVER="${DASHBOARD_SERVER:-http://192.0.2.10:1880}"
URL="${DASHBOARD_URL:-$DASHBOARD_SERVER/endpoint/dashboard}"
PREF="$HOME/.config/chromium/Default/Preferences"
# Self-healing splash (2026-07-31): a kiosk respawn during a Node-RED outage used to strand the
# board on a Chromium error page no watchdog tier could fix (the watchdog correctly skips while
# the heartbeat endpoint is down). If the dashboard is unreachable at (re)launch, load a local
# data-URL "Reconnecting" page that polls the endpoint every 5s and replaces itself with the real
# dashboard the moment the server answers. Palette matches the night-clock (dark warm + dim gold).
SPLASH="data:text/html,<body style='background:%23181410;margin:0'><div style='height:100vh;display:flex;align-items:center;justify-content:center;font-family:Georgia,serif;color:%238a6a33;font-size:5vw'>Reconnecting&hellip;</div><script>var U='$URL';function p(){var x=new XMLHttpRequest();x.open('GET',U+'?t='+Date.now());x.timeout=4000;x.onload=function(){if(x.status==200)location.replace(U)};x.send()}setInterval(p,5000);p()</script></body>"
while true; do
  [ -f "$PREF" ] && sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$PREF" 2>/dev/null
  mkdir -p /dev/shm/cchr
  if curl -s -m 5 -o /dev/null "$URL"; then TARGET="$URL"; else TARGET="$SPLASH"; fi
  chromium-browser --kiosk "$TARGET" --incognito --noerrdialogs --disable-infobars --no-first-run     --disable-session-crashed-bubble --ozone-platform=x11 --disable-translate     --disable-features=TranslateUI --disable-ipc-flooding-protection --disable-background-networking     --disable-background-timer-throttling --disable-renderer-backgrounding --disable-sync     --disable-dev-shm-usage --disk-cache-dir=/dev/shm/cchr --disk-cache-size=10485760 --media-cache-size=10485760
  sleep 2
done
