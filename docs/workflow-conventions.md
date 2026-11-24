> Archived from AGENTS.md (2026-11-24). The short version lives in AGENTS.md; this file holds the full backstory.

## Workflow conventions

- **Prefer helper scripts over inline one-liners for repeated/complex operations**
  (HA API calls, multi-step deploys, TFTP testing, …). Keep them in `scripts/`
  (committed) or `/tmp/` (scratch), make them idempotent, and give every
  network call a `timeout`. Existing: `scripts/update-pi5-node.sh` (enroll a
  join code, re-lock the gc-rust-node input, `nixos-rebuild switch` +
  `nixos-confirm`, power-cycle the Pi, verify),
  `scripts/pi5-powercycle.sh` (HA relay: default full cycle, `--off`/`--on`),
  `scripts/deploy-meter-relay.sh` (rebuild the `crates/meter-relay-rs` crate on
  grafton-router, confirm, verify — see that section).
  Do not paste HA tokens/curls inline in agent sessions — call the script.
- **Set timeouts on everything that talks to the network** (`timeout N cmd`);
  bare `ssh`/`curl`/`ping` to a flaky or dead host will stall the session.
  Never `pgrep -f`/`pkill -f` with a pattern that matches your own shell's
  command line (it self-matches and loops).
- **Poll for long-running work with a bounded loop, never one long `sleep`.**
  A single `sleep 300` blocks the turn (and gets aborted) with no progress
  visibility. Run the job in the background with output to a log, then loop a
  short sleep with a status line each iteration, e.g.:

  ```sh
  for i in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || { echo "[done] ($i)"; break; }
    printf '[%s] ' "$i"; tail -1 /tmp/job.log
    sleep 15
  done
  ```

  Check liveness with the job's PID (`kill -0`) or a `pgrep` pattern that
  cannot match the polling shell itself — not a long blocking sleep.
- **Watchers must be kill-proof by construction: log marker, not `systemctl`.**
  Remote-state polling (`ssh host 'systemctl is-active X'`) is the unreliable
  half: under heavy NFS/disk load `systemctl` wedges on its dbus round-trip
  and the ssh probe times out, while plain file reads on the same host keep
  working. So an `is-active` watcher cannot distinguish "still running" from
  "signal lost", and an error-tolerating clause (`|| st=ssh-error` + continue)
  turns a lost signal into an infinite "running": the Dell-tape stitch watcher
  on kabylakeitx (2026-11-06) watched a finished job for 3 h 40 m past its
  last poll, and the TUI's terminate did not reap it. The rules:
  1. **Key completion on the job's own log**, written by the wrapper script
     itself (a terminal `DONE`/`FAIL` line), and `grep` for it via ssh —
     a file read that survives exactly the load that kills `systemctl`.
  2. **Budget by wall-clock, not just iterations**: `deadline=$(( $(date +%s)
     + expected_secs * 3 / 2 + 1800 ))` and break on it, so a wrong poll
     interval can never stretch the watch. Every watcher prints a terminal
     line (`DONE|FAIL|LOST-SIGNAL|DEADLINE`) and exits — no exit path is a bug.
  3. **Watchers only observe; the systemd unit owns all cleanup** (restart
     F@H, confirm, etc. inside the unit script) so killing a watcher mid-watch
     must always be safe.
- **Reaping a wedged background shell when the UI kill fails**: find the group
  and signal it — `ps -eo pid,pgid,etime,args | grep "[u]nique-watch-word"`,
  then `kill -KILL -<PGID>` (negative = whole group, takes the child `ssh`/
  `sleep` with it). OpenCode then marks the shell completed ("Killed by
  SIGTERM"). Watch the pattern bracket so the `grep`/`ps` cannot match its
  own command line.
- **Never pipe a whole capture file through a byte-level tool.** A 5.7 GB `.mpg`
  is ~17 GB of hex text, and `od -An -tx1 -v FILE | tr ' ' '\n' | awk '{a[NR]=$2}'`
  holds one array element per byte: it reached 7 GB RSS / 15 GB virtual on this
  7.7 GB laptop, ate all 9.2 GB of swap and froze the desktop for four minutes
  until the OOM killer picked it (2026-11-02, `awk` pid 61629; nothing else was
  killed). Read a bounded window instead -
  `dd bs=1M count=2 iflag=skip_bytes skip=<offset> if=FILE | od -tx1` -
  and ask first whether the check is even needed: in that case the answer had
  already been proved by two encodes of the same source in the same container
  reporting different field orders, which can only come from the bitstream.
- Do not run heavy builds unless the task requires it; the user applies Nix
  config themselves when they prefer.
- If you DO apply a config (with permission), always finish with
  `sudo nixos-confirm` on autoRollback hosts.
- The repo often has uncommitted/staged changes (e.g. `hosts/zen3-nixos/ai/`,
  `default.nix`)
  plus untracked scratch files (`dump.txt`, `logs.txt`, `ppp.sh`, `result*`).
  Leave them alone unless the task is about them.
