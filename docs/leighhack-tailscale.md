# The leighhack tailscale bridge (grafton-hackspace-client)

**Status: resolved 2026-10-21.** Three outages: 2026-10-09 → 2026-10-14 (5 days),
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

## Related

* `hosts/grafton-router/virtual-machines/grafton-hackspace-client.nix` — the VM,
  the secrets share (`grafton-hackspace-client-secrets.service`) and
  `hackspace-tailscale-ensure`
* `hosts/grafton-router/services/tailscale.nix` — the grafton tailnet + the
  commented-out `nixos-container` version of this same bridge (superseded by the VM)
* `hosts/grafton-router/services/adguard.nix` — the `int.leighhack.org` DNS forward
* `hosts/grafton-router/services/hackspace-tunnel.nix` — the health timer
