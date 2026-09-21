# DeepSeek Harness fork → NixOS service: handover

**Status: DONE — built and deployed on grafton-router 2026-09-21. Service live.**

> **Superseded later on 2026-09-21:** the offline/vendored-`node_modules` design
> described below was replaced by a pure `fetchPnpmDeps` build in the fork's
> flake (commit `df9c99e58a`). The fork no longer needs a local checkout and
> `nixos-rebuild` no longer needs `--impure`. References below to vendored
> `node_modules`, absolute paths, or building from `~/Projects/deepseek-harness`
> are historical; see `docs/dsh-fork/README.md` for the current build.

See “Outcome” below for the extra blockers that the original handover did not
know about, and the fix for each.

## Outcome (2026-09-21)

The checkout repair was finished and the `node_modules` damage was actually
wider than the handover thought: 47 symlinks (13 broken, 34 resolving only via
the `/tmp/dshtest` back-symlink) pointed through the dead scratch path. All 47
were rewritten lexically back to repo-relative targets, and `.modules.yaml` was
healed (`storeDir` → the real store, `virtualStoreDir` → `.pnpm`);
`pnpm install --frozen-lockfile --offline` then reported “Already up to date”.
The `/tmp/dshtest` landmine is real and cost this much — never symlink the
checkout’s `node_modules` into a scratch dir.

With the tree healed, the nix build needed six fixes the handover had not
identified (all now in the fork’s `flake.nix`, commits `3d99321d7b`):

1. **`pm-on-fail` is not an `.npmrc` setting in pnpm 11.9.0** (the handover’s
   `manage-package-manager-versions` does not exist at all). The startup
   version gate (`switchCliVersion`) fetches `@pnpm/exe`/`pnpm` from the
   registry; it is skipped only when the wanted manager’s `onFail` is
   `ignore`, and pnpm 11 reads that from **`pnpm-workspace.yaml`**
   (`pmOnFail: ignore`). `verifyDepsBeforeRun: false` goes there too.
2. **`cp -a` from the store is read-only**, so the `.modules.yaml` rewrite and
   the build could not write; added `chmod -R u+w`.
3. **All per-workspace-project `node_modules` must be vendored**, not just the
   root — otherwise `tsc` cannot resolve `website/node_modules/vitepress`
   (2981 errors). A filtered impure path captures them.
4. **`DSH_CLIENT_COMMIT_HASH`** must be supplied: the flake source has no
   `.git`, and `scripts/build.ts` calls `git rev-parse HEAD`. It is set to the
   fork commit the package was built from.
5. **The launcher needs the official Node binary.** `node-addon-require-builtin`
   probes the running Node binary’s machine code; the nixpkgs-built Node fails
   (`x64 sysv getter is not a recognized this->field accessor`) while the
   official nodejs.org build works. `$out/bin/dsh` embeds a pinned official
   Node 24.16.0.
6. **The nixos-config input must be `git+file:`, not `path:`.** A `path:` flake
   input materialises the whole directory (node_modules, .git, build outputs —
   ~90k files) as the flake source; `git+file:///home/cjdell/Projects/deepseek-harness`
   yields the same git-filtered source as the fork’s own `nix build`, so the
   locked derivation matches the tested one exactly.

The `bin/dsh` heredoc also had a latent bug — an unquoted heredoc expanded
`"$@"` at build time to the build phase name (`installPhase`) — now escaped.

Deployment: `nixos-rebuild switch` + `nixos-confirm` twice (the first attempt
failed because the module’s `Environment=PATH` hid `install` from `preStart`;
`preStart` now uses an absolute coreutils path and the unit PATH lists the GUI’s
expected userland). Final state: `dsh-web-harness.service` active on
`0.0.0.0:3080`, fence verified (`401` trusted, `403` untrusted), GUI HTML served.
The only thing left is the browser acceptance check (Settings → Models from a
LAN machine).

## Mission

The fork `~/Projects/deepseek-harness/` (branch `trusted-authority-surface`, HEAD
`7f47ec93f2` = upstream `ddefc45fbc` + the patch in `docs/dsh-fork/trusted-authority-surface.patch`)
makes a *declared* LAN authority the operator's own surface for `dsh web`, so the GUI works
without an SSH tunnel / Host-rewriting proxy. The work:

1. Give the fork **its own flake** with a derivation for the built app. ✅ written
2. Add it to this flake (nixos-config) as an **input** and run it as a **systemd service**. ✅ written
3. **Prove it on grafton-router** (this machine, 192.168.49.1) first; zen3-nixos is
   pre-wired but explicitly out of scope ("we'll roll it out to other machines once proven").
   ⏳ blocked on the build (below)

## ⚠️ Read first: in-flight checkout repair + a landmine

During diagnosis I **corrupted the checkout's `node_modules` metadata**: I symlinked
`~/Projects/deepseek-harness/node_modules` into a scratch dir (`/tmp/dshtest`, since removed)
and ran pnpm there; pnpm followed the symlink and reified the *real* checkout, overwriting
`node_modules/.modules.yaml` (storeDir → a dead `/tmp/tmp.*` path, virtualStoreDir →
`../../../../../tmp/dshtest/node_modules/.pnpm`). The `.pnpm` tree itself (relative links) is
believed intact; the metadata is wrong.

A repair is/was running at handover time:

```
cd ~/Projects/deepseek-harness
/nix/store/gfrj5gwr59daw5qi72phra770mi0xvh1-pnpm-11.9.0/bin/pnpm install --frozen-lockfile
# log: /tmp/checkout-repair.log
```

**Check it finished** (`pgrep -f 'pnpm install'`), then verify the metadata is healed:

```
grep -E '"(storeDir|virtualStoreDir)"' ~/Projects/deepseek-harness/node_modules/.modules.yaml
# want: storeDir = /home/cjdell/.local/share/pnpm/store/v11
#       virtualStoreDir = local (".pnpm" or "node_modules/.pnpm" relative)
```

**Landmine: never symlink the checkout's node_modules into a scratch dir for pnpm testing.**
Copy, or use a minimal manifest dir. (This is how the corruption happened.)

## What already exists (all in place, config evaluates cleanly)

### Fork flake: `~/Projects/deepseek-harness/flake.nix` (staged, uncommitted)

- `packages.x86_64-linux.default` = the **complete built workspace tree**: `src` is the
  git-filtered checkout (node_modules/lib/dist are .gitignore'd out), plus the checkout's
  `node_modules` **vendored** via `builtins.path { path = "/home/cjdell/Projects/deepseek-harness/node_modules"; filter = _:_: true; }`
  (absolute path → **flake must be evaluated with `--impure`**; matches the repo's
  `nixos-rebuild switch --impure --flake .` convention).
- nixpkgs **pinned** to `0ad6f47ea4fe188f4bc8f0380f93ae8523337c6c` (26.05.20260707, the
  grafton pin — verified to carry pnpm 11.9.0 + nodejs_24 24.16.0; `musl-gcc` is absent but
  unneeded: `pnpm run build`'s native stage compiles only the host `flock` addon via `cc`).
- `installPhase`: `cp -a` the vendored node_modules → write a build-tree `.npmrc` →
  `pnpm run build` (native addon + tsc host/client + tsdown + vite) → `cp -a` tree to `$out`
  → delete build residue → `$out/bin/dsh` launcher embedding the build's Node.

### nixos-config

- `flake.nix`: input `deepseek-harness = { url = "path:/home/cjdell/Projects/deepseek-harness"; }`
  (no `follows` — the fork pins its own nixpkgs). `flake.lock` updated.
- `common/dsh-web-service.nix` (staged): `services.dshWebHarness` module — package-based
  (`dsh` option defaults to the input's package), `trustedHosts`/`settingsIp`, per-machine
  settings document (`settings-<ip>.yaml`) via a cordis patch layer installed in `preStart`,
  `ExecStart = ${dsh}/bin/dsh web --host 0.0.0.0 --port 3080 --no-open --trusted-host …`,
  runs as `cjdell` with `HOME=/home/cjdell`, `DSH_HOME=/home/cjdell/.dsh`, `PATH=${dsh}/bin`.
- `common/system.nix`: imports the module for the other hosts.
- `hosts/grafton-router/default.nix`: imports `../../common/dsh-web-service.nix` and `./dsh-harness.nix`.
- `hosts/grafton-router/dsh-harness.nix` (staged): enables it, `trustedHosts = [ "192.168.49.1" ]`.
- `hosts/grafton-router/configuration.nix`: **`swapDevices = [ { device = "/swapfile"; size = 8192; } ]`**
  — NOTE: this 2026 nixpkgs has **top-level `swapDevices`, not `boot.swaps`** (that option is gone;
  the module lives at `nixos/modules/config/swap.nix`).
- `hosts/zen3-nixos/dsh-harness.nix` (staged): pre-wired for 192.168.49.50; untested, out of scope.
- `docs/dsh-fork/README.md` (staged): full diagnosis + patch. **Its "Build and deploy (NOT yet
  done)" and "Verification status" sections are now STALE** — update them after deployment.

### Router runtime state

- **8 GiB swapfile created and swapon'd** (`/swapfile`, also persisted via `swapDevices` above).
  The router had 15.7 GiB RAM, ~3 GiB available, **no swap** — the tsc/vite build phases
  (host tsc self-caps at 4 GiB) needed the cushion.
- Nothing listening on 3080/30800 yet. The old npx-based `dsh-web` wrapper
  (`common/dsh-web.nix`) is still a systemPackage on the router; the 30800 proxy design is
  superseded by this service.
- Router: 4 cores, no build machines (local builds), nix 2.34.7, ~68 G free on `/`.

## Proven facts (so you don't re-derive them)

1. **Nix 2.34 sandbox = private network namespace** (loopback only) for every sandboxed
   (input-addressed) derivation — proven with test drv (`EAI_AGAIN`/`ENETUNREACH` from inside).
   Only fixed-output derivations get networking. `dontUseSandbox = true` is **ignored** in
   2.34 — sandboxing is decided by derivation type
   (`src/libstore/derivations.cc: DerivationType::isSandboxed()`: IA→always, CA-floating→yes,
   CA-fixed→no, impure→no). This is why the build must be **fully offline**.
2. **The pnpm content store is not byte-reproducible** (`v11/files/` is deterministic across
   fetches, `v11/index.db` SQLite is not — 13.8 MB of diff), so a fixed-output store derivation
   is not viable → hence vendored `node_modules`.
3. **pnpm 11 gotchas, all verified:**
   - On every `pnpm run`, pnpm honours the `packageManager` field (pnpm@11.7.0) by
     **downloading that pnpm from the registry and re-exec'ing** it unless
     `manage-package-manager-versions=false` (works via project `.npmrc`; the env var
     `npm_config_verify_deps_before_run` form does NOT work for this key).
   - `verify-deps-before-run` re-runs `pnpm install` when it thinks the tree is out of sync —
     disable via the same `.npmrc`.
   - `pnpm fetch` (the "official" offline idea) also runs lifecycle scripts and needs the
     repo's `patches/` dir; its store is the non-reproducible one above.
   - pnpm's **startup consistency check** (separate from the two above) reifies when
     `node_modules/.modules.yaml` doesn't match the environment — **this is the live blocker** (next section).
4. `nixosConfigurations.grafton-router` **evaluates cleanly** with the new module;
   `services.dshWebHarness` resolves the `dsh` package (verified with
   `nix eval --impure .#nixosConfigurations.grafton-router.config.services.dshWebHarness`).
5. Manual `pnpm install && pnpm run build` **does work in this checkout on this router**
   (artifacts present; pnpm store `~/.local/share/pnpm/store/v11`, 1.9 G, complete for this
   lockfile) — so the dependency tree is sound; only the nix-build wiring remains.

## The blocker (root-caused, fix designed, not applied)

Build (sandboxed, offline) fails on the first pnpm call:

```
[ERROR] GET https://registry.npmjs.org/pnpm: fetch failed
For help, run: pnpm help run
```

That `GET /pnpm` is the **packument for the npm package `pnpm`** (apps/desktop depends on
`pnpm: 11.7.0`) — i.e. pnpm is attempting a full **reify/install**, not a version re-exec
(that's handled by the `.npmrc`). Cause: `node_modules/.modules.yaml` records an **absolute
`storeDir`** (`/home/cjdell/.local/share/pnpm/store/v11`) that doesn't exist inside the
sandbox → pnpm's startup consistency check decides the tree is inconsistent → reify →
registry → sandbox netns → fail.

**Fix (designed, not yet in flake.nix):** in `installPhase`, after `cp -a ${nodeModules}
node_modules` and before `pnpm run build`, rewrite the metadata to build-local paths
(`.modules.yaml` is plain JSON):

```sh
mkdir -p "$TMPDIR/pnpm-store"
node -e '
  const fs = require("node:fs");
  const f = "node_modules/.modules.yaml";
  const m = JSON.parse(fs.readFileSync(f, "utf8"));
  m.storeDir = process.env.TMPDIR + "/pnpm-store/v11";
  m.virtualStoreDir = "./.pnpm";   # relative to the .modules.yaml dir, as pnpm stores it
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n");
'
```

If pnpm *still* reifies after that, inspect what else in `.modules.yaml` can mismatch
(`prunedAt`, `pendingBuilds`, `packageManager`, `layoutVersion`) and/or run
`pnpm install --frozen-lockfile --offline` with a seeded store as a fallback.

## Next steps, in order

1. Confirm the checkout repair finished + `.modules.yaml` healed (commands above).
2. Add the `.modules.yaml` patch to the fork flake's `installPhase`; `git add flake.nix`.
3. Rebuild (background, monitor RAM — swap is your friend):
   ```
   cd /tmp && nix build --impure /home/cjdell/Projects/deepseek-harness#packages.x86_64-linux.default
   ```
   (~10–15 min: 2 G node_modules copies, tsc up to 4 G, vite, final ~2.5 G copy to $out.)
4. Smoke-test the output: `<out>/bin/dsh web --help`, `ls <out>/apps/web/dist/index.html`,
   `ls <out>/native/system/packages/linux-x64/bin/glibc/system.node`.
5. **Commit** `flake.nix` + `flake.lock` in the fork repo (branch `trusted-authority-surface`).
6. In nixos-config: `nix flake lock --update-input deepseek-harness` (the input froze at the
   tree state when it was first locked; re-freeze after the flake commit).
7. Deploy:
   ```
   cd ~/nixos-config && sudo nixos-rebuild switch --impure --flake . && sudo nixos-confirm
   ```
   **`nixos-confirm` is mandatory** — the router has `system.autoRollback.enable = true` and
   will roll back (and reboot!) ~5 min after an unconfirmed switch.
8. Verify the service:
   - `systemctl status dsh-web-harness`; `journalctl -u dsh-web-harness` → prints
     `http://192.168.49.1:3080/?token=…`.
   - Fence (both must behave):
     ```
     curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 192.168.49.1:3080' -d '{}' http://127.0.0.1:3080/api/   # expect 401 (trusted, unauthenticated)
     curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Host: 192.168.49.50:3080' -d '{}' http://127.0.0.1:3080/api/   # expect 403 (untrusted)
     ```
   - `curl -s http://127.0.0.1:3080/ | head` → GUI HTML.
   - Browser from another LAN machine: open the token URL → **Settings → Models must work**
     (that is the whole point of the fork).
9. Update the stale sections of `docs/dsh-fork/README.md` ("Build and deploy (NOT yet done)",
   "Verification status") and this handover (delete or mark done).
10. Clean up scratch: `/tmp/{fetchtest,dshtest,pmtest,nettest,npeval,npeval3,dsh-build.log,checkout-repair.log}`.

## Environment facts / gotchas

- `python3` is **not** on PATH on the router (`nix shell nixpkgs#python3 --command …` if needed).
- All nixos-config evals/builds need `--impure` (the fork flake reads an absolute path; repo
  convention anyway).
- pnpm binaries available: store pnpm 11.9.0 at
  `/nix/store/gfrj5gwr59daw5qi72phra770mi0xvh1-pnpm-11.9.0/bin/pnpm`; the repo wants
  pnpm 11.7.0 (corepack) — 11.9.0 works fine for installs in the checkout.
- The `just` entry added to the router's `environment.systemPackages` (WIP from an earlier
  session) — leave it.
- git state at handover —
  - nixos-config **staged**: `common/dsh-web-service.nix`, `docs/dsh-fork/{README.md,
    trusted-authority-surface.patch}`, `hosts/grafton-router/dsh-harness.nix`,
    `hosts/zen3-nixos/dsh-harness.nix`, (+ this file)
  - nixos-config **modified, unstaged**: `flake.nix`, `flake.lock`, `common/system.nix`,
    `hosts/grafton-router/{configuration.nix,default.nix}`, `hosts/zen3-nixos/default.nix`
  - fork repo: `flake.nix` + `flake.lock` **staged, uncommitted** on `trusted-authority-surface`.
- Background processes at handover: the checkout repair (`pnpm install`, log
  `/tmp/checkout-repair.log`) — may have finished by the time you read this; nothing else.

## Why the design is the way it is (one paragraph)

Nix 2.34 sandboxes every regular derivation in a private netns, so no registry access inside
the build; and pnpm's content store (`index.db`) is not byte-reproducible, so a fixed-output
"pre-fetch" derivation isn't viable either. The build therefore runs **offline against the
checkout's already-installed `node_modules`** (vendored as a path input), and pnpm is kept
from re-touching the tree/version with a build-tree `.npmrc` — leaving exactly the tsc/tsdown/
vite compilation, which needs no network. Rollout to other machines = clone the fork,
`pnpm install` there (same path), `--impure` eval, same service module.
