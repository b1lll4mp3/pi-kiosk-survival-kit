# pi-kiosk-survival-kit

Four independent watchdog layers that keep my Raspberry Pi wall dashboards alive without
me touching them. Each layer catches a failure class the layer below it is structurally
blind to. Plus byte-exact deploy verification and pull-based remote reboot control.

## The morning a Pi came back with no radio

2026-08-05, early. A Pi 3B wall board rebooted and came back up with its WiFi radio dead.
No SSH, no ping, nothing on the network. Historically that meant the board stayed dark
until somebody noticed and pulled the plug, which in my house had meant 8-hour and even
36-hour blind outages.

This time the log told a different story. Layer 3, the on-Pi watchdog running from cron
every 2 minutes, couldn't reach the heartbeat server, checked `wlan0`, found it missing,
and started counting strikes. At strike 3 it restarted NetworkManager. Still dead: the
radio needed its firmware reloaded, and no daemon restart can do that. At strike 6 it
invoked its guarded self-reboot. The board came back with a working radio, the kiosk
respawned, the page started beating, and every layer stood down.

Nobody touched anything. The whole event exists only as a syslog trail. That's what these
scripts are for.

## The four layers

```mermaid
flowchart TB
    subgraph pi [On the Pi]
        L1["Layer 1: in-page JS self-heal<br/>per-frame reload w/ backoff + heartbeat POST"]
        L2["Layer 2: kiosk.sh<br/>crash-respawn loop + reconnect splash"]
        L3["Layer 3: dashboard_watchdog.sh (cron */2)<br/>T1 reload -> T2 kill -> T3 reboot<br/>N-branch: wifi-dead strikes -> NM restart -> reboot"]
    end
    subgraph server [On a server]
        SRV["dashboard server<br/>(pages + heartbeat store)"]
        L4["Layer 4: dashboard_extwatch.sh (cron */5)<br/>heartbeat stale 30 min -> smart-plug power-cycle<br/>rate-limited per 6 h window"]
    end
    L1 -- "POST heartbeat every 30 s" --> SRV
    L3 -- "GET heartbeat age" --> SRV
    L4 -- "GET heartbeat age" --> SRV
    L4 -- "HA API: plug off/on" --> PLUG[smart plug] --> pi
```

The rule I designed against: every layer watches a signal the layer below can't fake, and
covers a failure the layer below can't fix.

### Layer 1: in-page self-heal (`extras/example-dashboard.html` shows the pattern)

Catches a single iframe or endpoint dying while the page itself is healthy. A transient
server blip at load time used to break all the frames at once, with no recovery until the
next meta-refresh. The in-page watchdog reloads failed frames with exponential backoff
(30 s → 5 min cap), and only allows a whole-page reload when every frame is broken, ≥5 min
apart, max 3 times. On a memory-tight Pi a reload loop is worse than the outage.

It also POSTs the heartbeat every 30 s. That's the signal every higher layer trusts,
because it can only exist if the page JS is actually running.

Blind to: its own death. If the renderer is wedged it can't run the JS that would heal it.

### Layer 2: `kiosk.sh`, crash-respawn plus splash

Catches Chromium exiting, whether from a crash, an OOM-kill, or layer 3's `pkill`. An
infinite loop relaunches the browser 2 s later, scrubbing the "restore session?" crash
flags first. And if the dashboard server is unreachable at (re)launch, it loads a local
data-URL "Reconnecting…" splash that polls the endpoint every 5 s and replaces itself with
the real page the moment the server answers. From the source, dated 2026-07-31:

> "a kiosk respawn during a Node-RED outage used to strand the board on a Chromium error
> page no watchdog tier could fix (the watchdog correctly skips while the heartbeat
> endpoint is down)."

Blind to: a browser that's alive but frozen. A wedged renderer never exits, so the respawn
loop never fires.

### Layer 3: `dashboard_watchdog.sh`, the workhorse

Catches the wedged renderer: Chromium alive, page JS frozen, heartbeat stale. Detection is
the heartbeat age, read from the server. Three escalation tiers, because a 1 GB board leaks
over multi-day uptime and a soft reload isn't always enough:

- T1 stale → `xdotool` ctrl+r (browser-level reload works even when page JS is frozen)
- T2 still stale → `pkill -9 chromium` (layer 2 respawns it fresh in ~2 s)
- T3 still stale ~10 min after T2 → guarded `sudo reboot`, rate-limited by a cooldown

Then there's the N-branch, the part that saved the 2026-08-05 morning. When the heartbeat
endpoint is unreachable, "do nothing" is only the right answer if the network is actually
fine, because rebooting a Pi can't fix a backend outage. So unreachable splits on `wlan0`
state. Here's the hard-won part: NetworkManager's word is not trusted. From the source:

> "2026-08-02 LESSON: NM can report wlan0 'connected' while the client is gone from the
> AP (assoc stale, no traffic passes)."

The board sat dark for 8 hours that night because this branch abstained on NM's word alone.

"Connected" now has to survive a second-opinion probe: a gateway ping (same-subnet ICMP is
fine) or a TCP connect to a DNS server's :53 on another subnet. Never a bare ping
cross-subnet. Segmented networks routinely filter ICMP between VLANs, and a filtered ping
reads exactly like a dead network. That false signal is what got the previous external
watchdog disabled. Both probes failing while NM says "connected" ⇒ net-dead ⇒ N-branch:
3 strikes → restart NetworkManager, 6 strikes → guarded reboot (a reboot reloads the
`brcmfmac` WiFi firmware, which an NM restart can't).

One more deliberate choice, from the script header. It's not `set -e`:

> "this script's normal flow runs commands that return non-zero (curl timing out is the
> trigger; pkill returns 1 when nothing matches). set -e would exit exactly when it
> should be recovering."

Blind to: a board that's past self-help. Hard freeze, dead cron, wedged SD card, kernel
panic. No on-board script survives all of those.

### Layer 4: `dashboard_extwatch.sh`, the off-Pi power-cycler

Catches everything above. It runs on a server, reads the same heartbeat age, and if a board
has been dark past the point where layer 3 must have played its whole hand (30 min), it
power-cycles that board's smart plug via Home Assistant: off, 8 s, on. The judgement calls:

- Heartbeat, not ping. The trigger is client-truth, the page's own beat. The previous
  external layer triggered on cross-VLAN ping and got disabled for false alarms, and its
  absence is why one board sat dark for 8 hours.
- Rate limits: max 2 cycles per 6 h window per board, minimum 15 min between cycles. Once
  that's exhausted it alerts instead. This guards the SD card and stops a cycle-loop on a
  board that can't boot at all, like a dead card or a dead PSU.
- It abstains when the heartbeat server itself is down, because then no board can be
  judged, and falls back to a TCP :22 probe when the server restarted and has no beat on
  record.
- It pushes to an Uptime-Kuma-style push monitor on every healthy run, so the watchdog's
  own death raises an alert.
- Boards without a plug still get alert-only coverage. The comment block preserves the
  incident where a board left out of the table stayed dark 36 h while the page monitor
  stayed green.

Blind to: nothing short of the power grid. That's the job of being layer 4.

## The supporting cast

- `canary_baseline.sh`, deploy verification in bytes instead of 200s. It captures the exact
  payload byte-count of every endpoint a fragile board loads, plus its memory, swap, and
  thermal state over SSH. Run it before and after a change. **Any delta is stop-the-line.**
  Why not status codes or timing? Per-board content gating fails silently, so a missed gate
  returns 200 with the wrong bytes. And per the source, under-voltage causes ARM frequency
  scaling, so timing lies on a browning-out board. Bytes are clock-independent.
- Nonce-based reboot/halt pull-control, in `firstrun-kiosk.sh`'s `screen_poll.sh`. Remote
  reboot with no inbound port on the board. It polls a monotonic nonce and acts on the
  change, seeding on first read. Acting on the value would re-execute the reboot that
  preceded the boot, which is a reboot loop.
- `dashboard_output.sh` and `dashboard_display_watch.sh` do display self-config: output
  detection that falls back to the first HDMI connector (X starting while the panel sleeps
  reads every connector as disconnected, and a connected-only match brings a portrait board
  up landscape), a loop that re-applies the mode when the panel returns (xrandr can't set a
  mode on a disconnected output), rotation self-heal, and full-range RGB re-assertion on
  KMS boards.
- `firstrun-kiosk.sh` is unattended first-boot provisioning that wires all of the above into
  a fresh Pi OS Lite card. It carries its own scar tissue. Wait for clock sync before apt,
  because a Pi has no RTC and a stale clock both fails repo signature checks and 404s the
  pool. `apt-get update` has to succeed or no done-flag gets written. Journald gets
  persistent-but-capped storage via an `/etc` drop-in, because Pi OS forces volatile with a
  vendor drop-in and volatile journald destroyed the evidence in two separate freeze
  investigations. WiFi powersave goes off by resolving the real NM connection name. And the
  whole stack gets verified before the done-flag lands, so a half-configured board retries
  instead of bricking politely.

## Quickstart

```bash
# On the Pi (or bake it in with firstrun-kiosk.sh at flash time):
export DASHBOARD_SERVER=http://your-server:1880       # see .env.example
cp kiosk.sh dashboard_watchdog.sh dashboard_output.sh dashboard_display_watch.sh /home/pi/
crontab -l | { cat; echo "*/2 * * * * /home/pi/dashboard_watchdog.sh"; } | crontab -

# Your dashboard page: add the heartbeat POST + fitGuard (see extras/example-dashboard.html)

# Server side: two endpoints
#   POST /endpoint/dashboard-heartbeat   -> store now()
#   GET  /endpoint/dashboard-heartbeat   -> {"ago_s": <seconds since last beat>}

# On an always-on box (layer 4):
cp dashboard_extwatch.sh /usr/local/bin/
# edit the BOARDS table + point ENV_FILE at a file exporting HA_TOKEN
crontab -l | { cat; echo "*/5 * * * * /usr/local/bin/dashboard_extwatch.sh"; } | crontab -

# Before/after any change to a fragile board:
./canary_baseline.sh > before.txt   # ...deploy... ; ./canary_baseline.sh > after.txt
diff before.txt after.txt           # ANY delta is stop-the-line
```

## Design decisions, and why

- Independent layers, not one smart daemon. Every failure in here was found because a
  previous layer didn't cover it. A single supervisor is a single point of blindness. Four
  dumb layers with disjoint vantage points caught a dead radio, a wedged renderer, a
  stranded error page, and a hard freeze, each within minutes.
- The heartbeat is the only signal I trust. Process-alive, port-open, ping, and
  NetworkManager state have all lied to me at some point in this fleet's history. "The
  page's JS posted within 120 s" is the one proxy that implies everything upstream works.
- Second opinions before anything destructive. NM state gets a traffic probe. A missing
  heartbeat record gets a TCP :22 tiebreaker. T3 and N2 reboots sit behind cooldowns, and
  plug cycles are windowed. Every escalation is cheap to be wrong about once, and guarded
  against being wrong repeatedly.
- `flock` on every cron entrant. A hung curl plus a */2 cron otherwise stacks instances.
- Log context on every action. The watchdog stamps SoC temperature and throttle flags on
  each event, because a hot, throttled SoC stretches JS execution and looks a lot like a
  wedge. The log can rule that in or out afterwards.

## Limitations

- The heartbeat server is a trusted dependency. Layers 3 and 4 both abstain when it's down,
  which is correct (rebooting Pis can't fix a server) but does mean a simultaneous
  server-plus-board failure needs a human.
- Layer 4 needs Home Assistant, or any HTTP API you can adapt `ha_call` to, plus a smart
  plug per board you want auto-cycled. Plugless boards get alert-only coverage.
- The N-branch assumes `wlan0` and NetworkManager, i.e. stock Pi OS. Ethernet-attached or
  `wpa_supplicant`-managed boards need the `wifi_state()` function adapted.
- The `xdotool`-based T1 assumes X11. Under Wayland or labwc you'll need a different reload
  mechanism, or just lean on T2's kill-and-respawn, which is compositor-agnostic.
- Power-cycling is hostile to SD cards. The rate limits reduce that risk, they don't
  eliminate it. Use decent cards and the tmpfs-profile mitigation in `firstrun-kiosk.sh`.
- The scripts self-heal one board at a time and don't coordinate. A fleet-wide server outage
  produces N boards politely abstaining, which is correct but silent, so monitor the server
  separately.

## License

MIT, see [LICENSE](LICENSE).
