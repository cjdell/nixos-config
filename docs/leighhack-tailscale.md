# The leighhack tailscale bridge (grafton-hackspace-client)

**Status: resolved 2026-10-15.** Outage 2026-10-09 → 2026-10-14 (5 days).
Diagnosed and fixed by giving the VM persistent tailscale state, SSH access and
diagnostic tools, plus a health timer that alerts. One dependency stays outside
our control: see [Return path is their decision](#return-path-is-their-decision).

## What this is: there are TWO tailscale connections on grafton-router

They are completely independent, and this is the single most important thing to
know when debugging.

| | grafton tailnet | leighhack tailnet |
| --- | --- | --- |
| coordination server | `https://tailscale.home.chrisdell.info` (our headscale) | `https://tailscale.leighhack.org` (theirs) |
| runs in | `tailscaled` on the host | `tailscaled` inside the **grafton-hackspace-client microVM** |
| config | `hosts/grafton-router/services/tailscale.nix` | `hosts/grafton-router/virtual-machines/grafton-hackspace-client.nix` |
| magicDNS | `grafton.tailscale` | `int.leighhack.org` |
| range | `100.64.0.0/24` + `fd7a:115c:a1e0::/64` | `10.3.0.0/16` |
| what it is for | our own machines | the hackspace LAN + their services (`services1` = `10.3.1.1`) |

The VM is a **client** of leighhack and advertises `192.168.49.0/24` (plus an
exit node) into it. The router reaches the leighhack side through a
hand-written static route installed by `grafton-hackspace-client-routes.service`:

```
10.3.0.0/16 via 192.168.49.15 dev lan
```

`192.168.49.15` is the VM (`constants.nix: GRAFTON_HACKSPACE_CLIENT_IP`, MAC
`02:00:00:00:00:15`). No masquerade on the VM's bridge: return traffic to grafton
LAN hosts is delivered end-to-end, and the hackspace side has a matching static
route back through this VM.

**Downstream consumer:** `adguard.nix` forwards `[/int.leighhack.org/]10.3.1.1:53`.
So when this bridge dies the visible symptom is **DNS for
`*.int.leighhack.org` failing**, not "a VPN looks down" — which is why it does
not look like a tailscale problem.

## The 2026-10-14 incident

Symptom: `*.int.leighhack.org` would not resolve; `10.3.0.0/16` black-holed.

What was found:

* `tailscale status` on the host was **healthy** — 15 peers, correct tailnet.
  That is the grafton tailnet and says nothing about leighhack.
* Route present, VM `active` since Oct 9 00:17, VM answered ping.
* `10.3.1.1`: 100% packet loss.
* **The VM emitted nothing but ARP + IGMP for 100 seconds.** A tailscaled with a
  live session keeps a DERP connection alive and polls its coordination server;
  a tailscaled that is merely logged *out* still retries over HTTPS. Total
  silence means the tunnel is dead and not being retried.
* Coordination server `https://tailscale.leighhack.org` was up (HTTP 301 →
  `/admin`), so this was not the hackspace's headscale being down.

### Root cause: a one-shot registration attempt, with no retry, from a diskless VM

Two facts combine into the outage.

**1. The VM had no disk at all** — the qemu cmdline had no `-drive`, `-blockdev`
or `-pflash`; root is the initrd tmpfs (`root=fstab`). So `/var/lib/tailscale`,
which holds the node key and session, **lived in RAM and was destroyed on every
boot**. Every boot therefore *had* to re-register successfully, or there was no
connection.

**2. Registration is a single non-retrying attempt.** nixpkgs'
`tailscaled-autoconnect.service` polls the backend state and, on `NeedsLogin`,
runs:

```sh
tailscale up --auth-key "$(cat /run/secrets/leigh_hackspace_tailscale_pre_auth_key)" \
  --login-server=https://tailscale.leighhack.org --advertise-routes=192.168.49.0/24 \
  --advertise-exit-node --accept-dns=true --accept-routes=true
```

The script is `set -o errexit`, the unit is `Type = notify` (it only
`systemd-notify --ready`s once state reaches `Running`) and it has **no
`Restart=`**. So one failed *or merely timed-out* attempt ends registration for
ever — against someone else's coordination server, over the public internet.

**This is what happened.** The guest console is captured in the host journal, and
it is unambiguous. Oct 9, the boot that started the outage:

```
2026-10-09T00:17:32  Starting Tailscale node agent...
2026-10-09T00:17:32  [  OK  ] Started Tailscale node agent.
2026-10-09T00:17:32  Starting tailscaled-autoconnect.service...
                     <nothing, ever>
```

The same boot tonight, working:

```
2026-10-15T01:08:31  [  OK  ] Started Tailscale node agent.
2026-10-15T01:08:31  Starting tailscaled-autoconnect.service...
2026-10-15T01:08:34  [  OK  ] Started tailscaled-autoconnect.service.
```

`tailscaled-autoconnect` never completed, so **`tailscale up` never finished and
the VM never registered at all** — it was absent from the hackspace's headscale,
not merely route-unapproved. Nothing retried, for 5 days. Consistent with this,
the VM emitted nothing but ARP and IGMP on the LAN for 100 s: a logged-out
tailscaled still retries over HTTPS, and here nothing was retrying.

### What changed?

**Nothing in the config.** The VM module was last touched 2026-09-28 and the
secrets 2026-09-22; the pre-auth key was **reusable and worked fine** on the
first attempt once the VM was restarted during recovery. The node is not
ephemeral either (`tailscale debug netmap` → SelfNode has no `Ephemeral`).

What changed is that **the VM was restarted** by a `nixos-rebuild switch` on Oct
9 00:17. It had run uninterrupted since Sep 28, holding a session registered at
some earlier boot. "It always used to work" was really "it was never asked to
re-register" — every restart had always been a one-shot gamble, and this one lost.

**Why that particular attempt failed is not recoverable from this host.** The
guest's own journal was in RAM and is gone, and the console runs at `loglevel=4`
and stops emitting once boot completes, so the failure line never reached the
host journal. Plausible candidates, none provable: a transient fault reaching
`tailscale.leighhack.org`, the auth round-trip racing network readiness at boot,
or their headscale erroring at that moment. That is the actual lesson — the
design converted a possibly-momentary fault into a 5-day outage with no signal,
and then made the evidence unobtainable.

> Two earlier hypotheses of mine were wrong and are worth recording so nobody
> re-derives them: **not** an expired/consumed key (it is reusable and worked),
> and **not** unapproved subnet routes (that explains a 20-minute window during
> recovery, see below, not a node that never appeared).

A related hazard still worth checking: the VM runs with `--accept-routes
--accept-dns`, so if leighhack ever advertises a default route and the tunnel
then dies, the VM's own default route points into a dead `tailscale0` and it
cannot reach its coordination server to recover. Verify with
`ip route show default` in the VM — currently it correctly points at
`192.168.49.1 dev br-host`, not `tailscale0`.

### Why it stayed broken unnoticed for days

1. Nothing probed `10.3.0.0/16`. The grafton tailnet's health is unrelated and
   stayed green.
2. The static route stays installed even when the tunnel is dead, so traffic
   black-holes instead of failing fast with "network unreachable".
3. The VM answering ping proved *the VM* was up, which is easy to mistake for
   the tunnel being up.
4. **There was no way into the VM to check.** Root login was password-only (no
   `authorizedKeys`), `microvm -s` refuses because VSOCK is not enabled, and the
   serial console is qemu's `stdio` with no attachable stdin under systemd.

## Resolution (2026-10-15)

Deployed the changes below. The switch restarted the VM, which registered with
the **reusable** pre-auth key (it was reusable — the key was never the defect,
it was the only thing that could be blamed from outside) and created
`tailscale-state.img`. `tailscale status` inside the VM came up `Running` within
seconds and `tailscaled-autoconnect` succeeded.

Then, for **~20 minutes, the tunnel was one-way**: from the VM, `ping 10.3.1.1`
worked (22 ms, `pong from services1`), and the VM was forwarding our packets
(`IpForwDatagrams` incremented), but nothing we sent ever got a reply. It
started working on its own a while later. (This is the *recovery* effect described
under [Return path is their decision](#return-path-is-their-decision-a-recovery-effect-not-the-outage-cause)
— a different failure from the one that caused the outage.)

That is the shape of this link, and the thing to remember:

### Return path is their decision (a recovery effect, not the outage cause)

This bit during recovery and is worth knowing, but it is **not** what caused the
5-day outage — that was the node never registering. It is a second, independent
way this link can be one-way.

The VM advertises `192.168.49.0/24` (`Hostinfo.RoutableIPs` confirms it reaches
the server), but **whether the hackspace's headscale enables that route for this
node decides whether return traffic exists**. If it is not enabled, every
grafton→leighhack packet still leaves the VM and dies silently on the way back —
which looks exactly like "tailscale is down" from the router and exactly like
"everything is fine" from inside the VM.

A **fresh registration starts from scratch here**, so the diskless VM re-opened
this window on every boot. Now that the node key persists, we stay the same node
and the enabled route stays enabled.

To check it directly:

```sh
ssh root@192.168.49.15 'tailscale debug netmap' | sed -n '/SelfNode/,/Peers/p'
# Hostinfo.RoutableIPs  = what we advertise (client-side truth)
# and from the router, the end-to-end test that actually matters:
#   ping -c2 10.3.1.1        /   curl -sSI http://aibox.int.leighhack.org/
```

If it goes one-way and stays that way, ask the hackspace to enable the route
(and ideally auto-approve it in their ACLs so a re-registration cannot drop it):

```sh
headscale routes enable -r 192.168.49.0/24 -n <node-id>
```

## What was changed (2026-10-14/15)

1. **Persistent tailscale state** — `microvm.volumes` now attaches a 32 MiB
   ext4 image at `/var/lib/microvms/grafton-hackspace-client/tailscale-state.img`
   labelled `tsstate`, mounted in the guest at `/var/lib/tailscale`. The node
   identity survives restarts, so re-registration — and therefore the pre-auth
   key's expiry — is no longer on the critical path.
   Verified in the evaluated config: `fileSystems."/var/lib/tailscale".device =
   /dev/disk/by-label/tsstate`.
2. **Root `authorizedKeys` in the VM**, inherited from
   `config.users.users.cjdell.openssh.authorizedKeys.keys`, so
   `ssh root@192.168.49.15` works. The VM's LAN path is independent of
   tailscale, so it still works when the tunnel is dead.
3. **`services/hackspace-tunnel.nix`** — a 2-minute timer
   (`hackspace-tunnel-check.service`) that probes route → VM → tunnel and pushes
   to the phone through the existing `notifications.gateway`
   (`http://127.0.0.1:8888`, see `http.nix`). It alerts after 2 consecutive
   failures, re-alerts every 30 min, and announces recovery. It deliberately
   **never restarts the VM**: while state was ephemeral, a restart also spent a
   pre-auth key, so auto-healing could turn "down and diagnosable" into "down
   and unrecoverable without a new key".
4. **`scripts/check-hackspace-tailscale.sh`** — walks the path from the host
   inward and names the layer that broke. Run this first. It also runs the
   one-way test above, because "logged out" and "logged in but no return route"
   are indistinguishable from the router and need opposite fixes.
5. **Diagnostic tools in the VM** (`tcpdump`, `dig`, `jq`, `curl`, `iputils`) —
   during the incident the VM had none of them, so the decisive question ("can
   the VM itself reach 10.3.1.1?") could not be asked where it belonged.
6. **`tailscaled-autoconnect` now retries** (`Restart = on-failure`,
   `RestartSec = 30s`, `TimeoutStartSec = 5min`). This is the direct fix for the
   actual failure mode: a single failed or timed-out registration used to kill
   the connection permanently.
7. **A router→VM deploy key** (`grafton_hackspace_client_ssh_key` in sops, public
   half authorized in the VM) so the health check can report *which* layer is
   down rather than *that* something is down.

## Diagnosing it

```sh
sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh
```

Reports, per layer: route installed → VM active/answering → **VM has no disk**
→ VM's `tailscale` BackendState → `10.3.1.1` reachable → coordination server
reachable → `int.leighhack.org` resolves.

Manual one-liners:

```sh
# grafton tailnet only — says NOTHING about leighhack
tailscale status

ip route show 10.3.0.0/16                       # must be: via 192.168.49.15
ping -c2 192.168.49.15                          # the VM
ping -c2 10.3.1.1                               # through the tunnel
ssh root@192.168.49.15 'tailscale status; journalctl -u tailscaled-autoconnect -b'

# is the VM's tailscale even trying? healthy = periodic DERP/HTTPS from .15
sudo tcpdump -ni lan -c50 host 192.168.49.15
```

### Getting into the VM with no password (the QMP trick)

If `authorizedKeys` is not deployed yet, the serial console can be re-attached
at runtime — no reboot, guest untouched:

```sh
sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh --console
```

It talks QMP on `/var/lib/microvms/grafton-hackspace-client/grafton-hackspace-client.sock`
and runs:

```
chardev-change stdio socket,path=/run/microvm-console/grafton-hackspace-client.sock,server=on,wait=off
```

Two QEMU 11 gotchas, both of which cost time during the incident: the second
argument is a backend **driver spec**, not a chardev id (`chardev-change stdio
ser1` fails with "'ser1' is not a valid char driver name"), and the serial
device is **anonymous**, so its `chardev` property can no longer be set after
realize ("Attempt to set property 'chardev' on anonymous device … after it was
realized"). Re-pointing the `stdio` chardev that the device is wired to is what
works. While attached, guest console output stops reaching the host journal
(`journalctl -u microvm@grafton-hackspace-client`); it returns on the next VM
start.

## Recovering

Now that `/var/lib/tailscale` is a volume, the node identity survives restarts,
so recovery is normally just:

```sh
sudo systemctl restart microvm@grafton-hackspace-client
sleep 60
sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh
```

Only if the check reports `BackendState` != `Running` is the key involved. The
deployed key **is** reusable (`headscale preauthkeys create --user <u> --reusable
--expiration 0`); if it ever has to be replaced, put the new value in sops as
`leigh_hackspace_tailscale_pre_auth_key` in
`hosts/grafton-router/secrets/secrets.yaml` and rebuild — sops needs the file
committed, see the `.gitignore` gotcha in `AGENTS.md`.

**Then be patient.** After a *fresh* registration the link can be one-way for
minutes before their headscale has the return route for the new node (see
[Return path is their decision](#return-path-is-their-decision)). Do not conclude
the fix failed inside that window — re-run the check. This is also why
`hackspace-tunnel-check` waits for ~10 min of continuous failure before paging.

Finally: if the hackspace is tidying up, ask them to **delete the stale
`grafton-hackspace-client` nodes** from their headscale — every pre-fix restart
registered a fresh node key, so there are several dead ones.

## Related

* `hosts/grafton-router/virtual-machines/grafton-hackspace-client.nix` — the VM
* `hosts/grafton-router/services/tailscale.nix` — the grafton tailnet + the
  commented-out `nixos-container` version of this same bridge (superseded by the VM)
* `hosts/grafton-router/services/adguard.nix` — the `int.leighhack.org` DNS forward
* `hosts/grafton-router/services/hackspace-tunnel.nix` — the health timer
