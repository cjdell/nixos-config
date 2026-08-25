# Pi 5 ops notes (from the 2026-08-25 debugging session)

Field notes from getting gc-node running on the Pi — read the first two before
touching anything. All of these bit us during one deployment.

## 1. Weird uptime / clock artifacts (READ FIRST)

After a fresh power-cycle reboot, an SSH session reported:

- `uptime` → `up 160 days 18:30` (a machine that had just rebooted!)
- `systemctl status` → `Active: active (running) since Tue 2026-03-17 … 5 months 8 days ago`
- yet `date` showed the correct time

**Ground truth always wins; the counter-ish tools lied:**

- `/proc/uptime` → `296.21` (kernel really had been up 296 s)
- `systemd-analyze time` → `Startup finished in 716ms (kernel) + 14.756s (initrd) + 12.455s (userspace)`
- `/proc/cmdline` → `init=/nix/store/<new-toplevel>/init` (which toplevel actually booted)

Likely causes: the Pi has no battery RTC, so the early-boot wall clock is wrong
until NTP syncs — systemd records pre-sync timestamps for services started
before sync. The `uptime` reading matched the *pre-reboot* machine's uptime, so
it was stale — but treat `uptime`/`Active: since` as unreliable on this box and
verify reboots with `/proc/uptime` + `/proc/cmdline`.

Related: the HA-relay power-cycle responses were empty (`relay: off (response:
[])`); if a reboot "doesn't take", check the relay actually toggled
(`scripts/pi5-powercycle.sh` output).

## 2. Store ownership: sshd/ssh "Bad owner or permissions" (root cause of the outage)

The aarch64 pi5 closure was copied into zen3's `/nix/store` as **`cjdell:users`
(uid 1000)** — a rootless `nix build` writes remote-builder outputs
(`ssh://cjdell@192.168.49.191`) into the world-writable store without the
daemon's root chown. On the Pi (store served read-only over NFS), that broke:

- the **ssh client**: `Bad owner or permissions on /nix/store/…-systemd-260.2/lib/systemd/ssh_config.d/20-systemd-ssh-proxy.conf`
  (`programs.ssh` adds `Include …/20-systemd-ssh-proxy.conf` to `ssh_config`)
- **sshd**: its host key file was uid-1000-owned → refused to start → port 22 down

Fix (apply once):

```sh
sudo find /nix/store -maxdepth 1 -user cjdell -exec chown -R root:root {} +
```

Prevent: **run pi5 builds with `sudo nix build …`** so store paths land
root-owned. (The nix-daemon runs on zen3, but the ssh-ng remote-builder copy
path bypasses it when the invoking user isn't root.)

## 3. OpenSSH 10.x rejects store-path host keys (0444)

Store files are always `0444`. OpenSSH ≥ 10 refuses world-readable private
keys: `WARNING: UNPROTECTED PRIVATE KEY FILE! … Permissions 0444 … are too
open. This private key will be ignored.` → sshd has no usable host key → port
22 refused. So `hostKeys = [{ path = ./ssh_host_ed25519_key; … }]` can never
work on this OpenSSH.

Fix in `pi5/configuration.nix`: point sshd at a 0600 copy made at boot:

```nix
services.openssh.hostKeys = [
  { path = "/var/lib/sshd/ssh_host_ed25519_key"; type = "ed25519"; }
];
systemd.services.sshd.preStart = ''
  mkdir -p /var/lib/sshd
  ${pkgs.coreutils}/bin/install -m 0600 -o root -g root \
    ${./ssh_host_ed25519_key} /var/lib/sshd/ssh_host_ed25519_key
'';
```

Client side (one-time): `ssh-keygen -R pi5.grafton.lan; ssh-keygen -R 192.168.49.92`
then add `pi5/ssh_host_ed25519_key.pub` to `~/.ssh/known_hosts`.

## 4. `path:` flake inputs freeze at the locked narHash

`gc-rust-node` is a `path:` input of the pi5 flake. After editing
`~/Projects/gc-business/gc-rust-node`, a rebuild **silently uses the old
content** (the drv hash doesn't change) until you refresh the lock:

```sh
cd pi5 && nix flake lock --update-input gc-rust-node
```

## 5. crane build (gc-rust-node/flake.nix)

- `buildDepsOnly` compiles the dep tree against a manifest-only dummy source
  (`mkDummySrc`), so it's keyed on `Cargo.toml`/`Cargo.lock` alone — source
  edits never rebuild it. `buildPackage` reuses it via `cargoArtifacts`.
- Measured: a `src/` edit → full rebuild in **24 s** (vs ~40-60 min for the
  wasmtime stack). The deps derivation is content-addressed.
- **Do NOT use `craneLib.cleanCargoSource`** here — its filter strips `proto/`,
  which `build.rs` needs for tonic codegen. `src = ./.` (raw flake source).
- `gc-node` uses `Path::is_empty()` (still unstable in rustc 1.95, the
  nixos-26.05 toolchain) — fixed to `PathBuf::new()` in `src/config.rs`; keep
  that patch if you rebase the upstream repo.

## 6. deploy-pi5.sh had a pipefail race (fixed)

`set -o pipefail` + `ls … | grep -m1 'nixos-system-pi5'`: `grep -m1` exits after
the first match → `ls` gets SIGPIPE → the pipeline "fails" intermittently with
`error: no nixos-system-pi5 toplevel in …`. Fixed by
`ls … | grep 'nixos-system-pi5' | head -n1` (grep reads everything, head takes
the first line — no early-exiting reader).

## 7. Stateless Pi (design constraints, not bugs)

- Root is tmpfs; the Nix store is a read-only NFS overlay. The enrollment token
  (`~/.gc-node/token`), artifact cache, and `/var/lib/*` all vanish on reboot.
- gc-node join codes are **single-use** with a TTL (default 5 min; we use 24h).
  Every reboot needs a fresh code — `scripts/update-pi5-node.sh` enrolls one
  automatically and writes it into `pi5/configuration.nix`.
- gc-node with no token and no join code logs and exits 0 (service shows
  `inactive`); `Restart=on-failure` does not restart it.

## 8. Demo gc-server on zen3 (for the Pi)

- Ports: HTTP **8089**, gRPC **9002**, admin **8090**. Do not collide with
  9001 (Recallium) / 8081 (llama-swap).
- Config: `pi5/gc-server-demo.yaml`; start via the gc-server repo's
  `start-server-demo.sh` with `GC_SERVER_CONFIG` pointed at it (needs `go` +
  `tinygo` from `nix shell`, and `GOPRIVATE=github.com/gc-business` +
  a git `insteadOf` ssh rule for the private `gc-proto` module).
- Enroll: `./.run/gc-server-demo enroll --ttl 24h -c <config>` (writes to the
  auth store; run from the gc-server dir).
- The auto-dispatching demo workload only targets **mobile** nodes; to run a
  job on the Pi use `POST /api/demo/workload/run` with
  `{"left":1,"right":2,"target_node_id":"<node id>"}`.

## 9. Not yet fixed

- `boot.initrd.network.ssh` still points at the committed key as a store file
  (0444) — the initrd's OpenSSH would hit the same §3 rejection. Main sshd is
  the one that matters; revisit if initrd SSH is ever needed.
