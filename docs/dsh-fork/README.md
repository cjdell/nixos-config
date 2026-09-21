# DeepSeek Harness fork: declared authorities are the operator's own surface

Why this exists: the retired `dsh-web proxy` → `dsh web` GUI on grafton-router
(`http://192.168.49.1:30800/`; that proxy and its wrapper are gone — this service
replaced them) loaded and chatted, but **Settings → Models** died with

```
Loading the provider directory failed: settings are unavailable in this browser
```

## Diagnosis (verified against `@deepseek-ai/dsh` 0.1.5-rc.2 and upstream `master`)

The chain, all client-side:

1. `packages/client/ui-settings/src/client/index.ts:58` —
   `const persistence = ctx.remote.$host.isLoopback ? 'host' : 'memory'`. In `memory`
   mode the settings mirror starts `unavailable`, its `view` stays `undefined`, and
   `ensure()`/`load()` return immediately without a wire read.
2. `packages/client/connection/src/client/index.ts` —
   `isLoopback` was decided from `location.hostname` alone (`localhost`, `[::1]`,
   `127/8`), or from a shell-supplied `__DSH_TRANSPORT__.ownsHost`.
3. `packages/client/ui-settings-models` then reports the missing mirror view as
   "settings are unavailable in this browser".

So the Host had already **admitted** the LAN page (the `/api` Host/Origin fence accepts
the authority, and the token exchange authenticates it), but the browser refused to
treat it as the operator's own machine because it was not on the loopback interface.
Upstream documents this as a limitation ("Non-loopback pages get no durable settings")
and blocks the direct fix at the CLI: `--host 0.0.0.0` is rejected outright.

Verify the fence/wire side yourself. Against a service serving a declared
authority (loopback counts as declared), a trusted but unauthenticated request
must be `401`, and an undeclared authority must be `403` — no Host rewriting
involved since the fork:

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 127.0.0.1:3080' -d '{}' http://127.0.0.1:3080/api/            # 401: trusted, unauthenticated
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 192.168.49.1:3080' -d '{}' http://127.0.0.1:3080/api/          # 401: declared authority
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 192.168.49.50:3080' -d '{}' http://127.0.0.1:3080/api/         # 403: undeclared
```

## The change

One idea: **one decision, two consumers.** The authority set the `/api` fence admits
(`trustedHosts` = LAN literals derived from an all-interfaces bind + `--trusted-host`
extras) is also the set the served page treats as its own Host. No second policy, no
header rewriting, no HTML injection.

`trusted-authority-surface.patch` (8 files, +115/−13, applies to upstream `ddefc45`,
`0.1.6-alpha.2`):

| File | Change |
| --- | --- |
| `packages/client/connection/src/index.ts` | the connection row publishes its own `trustedHosts` to served pages as the `__DSH_TRUSTED_AUTHORITIES__` boot global (next to the existing `__DSH_CONNECTION_RECOVERY__` row) |
| `packages/client/connection/src/loopback-hostname.ts` | new `isOwnHostAuthority(pageHost, trustedAuthorities)`: loopback, or an exact `host:port` / port-less `host` entry — the fence's rule, in the file that already shares classification between fence and browser |
| `packages/client/connection/src/client/index.ts` | `isLoopback` now means "this page's authority is mine": `ownsHost ‖ non-browser ‖ isOwnHostAuthority(location.host, declared)`. `ConnectionLocation.host` and `ConnectionInstallOptions.trustedAuthorities` are the new inputs |
| `packages/bundle/web-app/src/startup.ts` | `--host 0.0.0.0` is allowed **only** with at least one `--trusted-host` authority; still refused otherwise, with a message saying why |
| `packages/client/connection/tests/loopback-hostname.client.spec.ts` | predicate cases (declared/undeclared, port-exact, port-less, uppercase, malformed) |
| `packages/bundle/web-app/tests/startup.spec.ts` | the rejection test now needs no authority; a new test accepts the bind once one is declared |
| `packages/client/connection/README.md`, `packages/client/ui-settings/README.md`, `packages/bundle/web-app/README.md` | limitation bullets rewritten to the new rule |

Blast radius, checked against every installed package: `ctx.connection.isLoopback` has exactly
three consumers in the harness — `api/gateway` (publishes `$host.isLoopback`), `ui-settings`
(persistence mode), and `ui-settings-general` (the settings document editor). A declared LAN
authority therefore gains the settings and credential surfaces and nothing else: no directory
picker, no open-in-app, no host-side behaviour moves.

## Making it a fork

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
git checkout -b trusted-authority-surface ddefc45
git am /path/to/trusted-authority-surface.patch     # or: git apply
git remote add fork git@github.com:<you>/deepseek-harness.git
git push -u fork trusted-authority-surface
```

Rebasing onto a newer `master` is a one-commit rebase; the touched files are the
connection package's two faces plus the web-app startup gate.

## Build (the fork's own flake)

The fork carries its own flake (`packages.x86_64-linux.default` in
`github:cjdell/deepseek-harness`, branch `trusted-authority-surface`). It fetches
the lockfile's dependency closure with `fetchPnpmDeps` (a fixed-output store —
the only step with network; `fetcherVersion = 4` dumps the store's SQLite index
to SQL first because the binary db is not byte-reproducible), then
`pnpmConfigHook` seeds that store into a writable tmpdir and runs
`pnpm install --offline --frozen-lockfile` inside the Nix 2.34 sandbox.
`pnpm run build` compiles the tree offline and the result is installed with
`$out/bin/dsh`. nixos-config consumes it as the `deepseek-harness` input and
runs it through `services.dshWebHarness` (`common/dsh-web-service.nix`) — no
`npx`, no checkout build, no proxy.

Nothing is built on grafton-router: the package comes from the fork's flake and
the router only activates it. The flake's comments carry the full detail; the
non-obvious parts are:

- **Pure and self-contained.** No `builtins.path`, no absolute paths, no local
  checkout — the GitHub input alone builds the package. That is why
  `nixos-rebuild switch` no longer needs `--impure`.
- **Official Node.** `node-addon-require-builtin` resolves Node's internal
  modules by *probing the running Node binary's machine code*; the nixpkgs-built
  Node does not match its patterns (`x64 sysv getter is not a recognized
  this->field accessor`), the official nodejs.org build does. The launcher embeds
  a pinned official Node release, not `pkgs.nodejs_24`.

After editing the fork, commit it, push the branch
(`git push fork trusted-authority-surface`) and refresh the input
(`nix flake lock --update-input deepseek-harness` in nixos-config). The flake's
`DSH_CLIENT_COMMIT_HASH` must be bumped when the commit changes, and the
`pnpmDeps` hash must be regenerated whenever `pnpm-lock.yaml` (or the pnpm
version) changes — set `hash = ""` and paste the hash from the failure.

## Using the GUI (signing in)

The service answers `401` on the bare URL until a browser has presented the launch
token, which `dsh web` mints **per process** and prints only to the journal:

```
dsh web: http://127.0.0.1:3080/?token=… (LAN: http://192.168.49.50:3080/?token=…)
```

A token-carrying URL is therefore a bootstrap credential, not a bookmark.
`dsh-web-url` (installed by `services.dshWebHarness` on the hosts that enable it)
prints the live one, and `--open` hands it to the desktop browser:

```sh
dsh-web-url            # LAN URL of the currently running process
dsh-web-url --local    # the loopback URL (SSH tunnel / same machine)
dsh-web-url --open     # …and open it in the desktop browser
```

What the token mints **is** the bookmark: a `dsh-auth-…` cookie — HttpOnly,
SameSite=Strict, bound to the authority it was issued for, and signed with a
durable secret (`$DSH_HOME/.credentials.yaml`). `cookieMaxAgeDays` (default
`3650` here, `30` upstream) is that cookie's lifetime, so after one token visit
per browser the plain `http://192.168.49.50:3080/` keeps working — across service
restarts, rebuilds and reboots. Reach for `dsh-web-url` again only for a new
browser, a cleared cookie jar, or `--local` over a tunnel.

## Deploy (grafton-router, live)

`hosts/grafton-router/dsh-harness.nix` enables the service with
`trustedHosts = [ "192.168.49.1" ]`:

```sh
cd ~/nixos-config
sudo nixos-rebuild switch --flake .
sudo nixos-confirm          # grafton-router has autoRollback: mandatory
```

`systemctl status dsh-web-harness`; `dsh-web-url` prints the sign-in URL (the
journal carries the same line, `http://192.168.49.1:3080/?token=…`). The unit runs
as `cjdell`, writes its profile patch layer in `preStart`, and serves on
`0.0.0.0:3080`. Its `Environment` overrides systemd's default `PATH`, so the tools
the GUI's agents invoke by name are listed there (`common/dsh-web-service.nix`).

**Security delta, deliberately opt-in:** a declared authority is served over plain
HTTP on the LAN, and possession of the token URL is enough to reach remote code
execution through the GUI. That is exactly what upstream's `--host 0.0.0.0` refusal
protects against; the fork keeps the default safe and makes the exposure an explicit,
named decision (`--trusted-host`). Use it on a LAN you trust, or keep loopback + an
SSH tunnel.

## Verification status

- Built and deployed on grafton-router on 2026-09-21: `dsh-web-harness.service`
  active, listening on `0.0.0.0:3080`, generation confirmed with `nixos-confirm`.
- Fence verified against the deployed service:
  `Host: 192.168.49.1:3080` → `401` (trusted, unauthenticated),
  `Host: 192.168.49.50:3080` → `403` (untrusted),
  `GET /?token=…` → GUI HTML, `http://192.168.49.1:3080/` reachable on the LAN.
- The predicate tests and the patch's reproducibility were verified earlier (16
  cases, byte-for-byte reproduction of the upstream commit).
- Sign-in verified on a scratch instance 2026-09-21 (before deploying the option):
  a patch row replaces the matched row's whole `config`, so the `connection` row
  restates `trustedHosts: !!js ctx.webRuntime.trustedHosts` — with that kept, a
  declared authority is `401` and an undeclared one `403` (the `!!js` expression
  still evaluates in a user patch layer), and the minted cookie carried
  `Max-Age=315360000` (3650 days).
- The legacy `dsh-web` wrapper (`common/dsh-web.{nix,sh}`) and its TCP proxy
  (`common/dsh-web-proxy.mjs`) were deleted 2026-09-21: both bound port 3080, and
  whenever both were up the service crash-looped with `EADDRINUSE: address already
  in use 0.0.0.0:3080`. `dsh-web-url` replaces the URL-lookup half of that script.
- The browser acceptance test — open the token URL from another LAN machine and
  confirm **Settings → Models** works — is user-side and has not been automated.

