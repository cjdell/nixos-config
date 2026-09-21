#!/usr/bin/env bash
# dsh-web — start/stop/status for the DeepSeek Harness web server (`dsh web`).
#
#   dsh-web           start it (or report if it's already running)
#   dsh-web status    show state + the latest startup URL
#   dsh-web stop      stop it
#   dsh-web proxy     start the network proxy (see common/dsh-web-proxy.mjs)
#   dsh-web proxy status|stop
#
# State: $DSH_HOME/web.log (append-only), $DSH_HOME/web.pid,
#        $DSH_HOME/web-proxy.log, $DSH_HOME/web-proxy.pid
#
# Ported from the hand-placed ~/.local/bin/dsh-web; common/dsh-web.nix installs
# it on every host in this flake. Two things it relies on:
#
#   - node/npx on PATH: the Nix wrapper (common/dsh-web.nix) prepends a pinned
#     nodejs, so no system node is needed.
#   - the web profile's dsh.profile.patchReload must be "startup": the
#     shipped dsh template defaults to "live", which needs node
#     --expose-internals, a flag npx cannot pass. ensure_web_profile() below
#     pins it before the first start (no-op on already-configured hosts).
set -u

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
LOG="$DSH_HOME/web.log"
PIDFILE="$DSH_HOME/web.pid"

# Network proxy (dsh-web-proxy.mjs, installed next to this script by
# common/dsh-web.nix): the dsh web server binds 127.0.0.1 only and its /api
# fence 403s non-loopback Host/Origin headers, so `dsh-web proxy` runs a tiny
# zero-dependency node proxy that listens on all interfaces and forwards over
# loopback with Host/Origin rewritten to the upstream's loopback authority.
# Opt-in per host, like dsh web itself — not a systemd service.
PROXY_LOG="$DSH_HOME/web-proxy.log"
PROXY_PIDFILE="$DSH_HOME/web-proxy.pid"
PROXY_PORT="${DSH_WEB_PROXY_PORT:-30800}"
PROXY_BIND="${DSH_WEB_PROXY_BIND:-0.0.0.0}"
SELF_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "$0")")" && pwd)
PROXY_MJS="$SELF_DIR/../lib/dsh-web-proxy.mjs"

# Make the web profile match what `dsh web` needs under npx (see header).
# dsh's own initProfile() never touches files it did not create, so
# pre-creating the manifest is safe; an existing manifest is only rewritten
# when its patchReload is not already "startup", and the patch layer /
# pnpm-workspace files are only written if missing.
ensure_web_profile() {
  local dir="$DSH_HOME/profiles/web"
  mkdir -p "$dir"
  node -e '
    const fs = require("node:fs");
    const dir = process.argv[1];
    const manifestPath = dir + "/package.json";
    let m = { name: "dsh-profile-web", private: true, dependencies: {} };
    try { m = JSON.parse(fs.readFileSync(manifestPath, "utf8")); } catch {}
    m.dsh ??= {};
    m.dsh.profile ??= {
      bundles: ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"],
    };
    if (m.dsh.profile.patchReload !== "startup") {
      m.dsh.profile.patchReload = "startup";
      fs.writeFileSync(manifestPath, JSON.stringify(m, null, 2) + "\n");
    }
  ' "$dir"
  [ -f "$dir/cordis.patch.yml" ] || cat > "$dir/cordis.patch.yml" <<'EOF'
# Your patch layer for this dsh profile, applied after every bundle layer:
# a top-level YAML array of loader patch entries (id-targeted config
# overrides, disables, and insert lists; `!!js` expressions allowed).
[]
EOF
  [ -f "$dir/pnpm-workspace.yaml" ] || cat > "$dir/pnpm-workspace.yaml" <<'EOF'
packages:
  - .

nodeLinker: hoisted
autoInstallPeers: false
EOF
}

# is_running <pidfile> — set REPLY_PID to the live pid, or return 1
is_running() {
  local pidfile=$1 pid
  [ -f "$pidfile" ] || return 1
  pid=$(cat "$pidfile" 2>/dev/null) || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 -- "$pid" 2>/dev/null || return 1
  REPLY_PID=$pid
  return 0
}

# latest_url [offset] — newest startup URL at or after byte offset (default: whole log)
latest_url() {
  tail -c "+${1:-1}" "$LOG" 2>/dev/null | grep -o 'http://[^[:space:]]*token=[^[:space:]]*' | tail -n 1
  return 0
}

start() {
  if is_running "$PIDFILE"; then
    echo "already running (pid $REPLY_PID)"
    local url; url=$(latest_url)
    [ -n "$url" ] && echo "latest URL: $url"
    return 0
  fi
  rm -f "$PIDFILE"
  mkdir -p "$DSH_HOME"
  ensure_web_profile
  # Byte offset so the wait loop only sees output from THIS boot (the log is
  # append-only and holds URLs from earlier runs, each with a dead token).
  local logsize=0
  [ -f "$LOG" ] && logsize=$(wc -c < "$LOG")
  # setsid: run in its own process group so `stop` kills npx and node together.
  # --yes: npx may re-resolve the package (e.g. after a reboot/update) and
  # would otherwise hang on an "Ok to proceed?" prompt.
  setsid nohup npx --yes @deepseek-ai/dsh web >> "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDFILE"

  local url="" i
  for i in $(seq 1 90); do
    is_running "$PIDFILE" || {
      echo "server exited during startup; last lines of $LOG:" >&2
      tail -n 25 "$LOG" >&2
      rm -f "$PIDFILE"
      return 1
    }
    url=$(latest_url $((logsize + 1)))
    [ -n "$url" ] && break
    sleep 1
  done
  if [ -z "$url" ]; then
    echo "timed out waiting for the startup URL; check $LOG" >&2
    return 1
  fi
  echo "started (pid $(cat "$PIDFILE"))"
  echo "$url"
}

stop() {
  if ! is_running "$PIDFILE"; then
    rm -f "$PIDFILE"
    echo "not running"
    return 0
  fi
  local pid=$REPLY_PID i
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM -- "$pid" 2>/dev/null
  for i in $(seq 1 10); do
    kill -0 -- "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 -- "$pid" 2>/dev/null; then
    echo "still alive after SIGTERM; sending SIGKILL" >&2
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
  echo "stopped"
}

status() {
  if is_running "$PIDFILE"; then
    echo "running (pid $REPLY_PID)"
    local url; url=$(latest_url)
    [ -n "$url" ] && echo "latest URL: $url"
  else
    rm -f "$PIDFILE"
    echo "not running"
    return 1
  fi
}

# proxy_upstream — $DSH_WEB_UPSTREAM, else the host:port of the newest
# startup URL in the web log (so a custom --port is picked up), else the
# dsh web default.
proxy_upstream() {
  local upstream="${DSH_WEB_UPSTREAM:-}" port
  if [ -z "$upstream" ]; then
    port=$(latest_url | grep -oE '127\.0\.0\.1:[0-9]+' | tail -n 1 | cut -d: -f2)
    upstream="127.0.0.1:${port:-3080}"
  fi
  echo "$upstream"
}

proxy_start() {
  if is_running "$PROXY_PIDFILE"; then
    echo "proxy already running (pid $REPLY_PID)"
    return 0
  fi
  [ -f "$PROXY_MJS" ] || {
    echo "proxy script missing: $PROXY_MJS" >&2
    return 1
  }
  rm -f "$PROXY_PIDFILE"
  mkdir -p "$DSH_HOME"
  local upstream
  upstream=$(proxy_upstream)
  if ! timeout 2 node -e '
      const net = require("node:net");
      const s = net.connect(Number(process.argv[1]), process.argv[2], () => process.exit(0));
      s.on("error", () => process.exit(1));
    ' "${upstream#*:}" "${upstream%%:*}" 2>/dev/null; then
    echo "warning: upstream $upstream is not reachable yet; requests will 502 until it is up (start it with: dsh-web)" >&2
  fi
  # Byte offset so the wait loop only sees output from THIS boot.
  local logsize=0
  [ -f "$PROXY_LOG" ] && logsize=$(wc -c < "$PROXY_LOG")
  setsid nohup node "$PROXY_MJS" >> "$PROXY_LOG" 2>&1 < /dev/null &
  echo $! > "$PROXY_PIDFILE"
  local i
  for i in $(seq 1 30); do
    is_running "$PROXY_PIDFILE" || {
      echo "proxy exited during startup; last lines of $PROXY_LOG:" >&2
      tail -n 25 "$PROXY_LOG" >&2
      rm -f "$PROXY_PIDFILE"
      return 1
    }
    tail -c "+$((logsize + 1))" "$PROXY_LOG" | grep -q "dsh-web-proxy: listening" && break
    sleep 0.5
  done
  local ip url token
  # First non-loopback IPv4 (node is on PATH via the Nix wrapper; not every
  # host's `hostname` supports -I).
  ip=$(node -e '
      const nets = require("node:os").networkInterfaces();
      for (const list of Object.values(nets))
        for (const a of list ?? [])
          if (a.family === "IPv4" && !a.internal) {
            console.log(a.address);
            process.exit(0);
          }
    ' 2>/dev/null)
  echo "proxy started (pid $(cat "$PROXY_PIDFILE"))"
  echo "upstream: $upstream"
  echo "listen:   $PROXY_BIND:$PROXY_PORT"
  url=$(latest_url)
  if [ -n "$url" ]; then
    token=${url##*token=}
    echo "remote:   http://${ip:-<host>}:$PROXY_PORT/?token=$token"
  fi
}

proxy_stop() {
  if ! is_running "$PROXY_PIDFILE"; then
    rm -f "$PROXY_PIDFILE"
    echo "proxy not running"
    return 0
  fi
  local pid=$REPLY_PID i
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM -- "$pid" 2>/dev/null
  for i in $(seq 1 10); do
    kill -0 -- "$pid" 2>/dev/null || break
    sleep 0.5
  done
  if kill -0 -- "$pid" 2>/dev/null; then
    echo "still alive after SIGTERM; sending SIGKILL" >&2
    kill -KILL -- "-$pid" 2>/dev/null || true
  fi
  rm -f "$PROXY_PIDFILE"
  echo "proxy stopped"
}

proxy_status() {
  if is_running "$PROXY_PIDFILE"; then
    echo "proxy running (pid $REPLY_PID)"
    tail -n 200 "$PROXY_LOG" 2>/dev/null | grep "dsh-web-proxy: listening" | tail -n 1
  else
    rm -f "$PROXY_PIDFILE"
    echo "proxy not running"
    return 1
  fi
}

case ${1:-start} in
  start)  start ;;
  status) status ;;
  stop)   stop ;;
  proxy)
    shift
    case ${1:-start} in
      start)  proxy_start ;;
      status) proxy_status ;;
      stop)   proxy_stop ;;
      *)      echo "usage: dsh-web proxy [start|status|stop]" >&2; exit 2 ;;
    esac
    ;;
  *)      echo "usage: dsh-web [start|status|stop] | dsh-web proxy [start|status|stop]" >&2; exit 2 ;;
esac
