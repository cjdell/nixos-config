# The leighhack tailscale bridge (grafton-hackspace-client)

**Status: resolved 2026-10-21; fourth failure 2026-11-01 also resolved — that
one was the router's own static route, not tailscale.** Three outages:
2026-10-09 → 2026-10-14 (5 days),
a 3-hour one on 2026-10-16 caused by the **hackspace's headscale deleting our
node** — see [2026-10-16: logged out by the control plane](#2026-10-16-logged-out-by-the-control-plane)
— and 3.5 hours on 2026-10-21, where the same server-side deletion happened
again but the fix that was supposed to cover it **could not read its own auth
key**, because the VM's secrets share had silently gone empty 27 h earlier. That
last one was entirely ours: [2026-10-21: the secrets share evaporated](#2026-10-21-the-secrets-share-evaporated-under-a-live-vm).
Diagnosed and fixed by giving the VM persistent tailscale state, SSH access and
diagnostic tools, plus a health timer that alerts, and (2026-10-16) an in-guest
timer that re-joins the tailnet by itself. One dependency stays outside our
control: see [Return path is their decision](#return-path-is-their-decision).

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
exit node) into it. The router reaches the leighhack side through a static
route **declared on the `lan` network and owned by systemd-networkd**
(`networking/interface.nix`):

```
10.3.0.0/16 via 192.168.49.15 dev lan
```

(Not a boot-time script: until 2026-11-01 it was installed once at boot by
`grafton-hackspace-client-routes.service`, a `RemainAfterExit` oneshot — see
[2026-11-01: a networkd restart flushed the route](#2026-11-01-a-networkd-restart-flushed-the-route).)

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

## 2026-10-16: logged out by the control plane

Symptom was identical to the Oct-9 outage (`BackendState=NeedsLogin`, tunnel
dead, VM otherwise healthy), and the health timer did its job this time: it named
the layer within minutes. The important part is **why**.

The guest journal is unambiguous, and it was **not** a logout from our side:

```
2026-10-16T08:21:52Z  active login: <missing-profile>
2026-10-16T08:21:52Z  magicsock: closing connection to derp-8 (derp-disabled), age 10h17m50s
2026-10-16T08:21:52Z  Switching ipn state Running -> NeedsLogin (WantRunning=true, nm=true)
2026-10-16T08:21:53Z  control: lite map update error: initial fetch failed 404: node not found
```

`LocalAPI: Logout` appears **zero times** in the whole journal. The tunnel was up
and running (DERP connection 10 h 17 m old) when their headscale started
answering `404: node not found`: **the node was deleted server-side**, and
`tailscaled`'s response to being told it does not exist is to drop its keys and
enter `NeedsLogin` — locally indistinguishable from someone running
`tailscale logout`. Plausibly the admin pruning the stale
`grafton-hackspace-client` nodes we asked them to clean up (there are several
identically-named ones). The pre-auth key was never the problem: it is reusable,
unexpired, and re-registration worked first try.

> So "the client was logged out" is not evidence about anyone's typing. On a
> tailnet you do not administer, a logout is an event that **will** happen. The
> fix is not to prevent it but to recover without a human.

### Why it sat dead for 3 hours: autoconnect is a boot-time one-shot

`tailscaled-autoconnect` polls the backend state and, on `Running`, does
`systemd-notify --ready` and **`exit 0`**:

```sh
      Running)
        echo "Tailscale is running"
        systemd-notify --ready
        exit 0        # <- it never looks again
        ;;
```

The `Restart = on-failure` added on 2026-10-15 only covers a *failed* registration
at boot; it cannot fire on a clean exit. So any logout after boot — ours, theirs,
or an expired node key — is permanent until something external intervenes. That
is the whole 3-hour window: `08:21:52Z` down, `11:23:04Z` a human restarted the
unit.

### Fix: `hackspace-tailscale-ensure` (in the guest)

A oneshot service + 1-minute timer in the VM's config
(`virtual-machines/grafton-hackspace-client.nix`) reads `BackendState` and
re-applies the pre-auth key when it is `NeedsLogin`/`NeedsMachineAuth`/`Stopped`.
It deliberately ignores `NoState`/`Starting` so it never races `tailscaled` at
boot, and it builds its `tailscale up` flags from the same `leighUpFlags` binding
as `services.tailscale.extraUpFlags`, so a re-join can never come up without the
subnet route this VM exists to advertise. Worst case is now ~1 minute of outage
instead of "until someone notices".

It runs **in the guest**, because the host cannot re-register a session it does
not hold, and it is independent of the alerting timer: alerting and healing are
separate concerns and both are now present.

**What it cannot fix:** a fresh registration is a *new node* on their headscale,
so the return route for `192.168.49.0/24` starts disabled and the link is
one-way for ~20 min (observed again on 2026-10-16: re-registered 11:23:04Z,
end-to-end 10.3.1.1 replies at ~12:40 BST). Auto-approving the route in their
ACLs would remove that window too — worth asking for, since re-registrations are
now automatic and can happen while nobody is watching.

## 2026-10-21: the secrets share evaporated under a live VM

Symptom, for the third time: `BackendState=NeedsLogin`, tunnel dead, VM healthy,
`*.int.leighhack.org` not resolving. The trigger was identical to 2026-10-16 —
their headscale answered `404: node not found` at 17:02:30 UTC — but this time
`hackspace-tailscale-ensure`, the auto-rejoin built for that incident, was
running on schedule and achieving nothing for **3.5 hours and 110 consecutive
failing checks**:

```
leighhack session is 'NeedsLogin' — re-registering with the pre-auth key
cat: /run/secrets/leigh_hackspace_tailscale_pre_auth_key: No such file or directory
tailscale up --auth-key "" ... To authenticate, visit:
        https://tailscale.leighhack.org/register/hskey-authreq-AnqL8...
<timed out after 2min, SIGTERM, repeat every 2 min forever>
```

Two independent defects, one per sentence of that log.

### 1. `tailscale up --auth-key ""` does not fail

An empty auth key is not an error: `tailscale` concludes nobody has given it a
way to authenticate and starts an **interactive login**, printing a register URL
and blocking. So a missing secret is indistinguishable from a hung login, the
unit's `TimeoutStartSec` kills it, the timer tries again, and nothing is ever
said about the actual cause. Fixed in `leighEnsure`: it now checks
`[ -s "$KEY" ]` and exits 1 naming the secrets share, and after `up` it judges
the outcome by `BackendState` instead of the exit code (which is 0 even for an
interactive login that completed nothing).

### 2. Why the key was gone: virtiofsd serves a directory, not a path

The guest's `/run/secrets` is a virtiofs share of the host's
`/run/secrets-vm`, which the host used to keep pointed at the current sops
generation with an **activation script** doing `umount` + `mount --bind` (it
cannot hand virtiofsd the `/run/secrets` symlink directly — its sandbox uses
`move_mount(..., MOVE_MOUNT_F_EMPTY_PATH)`, which returns EINVAL on a symlink).

**virtiofsd opens `--shared-dir` once, at VM start, and serves that directory
inode for the life of the process.** Re-mounting over the path on the host does
not move the guest's view; it *detaches* it. An activation script runs on every
`nixos-rebuild switch`, so every switch ever made was silently emptying the
VM's `/run/secrets`. This one did, at 15:06:35 on Oct 20, four minutes after the
VM had started at 15:02:00:

| | |
| --- | --- |
| guest `/run/secrets` inode | 168579720, **0 entries**, still mounted, no error |
| host `/run/secrets-vm` inode | 168619890, 22 entries |
| `readlink /proc/<virtiofsd>/cwd` | `/ (deleted)` |

Nothing could notice for 27 hours because the tailscale session was alive on its
state disk and the key is only read when *registering*. It became visible only
when their headscale deleted the node — i.e. the second defect was armed by the
first switch after it was deployed, and fired on the next server-side deletion,
which is a thing this tailnet does to us at least monthly.

**Fix:** no mount at all. The share is now a plain directory on `/run`'s tmpfs
(`/run/vm-secrets/grafton-hackspace-client`) and the host *copies the two files
the VM needs into it* (`systemd.services.grafton-hackspace-client-secrets` + an
activation script, because a service has no cheap way to know a secret changed:
`startIfChanged = "${config.system.build.toplevel}"` — the obvious trick — dies
with `infinite recursion encountered`, since every unit is part of the toplevel).
Replacing files is fine; only the shared *directory* must never move. The unit is
wired with `requiredBy`/`before` on `microvm-virtiofsd@grafton-hackspace-client`,
so even a bare restart of the VM's virtiofsd repopulates the share first. Side
benefit: the VM used to be handed read access to all 22 host secrets; it now gets
the pre-auth key and its ssh host key.

**Alerting was actively wrong here.** `hackspace-tunnel-check` said *"the
pre-auth key may need replacing"* 110 times while the key was fine, reusable and
untouched — because from the router, "logged out and cannot re-register" has one
symptom and three causes. It now probes `test -s /run/secrets/<key>` inside the
VM first and reports a missing key as a stale share, and
`check-hackspace-tailscale.sh` gained the same check as its own PASS/FAIL line.

**Correction to the advice further down this file:** "restarting the VM is not
the fix and costs a fresh node on their headscale" was true while state was
ephemeral and is now wrong twice over. The node key lives on
`tailscale-state.img`, so a restart does not re-register anything unless the
session is already gone — and for a stale share, restarting the VM is the *only*
fix, since virtiofsd cannot be told to re-open its shared directory. It was
deployed 2026-10-21 21:33 and the tailnet was back in ~60 s, end to end, with no
one-way window (the node was re-registered while their side already had the
subnet route enabled for us; do not count on that — see
[Return path is their decision](#return-path-is-their-decision)).

## Diagnosing it

```sh
sudo ~/nixos-config/scripts/check-hackspace-tailscale.sh
```

Reports, per layer: route installed → VM active/answering → VM has tailscale
state on disk → the VM's `tailscale` BackendState → **whether the guest can read
the pre-auth key at all** → `10.3.1.1` reachable → coordination server reachable
→ one-way test → `int.leighhack.org` resolves.

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

**Since 2026-10-16 you should not have to do this at all:**
`hackspace-tailscale-ensure.timer` in the VM re-joins within a minute of the
session dropping, whatever caused the drop. Check that first:

```sh
ssh root@192.168.49.15 'systemctl list-timers hackspace-tailscale-ensure; \
                        journalctl -u hackspace-tailscale-ensure --since -1h'
```

Only if the VM is *still* `NeedsLogin` after the timer has run is the key
involved — that means the re-registration itself is failing. Read the reason
before touching the key: since 2026-10-21 `hackspace-tailscale-ensure` exits 1
and says which half of "the key" it is. **Missing/empty key file** means the
guest cannot see its secrets share (stale virtiofsd directory) and the fix is
`systemctl restart microvm@grafton-hackspace-client`; a key that is present and
rejected is the real expired/spent case. The deployed key **is** reusable
(`headscale preauthkeys create --user <u> --reusable --expiration 0`); if it
ever has to be replaced, put the new value in sops as
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

## 2026-11-01: a networkd restart flushed the route

Fourth failure of the path, and a new failure mode: **the tunnel was healthy
the whole time.** `10.3.1.20` would not ping; the check script's first line was
the only honest one — `no route for 10.3.0.0/16` — and everything below it
("10.3.1.1 unreachable", "ONE-WAY TUNNEL", DNS down) was that one missing route
wearing three costumes: with no route, the router's `10.3.x` pings fell through
to the default route and left via `pppoe-zen`, so a router-side one-way test
cannot distinguish itself from the real 2026-10-14 one-way tunnel.

Root cause: the route was a runtime kernel route *on `lan`*, added once at boot
by a `Type=oneshot, RemainAfterExit` unit. The 02:18 switch restarted
systemd-networkd, which **recreated the `lan` bridge** (`lan: netdev ready`),
and the kernel flushed every route that lived on the link. Nothing re-added it —
the unit still reported `active (exited)` and only ran at boot. `hackspace-tunnel-check`
named the layer within two minutes (`DOWN: route 10.3.0.0/16 is not installed`)
but deliberately heals nothing, so it paged for 17 h across five switches.

**Fix:** the route is now declared as a networkd route on the `100-lan` network
(`networking/interface.nix`, with `GatewayOnLink` so a not-yet-started VM never
blocks installation), which networkd re-installs every time it configures `lan`
— including when it *is* the switch that recreates the bridge. The oneshot unit
is deleted; do not move it back. Interim recovery, if this ever recurs:
`systemctl restart systemd-networkd`.

The October hardening all worked as designed here — BackendState, secrets
share, disk and tunnel were green, and the timer named the failing layer
immediately. The lesson is narrower: **a route installed by script is
undocumented kernel state; anything that recreates its link silently owns its
life.** Anything else this host installs by `ip route add` at boot deserves the
same audit.

## 2026-11-19: what `*.int` answers with over IPv6, the 794 403s, and a misdiagnosis

Every `*.int.leighhack.org` name answers with **three** addresses: `10.3.1.1`
(their LAN, reached *through this tailnet*), `2001:8b0:1d14:225::1` (the
hackspace's public AAISP half) and `fd99:dead:beef:225d::1` (their ULA). Until
today the route from the house into the hackspace was IPv4-only, so both AAAAs
meant the same thing: **leave the house over Zen and arrive at the hackspace
door as a WAN client** — waved through by a hand-written
`allow <our delegated /48>;` row in the hackspace's own config, i.e. an ACL row
chasing a prefix we do not own. On 2026-11-19 that row stopped matching what we
send: last allowed request `13:48:58`, first 403 `14:26:55`, 794 more after it,
all over IPv6, while every layer of `hackspace-tunnel-check` stayed green.

**The handover note that started this work diagnosed a Zen re-delegation
(`2a02:8010:6680::/48` → `2a02:8011:d000::/48`). It was wrong, and acting on it
briefly cost the house its working IPv6.** Measured the same evening: a fresh
DHCPv6 re-solicit (`journalctl -u systemd-networkd | grep 'received delegated
prefix'`) still returned `2a02:8010:6680::/48`; the "new" /48 is Zen's
**access-link** space — the WAN interface holds `2a02:8011:d000:672::/64` via
RA and has for weeks (it predates today in the `headscale.nix` DERP dial
hint); and source-bound pings (`ping -6 -I <addr> 2606:4700:4700::1111`)
showed nothing routes for the candidate /48 while the old /48 still worked
end to end. Re-pinning `LAN_IPV6_PREFIX`/`DELEGATED_PREFIX` to the guessed /48
black-holes the house v6 twice over — `networking/firewall.nix` forwards only
`ip6 saddr DELEGATED_PREFIX`, and the RA stops advertising the real one — which
is exactly what happened; it was reverted the same evening. Durable rules:
**a WAN SLAAC address is not a delegation signal; before re-pinning anything
pinned to the delegation, verify it three ways (DHCPv6 journal, the ISP's own
statement/dashboard, and a source-bound ping proving both directions).** The
sweep list for a *real* future re-delegation is annotated in
`networking/constants.nix`: the constants there, `dns.nix` statics, both
postgres pg_hba rows, `hosts/zen3-nixos/ai/lfm3.nix`, the `FRIEND_V6_*` slices
(and the friend's wg config), and the Route 53 AAAA records — external, this
repo cannot move them. Note also the DHCPv6-PD client does not re-solicit while
the PPP session lives, so a real rotation only shows up after
`networkctl renew pppoe-zen` or a pppd bounce.

What fixes the actual fragility, independent of any prefix story, is that the
hackspace's AAAAs no longer touch Zen on the way out:

* **v6 routes into the VM.** `networking/interface.nix` declares routes for
  `2001:8b0:1d14::/48` and `fd99:dead:beef::/48` via the VM's link-local
  (`fe80::ff:fe00:15` — EUI-64 of the pinned tap MAC `02:00:00:00:00:15`;
  change one, change the other; and **no `%lan` scope suffix** — networkd v262
  rejects that form and silently drops the route, verify with
  `journalctl -u systemd-networkd | grep -i 'failed to parse'`), the same
  networkd-ownership pattern that protects the `10.3.0.0/16` route since the
  2026-11-01 bridge-flush incident. `--accept-routes` in the VM already carries
  both /48s (tailscale's table 52; its unconditional `from all lookup 52` rule
  serves forwarded traffic too), so these requests arrive on `tailscale0`.
  **But a v6 route to the hackspace is a two-way street**: they also *source*
  from `2001:8b0:1d14::/48` (their door `…:225::1`), and a destination-based
  route cannot tell "our request to them" from "their request to us" — a
  destination lookup on our *reply* to a hackspace-initiated flow hits the VM
  route too, and the answer vanishes into the tailnet instead of going back out
  the internet (same-evening discovery: their pings to `llm.ai…` reached our
  WAN — tcpdump proved it — and never got answered). The fix is in
  `networking/firewall.nix` + `interface.nix` + `pppoe.nix`: `ct direction
  reply` packets to the public hackspace /48 get mark `0x202a`, an ip-rule
  sends marked traffic to table 100, whose only route is a WAN default on
  pppoe-zen. Conntrack is the only thing that knows the direction, so conntrack
  it is. The ULA (`fd99:`) is deliberately not marked — it is unreachable
  across the internet, so every reply there genuinely belongs on the tailnet.
  The VM's advertisement into the **leighhack** tailnet stays **v4-only** by
  contrast: their members reach house services over Zen's v6 fine (arriving on
  the WAN, answered symmetrically by the mark chain), so adding our LAN /64 to
  their tailnet buys nothing and costs a re-approval dependency on their admin
  every time the VM re-registers. (Our own headscale *does* advertise the LAN
  /64 — that side is ours to control; see the round-2 section below.)
* **v6 gets one source-NAT point — in the VM — where v4 keeps none.** The
  v4 no-NAT design above still holds (their static route for our stable /24).
  v6 cannot preserve source and still survive an ACL chasing our ISP's prefix:
  the one permanently-admissible source is the VM's tailnet ULA
  (`fd7a:115c:a1e0::13` — proven admitted: HTTP 302 from the VM), so
  `virtual-machines/grafton-hackspace-client.nix` masquerades
  `br-host → tailscale0` traffic **scoped to the two hackspace /48s**. Side
  benefit: the v6 return path is pure tailnet, immune to the
  one-way-after-fresh-registration failure this doc is full of. Measured for
  the next reader: tailscale 1.104.1's MagicNAT is **not** a substitute — its
  masq chains are mark-gated to tailscaled's own traffic and never
  forward-SNAT (ip6 counter sat at zero under live LAN traffic). This is also
  what makes the hackspace's ACL row deletable — the whole point of the
  exercise: with their Zen-prefix row gone their door still admits us, because
  it now only ever sees `fd7a:115c:a1e0::13`.
* `hackspace-tunnel-check` gained a **fourth layer** to name this fault class
  by itself: `curl -6 https://network-info.int.leighhack.org/healthz`. Any
  HTTP status = the v6 path and their ACL both admit us; **403 pages as "our
  source is not in their ACL", never as "tunnel down"**; connect failure = our
  v6 path. That is the alert that would have named 2026-11-19 at 14:26 instead
  of at 21:00, by a human, from a page that would not load.

### Round 2, same evening: `ping6 gw.int.leighhack.org` from `airm5`

With the LAN→hackspace v6 path live, the ask flipped: a house **tailnet**
member should be able to reach the hackspace gateway directly, with or without
Zen in the picture. Three independent faults were stacked under that one
failing command:

1. **`gw.int.leighhack.org` has no AAAA, anywhere.** Their DNS answers A
   `10.3.1.1` and *nothing* on AAAA (contrast `switch.int`, which publishes
   both `2001:8b0:1d14:225::1` and the ULA) — so `ping6 gw.int…` fails at
   resolution before any routing question is even asked. The handover
   documents the box as `10.3.1.1 / 2001:8b0:1d14:225::1`, and that v6 is
   proven live: it is the address gw pings *us* from, and it answers our v6
   echo 0 % loss via the VM route. `services/adguard.nix` now supplies the
   missing glue as a `user_rules` rewrite (`HACKSPACE_GATEWAY_V6`,
   `networking/constants.nix`) — **retire ours when leigh adds the real AAAA
   upstream; a rewrite silently shadows the authoritative record forever.**
2. **Tailnet members had no route to the hackspace /48s.** `services/tailscale.nix`
   now advertises `2a02:8010:6680:49::/64` (the LAN, so members reach house
   v6 hosts through us — the feature the earlier v4-only debate had parked),
   plus `2001:8b0:1d14::/48` and `fd99:dead:beef::/48`, so member traffic to
   the hackspace rides the router→VM path instead of the public internet (and
   survives deletion of their Zen-prefix ACL row, which a public-internet
   ping6 from our delegation would not). Gotchas, both hit live:
   `headscale nodes approve-routes` **replaces** the approved set — pass the
   full list (`0.0.0.0/0,10.3.0.0/16,192.168.49.0/24,::/0,2a02:…:49::/64,
   2001:8b0:1d14::/48,fd99:dead:beef::/48`) — and nixpkgs'
   `tailscaled-autoconnect` is a boot-time one-shot that exits once the
   backend is Running, so after editing `extraUpFlags` the *running* node
   keeps advertising the old set until `sudo tailscale up <flags>` is run by
   hand. Verify: `headscale nodes list-routes -i 11` shows Approved =
   Available = Serving.
3. **A grafton-tailnet source cannot cross the VM un-NATed.** Both tailnets
   default to `100.64.0.0/10` + `fd7a:115c:a1e0::/48` — the *same* ranges —
   so when the VM de-NATs a hackspace reply destined `fd7a:115c:a1e0::6`,
   its own tailscale table (52, served unconditionally per the bullet above)
   claims that address for `tailscale0` and the reply dies on **leighhack's**
   tailnet, possibly at some unrelated node. Demonstrated precisely:
   `ping -6 -I fd7a:…::b 2001:8b0:…::1` = 100 % loss, LAN-sourced = 0 %, same
   route, same minute. The fix is the `hackspace-v6-nat` inet table in
   `networking/firewall.nix`: member→hackspace traffic gets masqueraded to
   the LAN address **before** the VM sees it, so the VM's return path is
   plain `dev lan` main-table routing. v4 needed no new rule —
   `firewall.nat` has masqueraded `tailscale0 → 10.3.0.0/16` for a while, and
   their approved `192.168.49.0/24` subnet route makes that source routable
   back.

Measured afterwards, from the router: `dig AAAA gw.int…` answers
`2001:8b0:1d14:225::1`; the `fd7a`-sourced ping that used to hang now returns
0 % loss through the full masq→VM→nat6 chain. Two honest limits from their
side: `10.3.1.1:443` (their OPNsense UI) filters tailnet-adjacent sources —
`ping`/DNS answer, `https://10.3.1.1` times out, so test with ICMP, not the
browser — and whether their ACL admits `fd7a:115c:a1e0::13` to the gateway
itself (not just the door) is their policy; if pings to `gw` ever go dark
while `switch.int` stays 302, that is their row to widen, not our route to
fix.

## 2026-11-23: the /48 comes off the tunnel — flaps beat ACL-chasing

Two days of swapped symptoms ended this design change. Friday the Pixel hung on
`frigate.int` and `id.leighhack.org` while the Mac was fine; overnight that
**flipped** — phone fine, Mac now hanging on `id.leighhack.org` unless forced to
IPv4. Neither device was the variable; the tailnet path was. The watchers
(`conntrack -E`) caught the failure class overnight: LAN-client SYNs to
`2001:8b0:1d14:225::1` sitting `[UNREPLIED]` for a full 120 s while the v4
tunnel stayed healthy. Reproduced from a netns client on the lan bridge: the
path was also *degrading* — SYN-ACK fine (mss 1220, i.e. genuinely through the
tailnet), then the first data packet retransmitted ~3 times over a second
before the connection came alive, and the router's own session to the same
address sailed through the same minute. That combination — TCP **connects**,
data stalls — is exactly the one failure mode browsers refuse to fall back
from: Happy Eyeballs gives up on failed connections, not established-but-
silent ones, which is the whole "hangs forever unless I force IPv4" experience.
`gw` is the VM's only peer with a live direct WireGuard session; when it flaps
to DERP or rebinds, established TCP through it stalls rather than breaks.

The question was what the tunnel was actually buying for the public /48 —
`2001:8b0:1d14:225::1` is their **internet** nginx, publicly routable, and
this house has been dialled in on the other side's firewall: leigh keeps a
standing allow policy for the Grafton IPv6 ranges. Measured with the /48 forced
over Zen (client-sourced and router-sourced both, sources `2a02:8b0…49::/64`
and the pppoe link /64): `id.leighhack.org` 302 in ~0.13 s **steady**, the
`frigate.int` vhost 200 in ~0.07 s, the health probe
`network-info.int.leighhack.org/healthz` 200 in ~0.09 s, zero retransmit
storms. The detour bought only the flap exposure. So the 2026-11-19 decision
that built this section (their hand-written WAN ACL row breaks → ride the
tailnet with its "stable" source) is **superseded**: the allow policy is now
the contract, and the internet path is the primary for the public /48.

What changed (`networking/interface.nix`): the `2001:8b0:1d14::/48 via
fe80::ff:fe00:15` route is **deleted**. Kept on the tunnel: v4
`10.3.0.0/16` (frigate's A record, `.int` DNS at 10.3.1.1, everything
name-blind), the `fd99:dead:beef::/48` ULA (not routable anywhere else —
still the sole v6 answer for some `*.int` hosts), the `mark-hackspace-replies`
chain (their gateway still SOURCES monitoring at us from 225::1 over the WAN —
`firewall.nix`, `pppoe.nix`), and AdGuard's `[/int.leighhack.org/]` forward.
Consequences documented in the files: grafton-tailnet **members'** v6 to the
/48 no longer rides the VM (their v4 `.int` is untouched) — if member v6 ever
matters, re-add the route scoped to `iif tailscale0` via a mark, not in main;
and the health check's two IPv6 `where=` strings now teach the new failure
classes — a 403 on the door means **their allow row broke**, and a stray
`ip -6 route show 2001:8b0:1d14::/48` re-attaches the probe to the tunnel and
its flaps.

One correction, true before this change as well: everything from interface.nix
and the health check that says forwarded v6 "arrives masqueraded as the VM's
fd7a tailnet address" was **wrong** — that masquerade rule sat at `counter
packets 0` inside the VM. Forwarded house traffic crossed the tailnet with the
LAN client's own `2a02:…` source, which is what their access log saw, and what
their allow policy admits. (The only v6 that ever did masquerade is our own
tailnet members' `fd7a`, SNATed to LAN space by `hackspace-v6-nat` on the
router before the VM ever sees it — see the 2026-11-19 section above.)

Verify after the switch: `ip -6 route show 2001:8b0:1d14::/48` empty; from the
Mac (browser, no forcing) `id.leighhack.org` opens; `journalctl -u
hackspace-tunnel-check -n 20` green; on the phone both names still open.

## Related

* `hosts/grafton-router/virtual-machines/grafton-hackspace-client.nix` — the VM,
  the secrets share (`grafton-hackspace-client-secrets.service`) and
  `hackspace-tailscale-ensure`
* `hosts/grafton-router/services/tailscale.nix` — the grafton tailnet + the
  commented-out `nixos-container` version of this same bridge (superseded by the VM)
* `hosts/grafton-router/services/adguard.nix` — the `int.leighhack.org` DNS forward
* `hosts/grafton-router/services/hackspace-tunnel.nix` — the health timer
