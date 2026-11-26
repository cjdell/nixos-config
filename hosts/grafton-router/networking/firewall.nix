{
  lib,
  ...
}:

let
  c = import ./constants.nix;

  # `{ "lan", "vlan10" }` — quoted nftables set of interface names
  ifaceSet = names: "{ ${lib.concatMapStringsSep ", " (n: "\"${n}\"") names} }";

  # Everything we trust implicitly on input (no further rules needed)
  # Note: tailscale0 is deliberately NOT here — tailnet members get only the
  # explicit service rules in input-allow, not blanket trust.
  trustedIfaces = ifaceSet [
    "lo"
    c.LAN_INTERFACE
    c.VLAN10_INTERFACE
    c.PODMAN_INTERFACE
  ];

  # Internal bridges that may talk to each other (mDNS etc.)
  internalIfaces = ifaceSet [
    c.LAN_INTERFACE
    c.VLAN10_INTERFACE
    c.PODMAN_INTERFACE
  ];

  # LAN + VLAN10, i.e. everything except podman containers and the VPN
  homeIfaces = ifaceSet [
    c.LAN_INTERFACE
    c.VLAN10_INTERFACE
  ];
in
{
  networking.nftables.tables = {
    firewall = {
      family = "inet";
      content = ''
        # ============================================================================
        # FILTER TABLE (inet)
        # ============================================================================

        # ----------------------------------------------------------------------------
        # rpfilter — anti-spoofing
        # Checks a route exists back to the source through any output interface; if
        # not, the packet is dropped. The DHCPv4 exception exists because DHCP clients
        # broadcast from 0.0.0.0 before they have an IP — those fail the FIB check
        # but are legitimate.
        # ----------------------------------------------------------------------------
        chain rpfilter {
          type filter hook prerouting priority mangle + 10; policy drop;
          meta nfproto ipv4 udp sport . udp dport {
            ${toString c.DHCPV4_CLIENT_PORT} . ${toString c.DHCPV4_SERVER_PORT},
            ${toString c.DHCPV4_SERVER_PORT} . ${toString c.DHCPV4_CLIENT_PORT}
          } accept comment "DHCPv4 client/server"
          fib saddr . mark oif exists accept
        }

        # ----------------------------------------------------------------------------
        # input — traffic to the router itself
        # ----------------------------------------------------------------------------
        chain input {
          type filter hook input priority filter; policy drop;

          # Trust our own networks / interfaces entirely
          iifname ${trustedIfaces} accept comment "trusted interfaces"
          ip6 saddr ${c.DBTHR33_SUBNET} accept comment "DBTHR33 trusted network"
          ip6 saddr ${c.HACKSPACE_IPV6_SUBNET} accept comment "Hackspace IPv6 trusted network"
          ip saddr ${c.PODMAN_SUBNET} accept comment "NixOS containers"

          # Handle packets according to connection state
          ct state vmap {
            invalid     : drop,
            established : accept,
            related     : accept,
            new         : jump input-allow,
            untracked   : jump input-allow
          }

          # Reached here = blocked; log it (spots port scans / misconfigs)
          tcp flags syn / fin,syn,rst,ack log prefix "refused connection: " level info
        }

        chain input-allow {
          # --- SSH: private networks only -------------------------------------------
          ip saddr ${c.WIREGUARD_SUBNET} tcp dport ${toString c.SSH_PORT} accept comment "ssh from WireGuard VPN"
          ip saddr ${c.LAN_SUBNET}       tcp dport ${toString c.SSH_PORT} accept comment "ssh from LAN"
          ip saddr ${c.TAILSCALE_SUBNET} tcp dport ${toString c.SSH_PORT} accept comment "ssh from Tailscale"

          # --- Tailscale: explicit services only (no blanket trust) -----------------
          # headscale's MagicDNS split sends grafton.lan queries to the router
          ip saddr ${c.TAILSCALE_SUBNET} udp dport ${toString c.DNS_PORT} accept comment "DNS from Tailscale (MagicDNS split)"
          ip saddr ${c.TAILSCALE_SUBNET} tcp dport ${toString c.DNS_PORT} accept comment "DNS from Tailscale (MagicDNS split)"
          ip saddr ${c.TAILSCALE_SUBNET} tcp dport ${toString c.HOME_ASSISTANT_PORT} accept comment "Home Assistant from Tailscale"

          # --- Public services --------------------------------------------------------
          tcp dport ${toString c.HTTP_PORT}       accept comment "HTTP from anywhere"
          tcp dport ${toString c.HTTPS_PORT}      accept comment "HTTPS from anywhere"
          udp dport ${toString c.STUN_PORT}       accept comment "STUN (headscale DERP)"
          udp dport ${toString c.TAILSCALE_PORT}  accept comment "Tailscale from anywhere"

          # --- ICMP -------------------------------------------------------------------
          icmp type echo-request limit rate 10/second accept comment "allow ping (rate limited)"
          icmpv6 type != { nd-redirect, 139 } accept comment "Accept all ICMPv6 except redirects and node info queries (type 139). See RFC 4890, section 4.4."

          # --- Friend tunnel experiment ------------------------------------------------
          # AdGuard serves RDNSS :49::1 to the friend's LAN devices; their queries
          # arrive decapsulated from wg-friend, destined for us (INPUT, not FORWARD).
          iifname wg-friend ip6 saddr ${c.FRIEND_V6_SUBNET} udp dport ${toString c.DNS_PORT} accept comment "friend DNS (tunnel experiment)"

          # --- DHCPv6 — router is a DHCPv6 *client* on the WAN ------------------------
          # Prefix delegation from the ISP (see pppoe.nix) arrives on UDP 546 (client
          # port), sourced from the server port 547.
          ip6 daddr fe80::/64 udp dport ${toString c.DHCPV6_CLIENT_PORT} accept comment "DHCPv6-PD from ISP (link-local)"
          udp dport ${toString c.DHCPV6_CLIENT_PORT} udp sport ${toString c.DHCPV6_SERVER_PORT} counter accept comment "DHCPv6-PD from ISP (any daddr)"
        }

        # ----------------------------------------------------------------------------
        # forward — traffic routed through the router
        # ----------------------------------------------------------------------------
        chain forward {
          type filter hook forward priority 0; policy drop;

          # Anti-spoofing / broken-packet hygiene
          tcp flags & (fin|syn|rst|psh|ack|urg) == 0 drop comment "drop null packets"
          tcp flags & (fin|syn) == fin|syn drop comment "drop fin+syn"
          tcp flags & (syn|rst) == syn|rst drop comment "drop syn+rst"

          # mDNS between internal networks
          iifname ${internalIfaces} udp dport ${toString c.MDNS_PORT} accept comment "mdns from trusted networks"

          # MSS clamping (avoids MTU issues over PPPoE).
          # Must clamp BOTH directions: matching only bare SYN (excluding
          # SYN-ACK) leaves the LAN client unaware of the smaller path MTU,
          # so client segments > PPPoE MTU get IP-fragmented on egress and
          # are dropped upstream (breaks Chrome's split post-quantum
          # ClientHello, showing up as ERR_CONNECTION_RESET).
          tcp flags syn / fin,syn,rst,ack tcp option maxseg size set 1400 comment "Clamp TCP MSS to avoid MTU issues"
          tcp flags syn,ack tcp option maxseg size set 1400 comment "Clamp TCP MSS (SYN-ACK)"
          tcp flags syn / fin,syn,rst,ack ip6 daddr != fe80::/10 tcp option maxseg size set 1400 comment "Clamp TCP MSS for IPv6"
          tcp flags syn,ack ip6 daddr != fe80::/10 tcp option maxseg size set 1400 comment "Clamp TCP MSS IPv6 (SYN-ACK)"

          # tailscale0's MTU is 1280, so 1400 is still too big for anything
          # crossing the tunnel: the handshake must advertise 1240 (1280-40)
          # or every connection discovers that the hard way with a DF drop +
          # "frag needed" round-trip per PMTU probe — SMB browsing stalls.
          oifname ${c.TAILSCALE_INTERFACE} tcp flags syn / fin,syn,rst,ack tcp option maxseg size set 1240 comment "Clamp MSS to tailscale tunnel MTU (out)"
          iifname ${c.TAILSCALE_INTERFACE} tcp flags syn,ack tcp option maxseg size set 1240 comment "Clamp MSS to tailscale tunnel MTU (in)"

          # No internet egress to RFC1918 addresses
          oifname ${c.WAN_INTERFACE} ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } reject with icmp type net-unreachable comment "outbound rfc1918 not permitted"

          # Connection tracking dispatch
          ct state vmap {
            invalid     : drop,
            established : accept,
            related     : accept,
            new         : jump forward-allow,
            untracked   : jump forward-allow
          }

          # Connection rate limiting
          ct state new limit rate over 50/second burst 100 packets drop comment "rate limit new connections"

          # Reached here = blocked; log it
          tcp flags syn / fin,syn,rst,ack log prefix "refused forward: " level info
        }

        chain forward-allow {
          # Only NEW connections reach here — define initiation rules only.

          # Tailscale exit node — tailnet clients route to the internet via us.
          # Deliberately narrow: does NOT give tailnet access to podman containers.
          iifname ${c.TAILSCALE_INTERFACE} oifname ${c.WAN_INTERFACE} accept comment "Tailscale exit node (internet)"

          ip saddr ${c.PODMAN_SUBNET} accept comment "NixOS containers"

          # LAN can initiate to VLAN10
          iifname ${c.LAN_INTERFACE} oifname ${c.VLAN10_INTERFACE} accept comment "LAN to VLAN10"

          # Thread mesh (services/otbr.nix): wpan0 is the Thread interface the
          # OTBR container runs on the host network namespace. Only NEW flows
          # reach here — established/related already passed the forward chain's
          # ct vmap. What is deliberately NOT done here: filtering unicast INTO
          # the mesh. otbr-agent inserts its own OT_FORWARD_INGRESS chain for
          # that (a later nft hook priority, matching against on-mesh prefixes
          # it owns and we cannot know statically), so this pair is just the
          # "internal network" authorization for both directions — without it
          # the policy drop here silently black-holes the mesh in both
          # directions while the border router looks perfectly healthy.
          iifname ${c.LAN_INTERFACE} oifname wpan0 accept comment "LAN to Thread mesh"
          iifname wpan0 oifname ${c.LAN_INTERFACE} accept comment "Thread mesh to LAN"

          # Internal networks outbound to internet
          iifname ${c.LAN_INTERFACE}    oifname ${c.WAN_INTERFACE} accept comment "LAN out via ISP"
          iifname ${c.VLAN10_INTERFACE} oifname ${c.WAN_INTERFACE} accept comment "VLAN10 out via ISP"
          iifname ${c.PODMAN_INTERFACE} oifname ${c.WAN_INTERFACE} accept comment "podman to internet"

          # Internal <-> podman
          iifname ${c.LAN_INTERFACE}    oifname ${c.PODMAN_INTERFACE} accept comment "LAN to podman"
          iifname ${c.VLAN10_INTERFACE} oifname ${c.PODMAN_INTERFACE} accept comment "VLAN10 to podman"
          iifname ${c.PODMAN_INTERFACE} oifname ${c.LAN_INTERFACE}    accept comment "podman to LAN"
          iifname ${c.PODMAN_INTERFACE} oifname ${c.VLAN10_INTERFACE} accept comment "podman to VLAN10"

          # Hackspace (10.3.0.0/16) — routed out the LAN to the hackspace-client VM.
          # Allow LAN clients to initiate (masqueraded in the nat table so replies
          # return via us). Ping already passed via the ICMP rule below; this
          # enables TCP/UDP (e.g. SSH) which otherwise fell through to the drop.
          iifname ${c.LAN_INTERFACE} ip daddr ${c.HACKSPACE_SUBNET} accept comment "LAN to Hackspace"

          # IPv6 counterparts, added 2026-11-19 — the "LAN to Hackspace" rule above
          # is `ip daddr`, so it never matched a single AAAA. The networkd routes
          # in networking/interface.nix steer both hackspace /48s into the VM;
          # these are their filter counterparts. Deliberately NO v6 masquerade
          # counterpart: the whole point of the IPv6 path is to arrive with a
          # source the hackspace ACL trusts *permanently*, and that source is the
          # VM's tailnet address — which only the VM can originate, so its single
          # masquerade rule lives in
          # virtual-machines/grafton-hackspace-client.nix. Masquerading here
          # instead would rewrite to this router's lan address — i.e. back onto
          # the rotation schedule of a delegated prefix we do not own, the
          # fragility that produced the 794 403s of 2026-11-19
          # (docs/leighhack-tailscale.md).
          iifname ${c.LAN_INTERFACE} ip6 daddr ${c.HACKSPACE_IPV6_SUBNET} accept comment "LAN to Hackspace (IPv6)"
          iifname ${c.LAN_INTERFACE} ip6 daddr ${c.HACKSPACE_ULA_SUBNET} accept comment "LAN to Hackspace (ULA)"

          # gatling-services' tailnet subnet (10.0.1.0/24) — an approved subnet
          # route accepted on tailscale0 via --accept-routes. The generic "LAN to
          # VPN" rule below already forwards this; it is stated explicitly so
          # the masquerade rule in the nat table has its filter counterpart.
          iifname ${c.LAN_INTERFACE} ip daddr ${c.GATLING_SUBNET} accept comment "LAN to gatling-services subnet"

          # --- Friend tunnel: keep him OUT of the house -------------------------------
          # Must come BEFORE the delegated-prefix rule below, which would
          # otherwise hand a third party on wg-friend the same trust as every
          # internal interface: his source address is inside our /48, so without
          # this he reaches any globally-addressed box in the house — verified
          # from the demo VM: HTTP 301 from :49::1 and HTTP 200 from zen3
          # (:49::50). His own internet egress is untouched (established/related
          # passed in the forward chain), his DNS is INPUT with its own rule, and
          # inbound connections to his /64 arrive on the WAN decapsulated, never
          # on wg-friend — so this only closes the walk-in.
          iifname wg-friend ip6 daddr ${c.DELEGATED_PREFIX} reject with icmpx type admin-prohibited comment "friend /64 may not reach our /48"

          # IPv6 — delegated prefix + trusted network
          ip6 saddr ${c.DELEGATED_PREFIX} accept comment "outbound from delegated IPv6 prefix"
          ip6 saddr ${c.DBTHR33_SUBNET}   accept comment "DBTHR33 trusted network"
          ip6 saddr ${c.HACKSPACE_IPV6_SUBNET} accept comment "Hackspace IPv6 trusted network"

          # --- Friend tunnel experiment (services/friend-tunnel.nix) -------------------
          # Inbound to the shared /64: from the internet (pppoe) and hairpin-ish
          # from the LAN (so we can demo it from home boxes).
          iifname ${c.WAN_INTERFACE} ip6 daddr ${c.FRIEND_V6_SUBNET} accept comment "friend /64 inbound from internet"
          iifname ${c.LAN_INTERFACE} ip6 daddr ${c.FRIEND_V6_SUBNET} accept comment "friend /64 from LAN (demo path)"

          # Management: LAN may reach the VM's strict-side address (SSH).
          iifname ${c.LAN_INTERFACE} ip daddr ${c.STRICT_SUBNET} accept comment "LAN to strict-sim (VM management)"

          # The strict-ISP simulation itself: the VM may transit ONLY TCP/443
          # (its wss dial terminates on us = INPUT, exempt by design, same as
          # any browser reaching a web server through the ISP). Everything else
          # from that bridge is refused, explicitly, so the demo has a
          # reject-with-message instead of a silent policy drop.
          iifname ${c.STRICT_INTERFACE} tcp dport ${toString c.HTTPS_PORT} accept comment "strict sim: TCP/443 transit only"
          iifname ${c.STRICT_INTERFACE} reject with icmpx type admin-prohibited comment "strict sim: everything else denied"

          # ICMP
          icmp type echo-request accept comment "allow ping"
          icmpv6 type != { nd-redirect, 139 } accept comment "Accept ICMPv6 except redirects and queries"

          # VPN <-> home
          iifname ${c.TAILSCALE_INTERFACE} oifname ${homeIfaces} accept comment "VPN to LAN"
          iifname ${homeIfaces} oifname ${c.TAILSCALE_INTERFACE} accept comment "LAN to VPN"
        }

        chain output {
          type filter hook output priority 0; policy accept;
        }

        # ----------------------------------------------------------------------------
        # policy-routing marks — hackspace-session symmetry (added 2026-11-19)
        # (2026-11-23: the destination route 2001:8b0:1d14::/48 -> VM is GONE
        # from main — see networking/interface.nix — so the original hazard
        # below, replies following a VM route into the tailnet, no longer
        # exists for it. The chain stays anyway: it is still the guarantee
        # that hackspace-SOURCED sessions keep replies on the leg they
        # arrived on even if anything ever re-adds a route into that /48,
        # and their gateway 225::1 keeps SOURCING monitoring at us from the
        # prefix.)
        # The v6 route keyed on DESTINATION, but the hackspace also SOURCES
        # from that same /48 — their gateway 2001:8b0:1d14:225::1 pings/
        # monitors us from it, over the
        # internet (their tailnet has no v6 path into the house, so v6 sessions
        # from them can ONLY arrive on the WAN). A destination lookup on our
        # REPLY to one of those fresh requests hits the VM route anyway, and
        # the answer vanishes into the tailnet — the bug that ate every
        # hackspace->house v6 ping the same evening as the AAAA work (tcpdump
        # proved their pings reach the WAN and never get answered). So stamp
        # internet-arrived hackspace sessions on conntrack, re-apply the stamp
        # as fwmark on replies, and an ip-rule on 100-lan (interface.nix)
        # sends marked traffic to table 100 — a WAN-only default (pppoe.nix) —
        # despite main's /48 route:
        #   * hackspace-sourced session (arrives on the WAN): conntrack mark;
        #     replies -> fwmark 0x202a -> table 100 -> out via Zen, like the
        #     request. Each session is symmetric end to end, which matters
        #     because their return path is a stateful firewall entitled to
        #     discard answers seen on a different interface than the question.
        #   * everything else is deliberately NOT stamped: fd99 ULA is
        #     unreachable across the internet so its replies always belong on
        #     the tailnet, and our own tailnet members' outbound-to-hackspace
        #     sessions (iif tailscale0, SNATed by hackspace-v6-nat below) must
        #     reply via the VM exactly like their request. NB since 2026-11-23
        #     member traffic to the PUBLIC /48 no longer reaches the VM (main
        #     routes it out the WAN), so that pairing is now about the ULA;
        #     if member-v6-to-the-door is ever wanted back, scope a route to
        #     iif tailscale0 per the note in networking/interface.nix.
        # `ct direction original` matters: WITHOUT it, reply-direction packets
        # of an OUTBOUND-to-door session also carry ip6 saddr hackspace and
        # would get stamped — and their way-back packets would then be fwmarked
        # and rerouted by table 100 to the WAN. The second (output-hook) chain
        # covers sessions terminating on the router itself: OUTPUT never sees
        # prerouting, but the reply still needs the stamp.
        # ----------------------------------------------------------------------------
        chain mark-hackspace-replies {
          type filter hook prerouting priority mangle; policy accept;
          iifname ${c.WAN_INTERFACE} ip6 saddr ${c.HACKSPACE_IPV6_SUBNET} ct direction original ct mark set 0x202a comment "hackspace session arrived via the internet: remember it on the conntrack entry"
          ct mark 0x202a ct direction reply meta mark set 0x202a comment "its replies follow the request out the WAN, not the VM route"
        }

        chain mark-hackspace-replies-output {
          type filter hook output priority mangle; policy accept;
          ct mark 0x202a ct direction reply meta mark set 0x202a comment "same, for sessions terminating on the router (OUTPUT skips prerouting)"
        }
      '';
    };

    nat = {
      family = "ip";
      content = ''
        chain pre {
          type nat hook prerouting priority dstnat; policy accept;
          # we'll add rules for our 1:1 NAT here later
          # tcp dport 65022 dnat to 192.168.49.1:22 comment "Forward SSH from ext port 65022 to 192.168.49.1:22"
        }

        chain post {
          type nat hook postrouting priority srcnat; policy accept;

          # Internal networks out via the ISP
          iifname ${c.LAN_INTERFACE}    oifname ${c.WAN_INTERFACE} masquerade comment "LAN NAT to FTTP"
          iifname ${c.VLAN10_INTERFACE} oifname ${c.WAN_INTERFACE} masquerade comment "VLAN10 NAT to FTTP"
          iifname ${c.PODMAN_INTERFACE} oifname ${c.WAN_INTERFACE} masquerade comment "Podman to FTTP"

          # Tailscale out
          iifname ${c.TAILSCALE_INTERFACE} oifname ${c.WAN_INTERFACE} masquerade comment "Tailscale to FTTP"
          iifname ${c.TAILSCALE_INTERFACE} oifname ${c.LAN_INTERFACE} masquerade comment "Tailscale to LAN"

          # Strict-ISP simulation: the friend VM is behind double NAT, v4 only
          # (and the one allowed transit is TCP/443 in forward-allow).
          iifname ${c.STRICT_INTERFACE} oifname ${c.WAN_INTERFACE} masquerade comment "strict sim: CGNAT the friend VM"

          # LAN traffic to remote tailnets (Grafton + Hackspace) — masquerade so
          # replies come back via us instead of the remote network's routes
          iifname ${c.LAN_INTERFACE}          ip daddr ${c.TAILSCALE_SUBNET} masquerade comment "NAT for Grafton Tailnet traffic"
          iifname ${c.LAN_INTERFACE}          ip daddr ${c.HACKSPACE_SUBNET} masquerade comment "NAT for Hackspace Tailnet traffic"
          iifname ${c.LAN_INTERFACE}          ip daddr ${c.GATLING_SUBNET} masquerade comment "NAT for gatling-services subnet (10.0.1.0/24) traffic"
          iifname ${c.TAILSCALE_INTERFACE}    ip daddr ${c.HACKSPACE_SUBNET} masquerade comment "NAT for Hackspace Tailnet traffic"
        }

        chain out {
          type nat hook output priority mangle; policy accept;
          # we'll add v6 rules for our 1:1 NAT here later
        }
      '';
    };

    # v6 counterpart of line "NAT for Hackspace Tailnet traffic" above — that
    # table is family "ip", so ip6 needs its own. Why MASQUERADE and not
    # source-preserve like LAN-originated traffic: grafton-tailnet sources
    # (fd7a:115c:a1e0::/48, and 100.64.0.0/10 v4) are the *same ranges*
    # leighhack's own tailnet uses — every tailscale network defaults to them —
    # so the VM can never route a de-NAT'd reply back to, say, fd7a::6: its
    # table 52 claims the whole /48 for tailscale0 and the packet dies on
    # their tailnet (measured 2026-11-19: `ping -6 -I fd7a:…::b` through the
    # old path hung at 100 % loss while the LAN-sourced ping was 0 %).
    # Masquerading to the LAN address happens BEFORE the VM sees the packet,
    # the VM's nat6 then SNATs again to fd7a:115c:a1e0::13, and the hackspace
    # sees exactly the one node its ACLs admit. v4 didn't need this because
    # their headscale-approved 192.168.49.0/24 subnet route makes the
    # masqueraded source routable back on their side.
    # Added for the 2026-11-19 headscale advertisement of the hackspace /48s
    # (services/tailscale.nix) so `ping6 gw.int…` works from tailnet members.
    hackspace-v6-nat = {
      family = "inet";
      content = ''
        chain postrouting {
          type nat hook postrouting priority srcnat; policy accept;
          # saddr match, not iifname "tailscale0": the constraint that
          # matters is "came from our tailnet's range", and keying on the
          # address makes the rule testable from the router itself
          # (`ping -6 -I <our tailnet addr>`) and independent of which
          # interface delivered it. No legitimate LAN/VM source ever owns
          # fd7a:115c:a1e0::/48 — see the constant's comment.
          oifname ${c.LAN_INTERFACE} ip6 saddr ${c.TAILNET_V6_SUBNET} ip6 daddr { ${c.HACKSPACE_IPV6_SUBNET}, ${c.HACKSPACE_ULA_SUBNET} } masquerade comment "our tailnet -> hackspace v6: SNAT to the LAN address before the VM sees it"
        }
      '';
    };
  };
}
