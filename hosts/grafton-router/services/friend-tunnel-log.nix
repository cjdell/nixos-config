# Friend tunnel — LAN-only connection log.
#
# Answers one question, for whoever runs the router: when he dials in, did it
# work, and if not, WHICH LAYER died? The three layers fail differently, and
# the client only ever sees "not working":
#
#   EDGE      nginx sees the TCP+TLS connection, so it knows the real client IP
#             and the HTTP status of the WebSocket upgrade (101 = accepted).
#   CARRIER   wstunnel authorised the path and opened the UDP leg. It logs
#             richly, but its peer address is nginx on loopback — so IPs here
#             are useless, only outcomes matter.
#   WIREGUARD the crypto layer above it. It can fail while the two below are
#             perfect, which is exactly what a mismatched public key looks
#             like — and that is the most useful thing to be able to tell him.
#
# Rendering is a oneshot on a 20 s timer writing a static file, not a daemon:
# nothing new listens on the network, a hung render cannot hang a request, and
# the page auto-refreshes. Journal-only inputs — the `nginx_tunnel` syslog tag
# is set up in friend-tunnel.nix, which is also why nginx logs at all here.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  c = import ../networking/constants.nix;
  stateDir = "/var/lib/friend-tunnel-log";

  headHtml = pkgs.writeText "friend-tunnel-log-head.html" ''
    <!doctype html><html><head><meta charset=utf-8>
    <meta http-equiv=refresh content="20">
    <title>Friend tunnel — connection log</title>
    <style>
      body{font:14px/1.45 ui-monospace,SFMono-Regular,monospace;background:#101418;color:#d8dee6;margin:1.5em;max-width:1200px}
      h1{font-size:1.1em;margin:0 0 .2em} .sub{color:#7d8894;margin-bottom:1.2em}
      .card{border:1px solid #2a323c;border-left-width:5px;padding:.6em .9em;margin:.5em 0;border-radius:3px}
      .ok{border-left-color:#3fb950} .bad{border-left-color:#f85149}
      .warn{border-left-color:#d29922} .info{border-left-color:#58a6ff}
      table{border-collapse:collapse;width:100%;margin-top:.4em}
      td,th{text-align:left;padding:.25em .5em;border-bottom:1px solid #232a33;vertical-align:top}
      th{color:#7d8894;font-weight:normal}
      tr.bad td{color:#ffb3ad} tr.warn td{color:#e8c37a}
      .kv{display:inline-block;background:#1a2027;padding:.1em .5em;margin-right:.4em;border-radius:3px}
      code{background:#1a2027;padding:.05em .3em}
      pre{white-space:pre-wrap;word-break:break-word;color:#8b96a3;font-size:12px}
      a{color:#58a6ff} .lan{color:#d29922}
    </style></head><body>
    <h1>Friend tunnel — connection log</h1>
    <div class=sub><span class=lan>LAN only</span> · auto-refreshes every 20 s · window: last 3 days
  '';

  render = pkgs.writeShellScript "friend-tunnel-log-render" ''
    set -u

    OUT=${stateDir}
    SINCE='3 days ago'
    WG=${c.WG_FRIEND_INTERFACE}
    PORT=${toString c.WG_FRIEND_PORT}
    SUBNET=${c.FRIEND_V6_SUBNET}
    LOG=${c.FRIEND_TUNNEL_HOST}
    SECRET=${c.FRIEND_TUNNEL_WS_PREFIX}
    MASK='hrx9…'

    mkdir -p "$OUT"
    WORK=$(mktemp -d)
    trap 'rm -rf "$WORK"' EXIT

    # HTML-escape one field. wstunnel's Rust messages are full of < and >, so an
    # unescaped line silently destroys the rest of the page.
    h() { printf "%s\n" "$*" | sed -e "s/&/\\&amp;/g" -e "s/</\\&lt;/g" -e "s/>/\\&gt;/g"; }
    # wstunnel's tracing subscriber writes ANSI colour into the journal
    # unconditionally, so strip it or the page fills with escape-sequence mush.
    noansi() { sed -e "s/\x1b\[[0-9;]*m//g" -e "s/\x1b\[K//g"; }
    # Strip our own markup for the plain-text version.
    t() { sed -e 's/<[^>]*>//g' -e 's/&lt;/</g' -e 's/&gt;/>/g' -e "s/&amp;/\\&/g"; }
    # grep -c counts lines, prints 0 itself, and exits 1 when there were none.
    cnt() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null || true); printf '%s' "''${n:-0}"; }

    # ── EDGE: one line per connection attempt, with the REAL client IP ──────
    # Fields 1-4 are fixed; the request is $5..NF-1 rejoined, because a client
    # that puts a | in its request line must not be able to forge a column.
    # ⚠️ `journalctl -t nginx_tunnel` finds NOTHING: journald takes the
    # identifier from the sending process (`nginx`), and nginx's own `tag=` text
    # lands INSIDE the message body — "grafton-router nginx_tunnel: 192.168.49.1
    # - - [15/Nov/2026:18:08:17 +0000] "GET / HTTP/2.0" 404 146 …". So select on
    # the unit and anchor on the marker, then strip everything up to it.
    # What remains is nginx's `combined` format:
    #   <ip> - - [15/Nov/2026:18:08:17 +0000] "<REQ>" <status> <bytes> "<ref>" "<ua>"
    # so the client IP is the first token and (request, status) come out of one
    # regex — gawk's 3-argument match, which is why gawk is in the unit path
    # list rather than whatever awk else is lying around.
    journalctl --no-pager -u nginx -o short-iso --since "$SINCE" 2>/dev/null | noansi |
    awk -v secret="$SECRET" -v mask="$MASK" '
      index($0, "nginx_tunnel:") == 0 { next }
      {
        ts=$1; rest=$0; sub(/^.*nginx_tunnel:[ ]+/, "", rest);
        ip=rest; sub(/[ ].*/, "", ip);
        if (!match(rest, /"([A-Z]+ [^"]*)" ([0-9]{3}) /, m)) next;
        req=m[1]; st=m[2];
        gsub(secret, mask, req);
        res="FAIL"; why="HTTP " st;
        if      (st=="101")              { res="OK";   why="upgrade accepted — carrier established" }
        else if (st=="400")              { res="FAIL"; why="not a WebSocket upgrade (scanner, or plain http to the https port)" }
        else if (st=="404")              { res="FAIL"; why="wrong upgrade PATH — his --http-upgrade-path-prefix does not match ours" }
        else if (st=="408"||st=="499")   { res="FAIL"; why="client vanished mid-handshake — his ISP killed the connection" }
        else if (st=="502"||st=="504")   { res="FAIL"; why="wstunnel not answering on loopback — OUR unit, not his problem" }
        else if (st=="403")              { res="FAIL"; why="refused at the edge" }
        print ts "|EDGE|" res "|" ip "  " st "  " why "  [" req "]"
      }' > "$WORK/edge"

    # ── CARRIER: wstunnel's own view ────────────────────────────────────────
    journalctl --no-pager -o cat -u wstunnel-server --since "$SINCE" 2>/dev/null | noansi |
    awk -v secret="$SECRET" -v mask="$MASK" -v port="$PORT" '
      { ts=$1; rest=$0; sub(/^[^ ]*[[:space:]]+/, "", rest); gsub(secret, mask, rest);
        if ($0 ~ /Tunnel accepted due to matched restriction/) print ts "|CARRIER|OK|path authorised, UDP leg opened to 127.0.0.1:" port " — from here the WireGuard layer decides"
        else if ($0 ~ /ERROR/) print ts "|CARRIER|FAIL|" rest
        else if ($0 ~ /WARN/)  print ts "|CARRIER|WARN|" rest
        else if ($0 ~ /Accepting connection/) print ts "|CARRIER|INFO|connection from nginx (loopback proxy)"
        else if ($0 ~ /Closing local|Connection closed|Tunnel closed|dropp/) print ts "|CARRIER|INFO|carrier connection closed"
      }' > "$WORK/carrier"

    # ── WIREGUARD: live state — this is what "is he actually up" means ──────
    HS=""; EP=""; TR=""; PEER=""
    if raw=$(wg show "$WG" 2>/dev/null) && [ -n "$raw" ]; then
      HS=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*latest handshake:[[:space:]]*//p')
      EP=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*endpoint:[[:space:]]*//p')
      TR=$(printf '%s\n' "$raw" | sed -n 's/^[[:space:]]*transfer:[[:space:]]*//p')
      PEER=$(printf '%s\n' "$raw" | sed -n 's/^peer:[[:space:]]*//p')
    fi

    CARRIER_OK=$(cnt '|CARRIER|OK|' "$WORK/carrier")
    EDGE_OK=$(cnt '|EDGE|OK|' "$WORK/edge")
    EDGE_FAIL=$(cnt '|EDGE|FAIL|' "$WORK/edge")

    if [ -z "$HS" ] || [ "$HS" = never ] || printf '%s' "$HS" | grep -q '0 seconds ago'; then
      if [ "$CARRIER_OK" -gt 0 ]; then
        WGR=bad
        WGMSG="WireGuard has never handshaked, yet the WebSocket carrier connected $CARRIER_OK time(s). Those two facts together mean one thing: he IS reaching us and his key is not the one registered here. Ask him to run <code>wg pubkey &lt; /run/secrets/wg-friend.key</code> and send the result."
      else
        WGR=warn
        WGMSG="No WireGuard handshake and no carrier connection either — nobody has dialled in, or his ISP blocks TCP/443 egress, or DNS for $LOG does not resolve from his network."
      fi
    elif printf '%s' "$HS" | grep -qE 'hour|day|week'; then
      WGR=bad
      WGMSG="Last handshake was $HS — the tunnel has been down that whole time. His carrier died and the client has not re-established it. Have him run <code>systemctl restart wstunnel-client</code>; WireGuard re-handshakes on its own."
    else
      WGR=ok
      WGMSG="Up. Last handshake $HS. Peer $PEER; endpoint ${"EP:-none"} — loopback is correct, wstunnel is the carrier; transfer ${"TR:-none"}."
    fi

    UNITS=""
    for u in wstunnel-server nginx nftables; do
      UNITS="$UNITS <span class=kv>$u=$(systemctl is-active "$u" 2>&1)</span>"
    done
    LISTEN=$(ss -lnup 2>/dev/null | grep -c ":$PORT" || true)
    [ -n "$LISTEN" ] || LISTEN=0
    ROUTE=$(ip -6 route show match "$SUBNET" 2>/dev/null | head -1)

    sort -r "$WORK/edge" "$WORK/carrier" 2>/dev/null | head -300 > "$WORK/events"
    N=$(wc -l < "$WORK/events")

    # ── log.txt: the copy-pasteable version, for pasting into a conversation ─
    {
      echo "friend tunnel connection log — rendered $(date -Is)"
      printf 'wireguard: %s\n' "$WGMSG" | t
      printf 'last 3 days: %s edge attempts accepted, %s refused, %s carrier authorisations\n' \
        "$EDGE_OK" "$EDGE_FAIL" "$CARRIER_OK"
      printf 'udp listener on :%s: %s · route %s: %s\n' "$PORT" "$LISTEN" "$SUBNET" "''${ROUTE:-MISSING}"
      echo
      cut -d'|' -f1,2,3,4 "$WORK/events" | tr '|' ' '
    } > "$OUT/log.txt"

    # ── index.html ──────────────────────────────────────────────────────────
    {
      cat ${headHtml}
      printf ' · rendered %s</div>\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"

      printf '<div class="card %s"><b>WireGuard: %s</b><br>%s</div>\n' \
        "$WGR" "$( [ "$WGR" = ok ] && echo UP || echo 'NOT UP' )" "$WGMSG"

      printf '<div class=card><b>Edge (nginx — real client IPs)</b> %s accepted, %s refused · <b>Carrier (wstunnel)</b> %s authorisations</div>\n' \
        "$EDGE_OK" "$EDGE_FAIL" "$CARRIER_OK"

      printf '<div class=card>%s<br>udp listener :%s → %s · route %s → %s</div>\n' \
        "$UNITS" "$PORT" "$LISTEN" "$(h "$SUBNET")" "$(h "''${ROUTE:-MISSING, so wg-friend has no /64 address}")"

      printf '<p><a href=log.txt>plain-text version</a> · %s edge/carrier events shown, newest first</p>\n' "$N"
      echo '<table><tr><th>when</th><th>layer</th><th>result</th><th>detail</th></tr>'

      while IFS='|' read -r ts layer res text; do
        case "$res" in OK) cls=ok ;; FAIL) cls=bad ;; WARN) cls=warn ;; *) cls=info ;; esac
        printf '<tr class=%s><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
          "$cls" "$(h "''${ts%%+*}")" "$(h "$layer")" "$(h "$res")" "$(h "$text")"
      done < "$WORK/events"

      echo '</table><details><summary>raw events</summary><pre>'
      h "$(cat "$WORK/events")"
      echo '</pre></details></body></html>'
    } > "$OUT/index.html.new"

    chmod 0644 "$OUT/index.html.new" "$OUT/log.txt"
    mv "$OUT/index.html.new" "$OUT/index.html"
  '';
in
{
  systemd.services.friend-tunnel-log-render = {
    description = "Render the friend-tunnel connection-attempt log for the LAN status page";
    # NixOS gives units a minimal PATH and this script shells out constantly, so
    # every tool it uses must be named here. A missing one shows up as a
    # half-empty page, never as a unit failure.
    path = [
      pkgs.systemd
      pkgs.wireguard-tools
      pkgs.iproute2
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
    ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = render;
      # 0700 is systemd's default for StateDirectory, which would leave nginx
      # serving a 403 forever.
      StateDirectory = "friend-tunnel-log";
      StateDirectoryMode = "0755";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      Restart = "on-failure";
      RestartSec = 10;
    };
  };

  systemd.timers.friend-tunnel-log-render = {
    description = "Refresh the friend-tunnel connection log";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15s";
      OnUnitActiveSec = "20s";
      AccuracySec = "5s";
      Unit = "friend-tunnel-log-render.service";
    };
  };

  # The page. LAN-only because it lists which public IPs dial the tunnel.
  services.nginx.virtualHosts.${c.FRIEND_TUNNEL_LOG_HOST} = {
    useACMEHost = "chrisdell.info";
    forceSSL = true;
    root = stateDir;
    extraConfig = ''
      # LAN only, both families. v6 is not optional here: the wildcard record
      # gives this name an AAAA, so a browser on the LAN usually dials the
      # router's public IPv6 and presents its OWN :49:: address as the source —
      # allow 192.168.49.0/24 alone 403s a working LAN client (observed).
      # Temporary/privacy addresses are fine: they are inside the same /64.
      # The friend's :8472::/64 stays denied on purpose — it reaches the internet
      # through us, which is not the same thing as being on the LAN.
      allow ${c.LAN_SUBNET};
      allow ${c.LAN_IPV6_SUBNET};
      deny all;
    '';
    locations."/".extraConfig = ''
      # Stale content on a live-status page is worse than no content.
      add_header Cache-Control "no-store";
    '';
  };
}
