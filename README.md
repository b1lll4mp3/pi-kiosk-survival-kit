# pi-kiosk-survival-kit

Four independent watchdog layers that keep my Raspberry Pi wall dashboards alive without
me touching them. Each layer catches a failure class the layer below it is structurally
blind to. Plus byte-exact deploy verification and pull-based remote reboot control.

## The morning a Pi healed its own radio

2026-08-05. I rebooted a Pi 3B wall board on purpose, partway through a rename migration,
and it came back up with its WiFi radio dead. No SSH, no ping, nothing on the network.
Historically that meant the board stayed dark until somebody noticed and pulled the plug,
which in my house had meant 8-hour and even 36-hour blind outages.

This time the log told a different story. Layer 3, the on-Pi watchdog running from cron
every 2 minutes, couldn't reach the heartbeat server, checked `wlan0`, found it missing,
and started counting strikes. At strike 3 it restarted NetworkManager. Still dead: the
radio needed its firmware reloaded, and no daemon restart can do that. At strike 6 it
invoked its guarded self-reboot, which landed at 10:58. The board came back with a working
radio, the kiosk respawned, and every layer stood down.

Let me be precise about what was unattended here, because it's easy to oversell. The event
wasn't: I triggered that reboot, I was sitting there watching, and I logged the whole thing
as a live end-to-end validation of the rename. The recovery was: I never touched the board,
nothing I did healed it, and it put itself back on the network.

On that same day a different board in the same fleet sat dark for 7.5 hours. Its
provisioning kit had installed a 1699-byte watchdog with no wifi self-heal in it at all: no
`net_alive()`, no NetworkManager restart, no recovery reboot. So it logged
"unreachable, skip" every two minutes for seven and a half hours while the branch that
would have rescued it sat in the repo the whole time. That's the strongest argument I have
for the drift checking further down.

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

### Layer 1: in-page self-heal

Catches a single iframe or endpoint dying while the page itself is healthy. A transient
server blip at load time used to break all the frames at once, with no recovery until the
next meta-refresh. The in-page watchdog reloads failed frames with exponential backoff
(30 s → 5 min cap), and only escalates to a whole-page reload when every frame is broken,
rate-limited to once per 5 minutes. There's no cap on how many times it escalates.

There used to be one: three whole-page reloads, then permanent give-up, on the theory that
a reload loop is worse than the outage on a memory-tight Pi. A real outage reversed that
reasoning. On 2026-07-24 an all-frames-down stretch outlasted the three reloads, the page
gave up while everything was still broken, and the board then sat dead for up to an hour
waiting on the meta-refresh. So the give-up is gone. Rate-limited retries continue for as
long as it's all-down, and the Pi-side watchdog is the real backstop for a wedged
renderer, since this JS can't run in that case anyway.

`extras/example-dashboard.html` shows the heartbeat POST and the fitGuard, not the frame
self-heal. There's no frame health check, no backoff and no whole-page escalation in the
demo, so treat it as the heartbeat half only.

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
- T3 still stale 10 min after the FIRST detection → guarded `sudo reboot`, rate-limited by
  a cooldown. That 600 s clock gets stamped at T1 and carried through T2 unchanged, so it
  measures time since first stale, not time since the kill

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

Blind to: a panel that refuses to sync. Since 2026-08-05 that's the one failure I know none
of the four layers catch. The board renders, the page keeps beating, `xrandr` geometry
reads correct, the HTTP monitor says 200, `scrot` captures a perfect frame, and the glass
is black. That one cost me 7.5 hours dark. Nothing on the board and nothing on the network
can see it, which is why my standing rule is that only human eyes close a glass case.

## The supporting cast

- `canary_baseline.sh`, deploy verification in bytes instead of 200s. It captures the exact
  payload byte-count of every endpoint a fragile board loads, plus its memory, swap, and
  thermal state over SSH. Run it before and after a change. **Any delta is stop-the-line.**
  Why not status codes or timing? Per-board content gating fails silently, so a missed gate
  returns 200 with the wrong bytes. A related lesson from the same fleet, for anything you
  cache server-side: validate cached bytes on the read path, not just at write time. I had
  a frame cache that JSON-round-tripped a Buffer and served `{"type":"Buffer",...}` as a
  4.4 MB `image/jpeg`, out of a 1.2 MB frame, while every status, content-type and
  freshness monitor stayed green. A
  freshness alarm that has never once gone red is a claim, not a control. And per the
  source, under-voltage causes ARM frequency
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
  KMS boards. The display watcher also carries a mode-escalation guard: it records the
  first known-good mode and refresh rate, and if the panel ever comes back at something
  else it shouts and restores. What put it there wasn't a power blip. I set
  `hdmi_enable_4kp60` to bring a 311 MHz pixel clock inside the envelope, which raised the
  core clock from 500 to 550 MHz, which unlocked 120 Hz and 144 Hz modes that had been
  unreachable before, and X auto-selects the highest preferred mode. The link couldn't
  carry the one it picked. Geometry still read correct and only the refresh rate had
  moved, so it looked healthy from everywhere except the glass. The generalisable version:
  raising a ceiling changes what gets selected, so a capability change and a selection pin
  are one change, never two.
- `firstrun-kiosk.sh` is unattended first-boot provisioning that wires all of the above into
  a fresh Pi OS Lite card. It carries its own scar tissue. Wait for clock sync before apt,
  because a Pi has no RTC and a stale clock both fails repo signature checks and 404s the
  pool. `apt-get update` has to succeed or no done-flag gets written. Journald gets
  persistent-but-capped storage via an `/etc` drop-in, because Pi OS forces volatile with a
  vendor drop-in and volatile journald has now destroyed the evidence in three separate
  incidents on this fleet, the third on a board this kit had not provisioned. WiFi powersave
  goes off in two places: the real NM connection name (resolved, because the guessed name
  silently no-ops) and a global drop-in, so a connection profile created later by a reflash
  or an SSID change doesn't start with powersave back on. And a
  verify gate runs before the done-flag lands, so a half-configured board retries instead
  of bricking politely. Read that gate narrowly though: it checks 5 binaries and 5 scripts,
  and `dashboard_watchdog.sh` is not one of them. A missing layer 3 only prints
  `WARN: layer 3 not installed` and the board still gets its flag and reboots into a
  perfectly good kiosk with no watchdog on it. So the gate covers the kiosk stack, not the
  whole stack.

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
  stranded error page, and a hard freeze. The in-page and on-Pi layers act in minutes (a
  stale beat is 120 s, a guarded reboot is 10 min from first detection). Layer 4 deliberately
  does not: it waits 30 min before cutting power, because the layers below it should be
  allowed to finish first.
- The heartbeat is the only signal I trust. Process-alive, port-open, ping, and
  NetworkManager state have all lied to me at some point in this fleet's history. "The
  page's JS posted within 120 s" is the one proxy that implies everything upstream works.
- Second opinions before anything destructive. NM state gets a traffic probe. A missing
  heartbeat record gets a TCP :22 tiebreaker. T3 and N2 reboots sit behind cooldowns, and
  plug cycles are windowed. Every escalation is cheap to be wrong about once, and guarded
  against being wrong repeatedly.
- No per-board defaults in a script that's meant to be identical everywhere.
  `dashboard_watchdog.sh` derives its `BEAT_URL` from the hostname and refuses to run on a
  host it doesn't recognise. It used to default to one specific board's endpoint, so when I
  synced it onto a second board that board's watchdog quietly watched the first board's
  heartbeat. That's worse than having no watchdog at all: it sees a healthy beat, never
  acts, and looks completely fine in the log. Hostname-derived config is also what makes a
  fleet-wide checksum possible, because the canon copy now has no per-board edits in it.
- Your copy of this kit will drift, so plan for it. Mine did. The rule "diff the kit's
  embedded scripts against the repo before any reflash" existed for a day before it bit me,
  because I'd applied it to one kit and not the other, and the second kit went on shipping a
  watchdog with no wifi self-heal. So `firstrun-kiosk.sh` no longer embeds a verbatim
  watchdog. It copies the one sitting in `/boot/firmware` at flash time, which means the
  provisioner and the watchdog can't drift apart by construction. On my side there's also a
  checksum script that compares every board's canon scripts and every kit's embedded copies
  against the repo, exit 1 on drift, run weekly. An embedded copy inside a provisioning kit
  is how a board gets reflashed back to a version missing a fix you already shipped.
- `flock` on every cron entrant. A hung curl plus a */2 cron otherwise stacks instances.
- Log context on every action. The watchdog stamps SoC temperature and throttle flags on
  each event, because a hot, throttled SoC stretches JS execution and looks a lot like a
  wedge. The log can rule that in or out afterwards.

## Rules for the UI itself, not just the box

The four layers keep the board alive. These are what I learned about what the board draws,
and each one cost me something.

**Name the layer you actually observed to fail.** A panel of mine displayed "Home Assistant
unreachable" for hours while Home Assistant was perfectly healthy: the Pi had fallen off
WiFi. The banner was written from a `fetch` rejection, and a rejection tells you only that
your own network died. It cannot tell you anything about the far end, because nothing
reached the far end. Only an actual response, including an error response, proves you got
there. So a rejection now reads "panel offline, check its network", and a non-2xx reads
"the far end answered badly". Getting this backwards produces a confidently wrong diagnosis
pointing at a healthy system, which is worse than no banner at all.

**Loud elements need a staleness cutoff; quiet ones don't.** Keeping the last known state
on screen is fine for a small status pill and unacceptable for anything animated. A hung
backend that leaves a wall display strobing a motion alert forever trains everyone in the
house to ignore it. Anything attention-grabbing gets a hard cutoff (mine is 60 s) after
which it returns to neutral rather than holding its last value.

**Animate opacity and nothing else.** On the 1 GB Pi 3B a flashing outline measured 24.4%
CPU against a 20.9 to 25.2% idle baseline, which is inside the noise. That is only true
because it animates opacity, which the compositor handles. Animate anything that triggers
layout or paint and the weakest board in the fleet starts dropping frames on a page whose
whole job is to be glanceable.

**Ship a forcing flag with every conditional element.** Anything that only appears under a
real-world condition is nearly untestable on the glass, so add a query flag that forces it
on (`?ringtest=1` here). This is the closest thing I have to a fix for the dark-glass blind
spot above: it can't tell you the panel is lit, but it lets a human standing in the room
confirm a rare state renders correctly without waiting for the condition.

**Test the served page, not a copy of it.** My harness fetches the live endpoint and
executes its script under a stubbed clock, so identity with production is structural rather
than assumed. Given how much of this kit is about copies drifting from originals, testing a
local copy of a page would have been a joke.

One honest caveat on all of the above: a passing headless harness proves the logic, never
the pixels. Mine would pass with the element rendered invisible.

## Limitations

- Nothing in here can see a panel that refuses to sync. The board renders, the heartbeat
  arrives, `xrandr` geometry and `scrot` both look perfect, the HTTP check is 200, and the
  glass is black. That failed silently on me for 7.5 hours. Only a human eye or a camera
  closes that case, and the mode-escalation guard catches the trigger at best, never the
  dark panel itself.
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
