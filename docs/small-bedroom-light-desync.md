# Bedroom lights: physical state vs. HA state (`Delivery failed` on Hue bulbs)

Investigation 2026-10-11 on **grafton-router**. The symptom: turning on the
Small Bedroom Light with a Google speaker made the bulb come on, but Home
Assistant showed it off and the circadian brightness/colour did not apply;
toggling it in HA then made circadian apply. Same pattern reported "a few
times".

## Why HA can be right about the command and wrong about the state

HA is a relay, not the source of truth for a Zigbee light. The two directions
are independent:

```
Google  ->  HA google_assistant  ->  HA light.turn_on
              ->  MQTT zigbee2mqtt/<light>/set  ->  Z2M  ->  Zigbee  ->  bulb
HA state  <-  MQTT zigbee2mqtt/<light>           <-  Z2M  <-  Zigbee report <- bulb
```

HA marks the light `on` only when the **bulb reports back**. It never assumes
the command worked. If the command reaches the bulb but the acknowledgement /
state report is lost, the bulb is physically on while HA still holds `off`, and
the circadian switch sees no `off → on` transition so never applies. Toggling
in HA re-sends the command; when that round-trip completes, HA sees the change
and circadian fires.

## Evidence

Z2M `set` commands to the two bedroom Hue ceiling lights fail constantly. Over
36 h (`journalctl -u podman-zigbee2mqtt`):

```
1088  Publish 'set' 'brightness' to 'Back Bedroom Ceiling Light' failed
  10  Publish 'set' 'brightness' to 'Small Bedroom Ceiling Light' failed
   2  Publish 'set' 'state'      to 'Small Bedroom Ceiling Light' failed
```

Typical:

```
genOnOff.on(...) failed (Delivery failed for '16606'.)
moveToLevelWithOnOff(...) failed ({...} timed out after 10000ms)
lightingColorCtrl.moveToColorTemp(...) failed (Delivery failed for '16606'.)
```

The HA recorder shows the state arriving late:

- `02:22:22` Z2M `on` → `Delivery failed`
- `02:23:08` HA finally records `on` (then bounces `on/off/on`)
- `00:56:00` Z2M `on` → `Delivery failed for '16606'`
- `00:56:07` HA records `on`; `00:56:08` two `reportState … 403` lines

Coordinator: EmberZNet **8.0.2**, Zigbee **channel 11**, serial via
`tcp://192.168.49.31:6638` (`ser2net`). 21 devices: 14 routers / 6 end devices.
Z2M **2.14.2**.

## Fixes applied

### 1. Z2M availability enabled (`/srv/zigbee2mqtt/configuration.yaml`)

`availability.enabled` was **false**, so an unreachable bulb kept its stale
`on`/`off` in HA instead of going `unavailable`. Added:

```yaml
availability:
  enabled: true
```

Requires restart (`requiresRestart: true`) — `sudo systemctl restart
podman-zigbee2mqtt`. This only adds a per-router ping every ~10 min (with
jitter + backoff); battery devices use passive tracking. It immediately
surfaced the truth:

```
zigbee2mqtt/Back Bedroom Ceiling Light/availability   {"state":"offline"}
zigbee2mqtt/Front Bedroom Corner Light/availability   {"state":"offline"}
zigbee2mqtt/Small Bedroom Ceiling Light/availability  {"state":"online"}
```

Backup kept at `configuration.yaml.bak-<timestamp>`.

### 2. `sleep_colortemp` raised to the bulb minimum (HA `configuration.yaml`)

All three circadian switches had `sleep_colortemp: 1000` (K). The Hue bulb's
minimum is 2000 K, so every sleep command was clamped to 500 mireds anyway.
Changed `1000 → 2000` (no visual change; takes effect on the next HA start).
Backup kept at `configuration.yaml.bak-<timestamp>`; `check_config` passes.

## Google Report State 403 — separate bug, needs one console click

`google_assistant.report_state` has been failing since at least 2026-10-09:

```
Request for https://homegraph.googleapis.com/v1/devices:reportStateAndNotification failed: 403
Request for .../devices:requestSync failed: 403
```

The `google.json` service-account key is **valid** — reproducing the call from
inside the HA container returns the real reason:

```
HomeGraph API has not been used in project 962914725848 before or it is disabled.
Enable it by visiting
https://console.developers.google.com/apis/api/homegraph.googleapis.com/overview?project=962914725848
then retry.   (status PERMISSION_DENIED, reason SERVICE_DISABLED)
```

This only breaks the outbound HA→Google state cache (Home app/speaker can show
stale state). It does **not** block EXECUTE commands reaching HA, so it is not
why HA's own state was stale. Fix = enable the HomeGraph API on project
`962914725848` (console, with the owning Google account).

## Remaining RF recommendations (not applied — need physical decisions)

- **Zigbee channel 11 overlaps Wi-Fi channel 1.** If the APs (`.2`/`.3`) sit on
  1/6/11, moving Zigbee to 15/20/25 is the classic fix. A channel migration is
  done from the Z2M UI; it generally works but can leave sleepy end devices
  needing a wake/re-pair, so it was deliberately not done unattended.
- The two failing bulbs are mains Hue routers, and Back Bedroom is now
  consistently `offline`. Confirm they aren't on a switched socket / wall
  switch that cuts power — no software fix recovers a powered-off radio.
- A network map (`zigbee2mqtt/bridge/request/networkmap`) will show whether
  their routes are weak.

## Verify

```sh
# availability + who is offline
mosquitto_sub -h 192.168.49.1 -u user -P pass -t 'zigbee2mqtt/+/availability' -v -W 5
# delivery failures
journalctl -u podman-zigbee2mqtt --since '30 min ago' | grep -i 'failed'
# current light state
mosquitto_sub -h 192.168.49.1 -u user -P pass -t 'zigbee2mqtt/Small Bedroom Ceiling Light' -W 3
```
