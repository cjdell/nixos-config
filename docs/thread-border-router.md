# Thread border router on grafton-router (Sonoff ZBDongle-P → Matter over Thread)

Adopted 2026-11-26 — **status: software staged, radio pending.** The ZBDongle-P
had not been plugged in yet at the time of writing, so `rcpPort` in
`services/otbr.nix` is empty and the whole service is inert; the bring-up is the
plug-in → flash → set-port → rebuild sequence below.
Home Assistant and python-matter-server have run on
grafton-router for a long time (containers in `home-assistant.nix`), but
without a Thread border router (TBR) no Matter-over-Thread device could ever
be commissioned. This adds the missing half: a spare **Sonoff ZBDongle-P**
(TI **CC2652P10**, shield silkscreen "C2652P") flashed to OpenThread **RCP**
firmware, driven by an **OTBR** container on the router, wired into HA via the
`otbr` → `thread` → `matter` integration chain.

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
bootloader, so no case opening, no soldering, no debug probe. After a flash the
dongle enumerates the same CH340 (no serial number) and the tty node may get a
different number — always key config off the USB **port** (see udev below).
Rollback: flash `CC1352P2_CC2652P_launchpad_coordinator_*.hex` (Koenkk
Z-Stack-firmware) with the same command minus the ot_rcp URL.

## Host side — `hosts/grafton-router/services/otbr.nix`

- udev: `SUBSYSTEM=="tty", ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523",
  KERNELS=="<usb port>"` → `/dev/otbr-rcp`. The CH340 carries no serial, so
  the physical USB port is the only way to tell this stick apart — and there
  is already an unrelated CH340 on port 1-7 of this box, so `rcpPort` must be
  set from the *observed* path after plugging ours in (empty = whole service
  inert: no rule, no container).
- Container: `docker.io/openthread/border-router` **pinned by digest**
  (2026-11-24 build), `--network host --privileged`, devices `/dev/otbr-rcp` +
  `/dev/net/tun`. The image's s6 `otbr-agent` run script reads `OT_*` env vars
  (authoritative: `etc/docker/border-router/` in the ot-br-posix repo):
  `OT_RCP_DEVICE=spinel+hdlc+uart:///dev/otbr-rcp?uart-baudrate=460800`,
  `OT_INFRA_IF=lan`, `OT_THREAD_IF=wpan0`, REST on **127.0.0.1:8081**.
- State: the agent symlinks `/var/lib/thread → /data/thread`, so the mesh lives
  in `/srv/otbr/thread`. Back it up like any other /srv data — losing it means
  recreating the Thread network (and re-commissioning every device).
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

## Bring-up (when the dongle arrives)

```sh
# 1. plug into a free USB socket on grafton-router, find its port:
ssh -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 \
  'dmesg | tail; sudo udevadm info -q path -n /dev/ttyUSB0'   # new tty → .../usb1/1-N/...
# 2. flash (service still inert — port empty; WORKDIR pre-staged by the
#    bring-up prep, so no download needed):
ssh -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 \
  'sudo PORT=/dev/ttyUSBn WORKDIR=/srv/otbr /srv/otbr/flash-thread-rcp.sh flash'
# 3. set rcpPort = "1-N" in hosts/grafton-router/services/otbr.nix, commit, push;
#    then (autoRollback host!):
ssh -A -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 \
  'cd nixos-config && git pull --ff-only && sudo nixos-rebuild switch --flake .'
ssh -i ~/.ssh/id_ed25519_ps cjdell@192.168.49.1 sudo nixos-confirm
# 4. verify + HA UI clicks (otbr integration url http://127.0.0.1:8081, thread preferred).
```

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

- `Failed to communicate with RCP` at start → wrong port (dongle moved: update
  `rcpPort`), baud/flow-control mismatch, or the stick is still on Zigbee firmware.
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
