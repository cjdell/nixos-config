# DeepSeek Harness fork: declared authorities are the operator's own surface

Why this exists: `http://192.168.49.1:30800/` (the `dsh-web proxy` → `dsh web` GUI on
grafton-router) loads and chats, but **Settings → Models** dies with

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

Verify the fence/wire side yourself (both must be `401`, i.e. trusted but
unauthenticated — the proxy rewrites `Host` to `127.0.0.1:3080`, which is why the
proxy works today):

```sh
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 127.0.0.1:3080' -d '{}' http://127.0.0.1:3080/api/
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 192.168.49.1:30800' -H 'Origin: http://192.168.49.1:30800' -d '{}' http://127.0.0.1:3080/api/  # 403: untrusted without the rewrite
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
`~/Projects/deepseek-harness/flake.nix`). It vendors the checkout's installed
`node_modules`, runs `pnpm run build` offline in the Nix 2.34 sandbox, and
installs the built tree with `$out/bin/dsh`. nixos-config consumes it as the
`deepseek-harness` input and runs it through `services.dshWebHarness`
(`common/dsh-web-service.nix`) — no `npx`, no checkout build, no proxy.

Nothing is built on grafton-router: the package comes from the fork's flake and
the router only activates it. The flake's comments carry the full detail; the
non-obvious parts are:

- **Offline pnpm.** Nix 2.34 sandboxes input-addressed derivations in a private
  netns, so the build must not touch the registry. pnpm 11 keeps its settings in
  `pnpm-workspace.yaml` (not `.npmrc`): `pmOnFail: ignore` stops the
  `packageManager`-field version switch (which fetches `@pnpm/exe`), and
  `verifyDepsBeforeRun: false` stops the deps-status auto-install. The vendored
  `.modules.yaml`'s absolute `storeDir` is rewritten to the build store.
- **All `node_modules` are inputs.** pnpm links each workspace project's direct
  deps into its own `node_modules`; vendoring only the root tree leaves `tsc`
  unable to resolve e.g. `website/node_modules/vitepress`. The flake vendors the
  project-local trees too.
- **Official Node.** `node-addon-require-builtin` resolves Node's internal
  modules by *probing the running Node binary's machine code*; the nixpkgs-built
  Node does not match its patterns (`x64 sysv getter is not a recognized
  this->field accessor`), the official nodejs.org build does. The launcher embeds
  a pinned official Node release, not `pkgs.nodejs_24`.
- **Hosted `github:` input.** The flake source is the `trusted-authority-surface`
  branch of `github:cjdell/deepseek-harness`: the tarball holds only tracked
  files, so (like the earlier `git+file:` local input, and unlike a bare `path:`
  input that would materialise `node_modules/`, `.git/` and build outputs) the
  fork's `src = ./.` stays the git-filtered checkout — and the input no longer
  needs the local directory to exist. The local checkout is still required on
  the *building* machine, because the flake vendors its `node_modules` from
  there (previous bullet).

After editing the fork, commit it, push the branch
(`git push fork trusted-authority-surface`) and refresh the input
(`nix flake lock --update-input deepseek-harness --impure` in nixos-config).
The flake's `DSH_CLIENT_COMMIT_HASH` must also be bumped when the commit changes.

## Deploy (grafton-router, live)

`hosts/grafton-router/dsh-harness.nix` enables the service with
`trustedHosts = [ "192.168.49.1" ]`:

```sh
cd ~/nixos-config
sudo nixos-rebuild switch --impure --flake .
sudo nixos-confirm          # grafton-router has autoRollback: mandatory
```

`systemctl status dsh-web-harness`; the journal prints
`http://192.168.49.1:3080/?token=…`. The unit runs as `cjdell`, writes its profile
patch layer in `preStart`, and serves on `0.0.0.0:3080`. Its `Environment`
overrides systemd's default `PATH`, so the tools the GUI's agents invoke by name
are listed there (`common/dsh-web-service.nix`).

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
- The browser acceptance test — open the token URL from another LAN machine and
  confirm **Settings → Models** works — is user-side and has not been automated.

