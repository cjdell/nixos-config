> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## DeepSeek Harness web GUI (`dsh-web-harness`, live on zen3-nixos + grafton-router)

The forked DeepSeek Harness Web GUI, as an always-on service:
`common/dsh-web-service.nix` (`services.dshWebHarness`), enabled by
`hosts/zen3-nixos/dsh-harness.nix` (`192.168.49.50:3080`) and
`hosts/grafton-router/dsh-harness.nix` (`192.168.49.1:3080`). Background and the
fork patch: `docs/dsh-fork/`.

- **The bare URL is `401` by design.** `dsh web` mints a random launch token per
  process and prints one URL carrying it; that URL is the bootstrap, and its
  token changes on every restart. Get the live one with **`dsh-web-url`** (prints
  the LAN URL; `--local` for loopback, `--open` to open it in a desktop browser).
- **What it mints is the bookmark.** The token sets an HttpOnly, SameSite=Strict
  `dsh-auth-…` cookie, bound to the authority it was issued for and signed with a
  durable secret (`~/.dsh/.credentials.yaml`), so it survives restarts and
  rebuilds. It lives `services.dshWebHarness.cookieMaxAgeDays` (default 3650
  days; upstream's is 30), so after **one** token visit per browser the plain
  `http://192.168.49.50:3080/` is all you need.
- **Don't undo the `!!js` line.** The module's cordis patch layer sets
  `cookieMaxAgeDays` on the `connection` row, and a patch **replaces** the matched
  row's whole `config` — so the row restates
  `trustedHosts: !!js ctx.webRuntime.trustedHosts` verbatim. Drop it and the
  `/api` fence has no declared authority: every LAN request 403s while loopback
  still looks fine.
- The legacy `dsh-web` wrapper (`common/dsh-web.{nix,sh}`) and its TCP proxy
  (`common/dsh-web-proxy.mjs`) were removed 2026-09-21: they drove `npx` against
  the *same* port 3080, so whenever both were up the service crash-looped with
  `EADDRINUSE`. Don't reintroduce a second thing that binds 3080.
- Deploy = `nixos-rebuild switch` on the host (+ `sudo nixos-confirm` on
  **grafton-router**, which has autoRollback; zen3-nixos has it commented out).

