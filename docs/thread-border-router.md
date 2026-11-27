# Thread border router on grafton-router (Sonoff ZBDongle-P → Matter over Thread)

Adopted 2026-11-26 — **status: radio flashed & verified, awaiting relocation to the
router.** At the time of writing the stick sat on zen3-nixos: enumeration + chip checks
below, `ot_rcp` flashed, `otbr-agent --radio-version` answered `OPENTHREAD/1.4.0-Koenkk-
2025.3.1; CC13XX_CC26XX`. The grafton-router service config is live (identity = the
dongle's CP2102N serial, any USB socket works); what remains is plug it into the router,
rebuild, and the Home Assistant UI steps.
Home Assistant and python-matter-server have run on
grafton-router for a long time (containers in `home-assistant.nix`), but
without a Thread border router (TBR) no Matter-over-Thread device could ever
be commissioned. This adds the missing half: a spare **Sonoff ZBDongle-P**
(TI **CC2652P10**, shield silkscreen "C2652P") flashed to OpenThread **RCP**
firmware, driven by an **OTBR** container on the router, wired into HA via the
`otbr` → `thread` → `matter` integration chain.

## The stick (inspected 2026-11-26 on zen3)

- USB: `10c4:ea60` CP2102N, ITead "Sonoff Zigbee 3.0 USB Dongle Plus", **unique
  serial `d01311ed57c9eb1198a28b4f1d69213e`** → udev pins the serial, so the
  service no longer cares which socket it is in. (Earlier P revisions used a
  serial-less CH340 `1a86:7523` — those need port pinning; this one does not.
  If the stick is ever swapped, update `rcpSerial` in `services/otbr.nix`.)
- CC2652P10 confirmed via TI serial bootloader (cc2538-bsl reports it with the
  benign "CC1350 PG2.0 (7x7mm): 352KB Flash" mislabel — same silicon ID; the
  geometry and `CC13XX_CC26XX` platform string settle it). Factory IEEE address
  intact: `00:12:4B:00:24:BC:1A:83`.
- The app flash area was **blank when found** (all `ff`): this stick had no
  coordinator firmware at all, so the RCP flash destroyed nothing.

## Why this particular firmware path (the confusing part)

- Sonoff's own product pages claim Thread/Matter for the "Dongle series" and
  their Matter-over-Thread guide even lists the ZBDongle-P — but the
  **firmware catalogue that actually backs their flasher**
  ([iHost-Open-Source-Project/hassio-ihost-sonoff-dongle-flasher](https://github.com/iHost-Open-Source-Project/hassio-ihost-sonoff-dongle-flasher)
  `firmware-build/FIRMWARE_LIST.json`, verified 2026-11-26) ships OpenThread
  only for the Silicon Labs chips (`.gbl` for MG21/MG24) and **Zigbee-only for
  the CC2652P**. The "OpenThread RCP 460800" entries for CC-prefixed dongles
  belong to the newer Dongle-PP10 (CC2674P10), not this stick.
- The supported community path for TI sticks: **Koenkk** (zigbee2mqtt maintainer,
  author of the standard Z-Stack images everyone flashes for these boards)
  maintains a maintained OpenThread fork [Koenkk/ot-ti](https://github.com/Koenkk/ot-ti)
  and publishes RCP images at
  [Koenkk/OpenThread-TexasInstruments-firmware](https://github.com/Koenkk/OpenThread-TexasInstruments-firmware).
  `docs/adapters.md` there lists **SONOFF ZBDongle-P** under
  `CC1352P2_CC2652P_launchpad_ot_rcp_*` — same launchpad-style PA wiring
  convention as the Z-Stack "launchpad" coordinator builds.
- Release used: **2025.3.1** (latest as of 2026-11-26),
  `CC1352P2_CC2652P_launchpad_ot_rcp_2025_3_1.zip`
  sha256 `5858a338f4d82e11a269410a9917561e91a5130fe3d6207dfc7066b0ed9e7e1d`,
  inner hex sha256 `75330d9294629feb72d401a2ec73f8a886f822d1de2b74a513758e19494f7e9f`.
  Runs spinel/HDLC over UART at **460800 8N1, no hardware flow control**.
- ⚠️ Known-rough spot: one 2025 discussion
  ([OpenThread-TexasInstruments-firmware#4](https://github.com/Koenkk/OpenThread-TexasInstruments-firmware/discussions/4))
  reported OTBR losing the RCP when a Thread device joined on a ZBDongle-P;
  the reporter "solved" it by buying an MG21 stick and the issue was closed
  without a root cause. Related open issues (#6, #7) cover other CC2652 boards.
  Treat CC2652P-as-TBR as *works, with a caveat*; if mesh joins prove flaky,
  the firmware is fine to abandon — any Koenkk Z-Stack "launchpad" coordinator
  hex flashed the same way puts the stick back to Zigbee.

## Flashing

`scripts/flash-thread-rcp.sh` (run on the box the dongle is plugged into;
the firmware download + sha256 pinning are inside). Plug the stick in and
flash it **before** setting `rcpPort` in `services/otbr.nix`, so the otbr
container is inert and nobody holds the port while the bootloader talks:

```sh
./scripts/flash-thread-rcp.sh probe PORT=/dev/ttyUSB0   # what is it, who holds it
sudo ./scripts/flash-thread-rcp.sh flash                 # BSL entry + erase/write/verify
```

Mechanics: `nixpkgs`'s `cc2538-bsl` with `--bootloader-sonoff-usb` — it toggles
DTR/RTS in the pattern that resets a Sonoff board straight into the TI serial
bootloader, so no case opening, no soldering, no debug probe. Run 2026-11-26 on
zen3: mass-erase + 360448 bytes @0x0 + CCFG write, CRC32 verify match
`0x3427c0fa`; afterwards the pinned image's own tool validated the radio:

```
$ podman run --rm --entrypoint /usr/sbin/otbr-agent --device /dev/ttyUSB0:/dev/rtest \
    $OTBR_IMAGE --vendor-name OpenThread --model-name BorderRouter \
    --radio-version "spinel+hdlc+uart:///dev/rtest?uart-baudrate=460800"
OPENTHREAD/1.4.0-Koenkk-2025.3.1; CC13XX_CC26XX; Mar 13 2025 20:18:49
```

(`otbr-agent --radio-version` is the authoritative RCP liveness probe —
worth knowing when debugging a "silent" stick. A hand-rolled spinel PING is a
bad substitute: this build answers a framed RESET but not naive PING/GET
frames, see OT's extended-header transaction semantics.)
Rollback: flash `CC1352P2_CC2652P_launchpad_coordinator_*.hex` (Koenkk
Z-Stack-firmware) with the same command minus the ot_rcp URL.

## Host side — `hosts/grafton-router/services/otbr.nix`

- udev: `SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60",
  ATTRS{serial}=="d01311ed…"` → `/dev/otbr-rcp`. The CP2102N revision carries
  a unique serial, so this matches exactly our stick in any socket, and the
  other serial adapters on the box (an idle CH340 on 1-7, an FTDI) can never
  be grabbed. Empty `rcpSerial` in the module = fully inert (no rule, no
  container).
- Container: `docker.io/openthread/border-router` **pinned by digest**
  (2026-11-24 build), `--network host --privileged`, devices `/dev/otbr-rcp` +
  `/dev/net/tun`. The image's s6 `otbr-agent` run script reads `OT_*` env vars
  (authoritative: `etc/docker/border-router/` in the ot-br-posix repo):
  `OT_RCP_DEVICE=spinel+hdlc+uart:///dev/otbr-rcp?uart-baudrate=460800`,
  `OT_INFRA_IF=lan`, `OT_THREAD_IF=wpan0`, REST on **127.0.0.1:8081**.
- State: the agent symlinks `/var/lib/thread → /data/thread`, so the mesh lives
  in `/srv/otbr/thread` — the router's nightly borg `backup-srv` job archives
  `/srv`, so it is automatically in backup (verified: timer active). Losing
  this means recreating the Thread network (and re-commissioning every device).
- It also inserts its own `ip6tables` ingress filter (`OT_FORWARD_INGRESS`)
  and the `FORWARD` accepts for egress — that is expected, not stray rules;
  and it starts a **TREL** interface on `lan` alongside the radio.
- Firewall: `forward` on this router is `policy drop`; `networking/firewall.nix`
  gained the explicit `lan ↔ wpan0` pair (comments there explain the division
  of labour with otbr's own ingress chain). Without it the BR runs happily and
  the mesh is silently black-holed in both directions.
- `systemd.services.podman-otbr` is forced `Restart=always` — podman refuses to
  create a container with a missing `--device`, so the unit just retries every
  10 s until the dongle is plugged in again.

## Home Assistant side (one-time, UI)

HA here is `linuxserver/homeassistant` (container), so **not** the HAOS OTBR
add-on — the equivalent core-integration route:

1. Settings → Integrations → add **OpenThread Border Router** (`otbr`), URL
   `http://127.0.0.1:8081` (HA is host-networked, so that is the otbr-agent
   on loopback).
2. The **Thread** integration then surfaces automatically (or after a HA
   restart). Open the Thread network's ⋮ menu → **set as preferred network**.
3. matter-server is already running (`home-assistant.nix`, BLE `--bluetooth-adapter 0`
   = hci0). Settings → Devices & Services → **Matter** → Add Matter device →
   scan/paste the QR; for Thread devices HA now offers the mesh via the
   preferred Thread network. Phones (Android companion → "Sync Thread
   credentials"; iOS just works once the phone is on the LAN Wi-Fi) can add
   devices directly too — the phone reads the dataset from the Thread
   integration, the BLE work is done by HA's server-side Bluetooth.

## Deployment incident, 2026-11-27 (read before touching otbr.nix)

The first switch half-succeeded and then rolled itself back:

1. `switch-to-configuration` **starts new enabled units during activation** —
   `podman-otbr` was one, and the udev symlink did not exist at that moment
   (rules were written to /etc but the running tty device had never been
   re-triggered), so podman errored (`stat /dev/otbr-rcp: no such file`), the
   start-unit failed, and the switch aborted **after** the profile symlink had
   already moved to the new generation.
2. Five minutes later the auto-rollback timer saw `profile ≠ system-good` and
   **rebooted the router back to the last confirmed generation** — as designed,
   but it means a failing service unit on this host does not merely "fail
   softly", it reverses the whole deployment.
3. The container itself then crash-looped on `hdlc_interface.cpp:157 ... No
   such file or directory`: podman resolves SYMLINK `--device` sources, so the
   node landed in the container as `/dev/ttyUSBn`, not `/dev/otbr-rcp`.

Fixes now in the module: `podman-otbr` is `wantedBy = [ ]` and is pulled only
by the udev rule (`RUN+="systemd"` + `ENV{SYSTEMD_WANTS}="otbr-rcp-plug.service"`
— udev's own device-lifecycle hook), plus the `otbr-udev-nudge` oneshot (wanted
by `multi-user.target`) that fires one `udevadm trigger --action=change` at the
resolved node, closing the first-deployment gap where the running device
predates the rule. The device is bound `--device=/dev/otbr-rcp:/dev/otbr-rcp`
(explicit target). Two follow-on findings that same night: `systemctl
try-restart` is a **silent no-op on an inactive unit** (it must be plain
`restart` here); and upstream OTBR does **not** form a Thread network on an
empty dataset — the `otbr-form` oneshot (idempotent, greps `networkkey`) does
the one-time `dataset init new → commit → ifconfig up → thread start`.

Then the real killer, with a root cause worth remembering: **a `systemd.path`
unit using `PathExistsGlob=…` + a `Type=oneshot` trigger service loops
forever** — systemd.path(5): the Exists condition is checked not only on
inotify events but *whenever the triggered unit deactivates*. The plug oneshot
finishes → re-armed → fires again, at script-execution speed (measured 2757
activations in ~2 min once the guard made runs ~10 ms instead of a 7 s
container restart; zero kernel uevents, every watched inode/mtime frozen the
whole time — the container and podman were innocent throughout, and moving
the watch from `/dev/otbr-rcp` to the by-id symlink changed nothing, which is
the clue that should have pointed here first). `StartLimitIntervalSec=0`,
which was added to absorb "bursty" udev events, then removed systemd's own
fuse. The module now has **no path units**; the plug unit additionally keeps
the device-generation guard (`stat -c %i:%Z` vs `/run/otbr-rcp-plug.state`),
so even the intended events (boot coldplug, nudge, every change uevent) are
verified no-ops unless the device node is genuinely new or the container is
down. And the plug script must **never** run `udevadm trigger` — the trigger
inside the unit its own rule starts is the same loop wearing a different hat.

## Bring-up (firmware is done — what remains once the stick moves)

```sh
# 1. plug the flashed stick into ANY free USB socket on grafton-router.
# 2. deploy (autoRollback host!) — from zen3: git push, then:
ssh -A -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 \
  'cd nixos-config && git pull --ff-only && sudo nixos-rebuild switch --flake .'
ssh -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 sudo nixos-confirm
# 2b. nothing else needed: the udev rule (RUN+="systemd" → otbr-rcp-plug)
#     handles boot and re-seat; the otbr-udev-nudge oneshot (started at
#     activation AND boot) fires one change uevent at the running device, so
#     even the FIRST switch that ships the rule needs no manual nudge.
# 3. verify on the router — the chain (nudge → udev → plug) starts the
#    container for you; podman-otbr itself is NOT enabled directly (see the
#    incident section). Give the restart+form chain ~30 s, then:
ssh -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 \
  'ls -l /dev/otbr-rcp; systemctl is-active podman-otbr otbr-form; sudo podman exec otbr ot-ctl state; curl -s http://127.0.0.1:8081/node | grep -E "state|networkName"'
#    (container is named "otbr"; podman-otbr is the unit. REST key is "state".)
# 4. HA UI: add "OpenThread Border Router" integration (http://127.0.0.1:8081)
#    → Thread integration appears → set preferred network → Matter → Add device.
```

The router already has the bring-up prep: `/srv/otbr` (firmware + flasher, in
case a re-flash is ever needed), the digest image pre-pulled, `cc2538-bsl`
cached in its Nix store.

## Ops quick reference

```sh
# radio + mesh state:
sudo podman logs --tail 50 podman-otbr
curl -s http://127.0.0.1:8081/node | jq '.node_state'        # 0 = down, 4 = leader/active
curl -s http://127.0.0.1:8081/dataset/active | jq .          # the network key etc.
sudo podman exec podman-otbr ot-ctl state                     # if the CLI is wanted
# firmware re-flash (dongle on the router):
sudo ./scripts/flash-thread-rcp.sh flash
```

Symptoms → likely cause:

- `Failed to communicate with RCP` at start → `/dev/otbr-rcp` points at a swapped-in
  stick with a different serial (update `rcpSerial`), baud/flow-control mismatch, or
  the stick is not on ot_rcp firmware (`otbr-agent --radio-version` proves it).
- BR green, device commissioning dies at "joining network" → the upstream caveat
  above; try re-commissioning first, then consider an EFR32 stick as the radio.
- LAN client can't reach a Thread device → `nft list chain ip6 filter forward-allow`
  (the `lan ↔ wpan0` pair), and remember Thread device addresses are the mesh's
  own prefix (`fd..`), routed by this box because it *is* the border router.

Deploy: rebuild on **grafton-router** (autoRollback on!) —

```sh
ssh -A -i ~/.ssh/id_ed25519_ps cjdell@grafton-router \
  'cd nixos-config && git pull --ff-only && sudo nixos-rebuild switch --flake .'
ssh cjdell@grafton-router sudo nixos-confirm
```
