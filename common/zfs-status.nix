{ config, lib, pkgs, ... }:

let
  cfg = config.services.zfsStatus;

  # Extremely minimal self-contained Python server: on every request it
  # re-collects `zpool status` + drive serials and returns a small HTML page.
  # Runs as root so it can read zpool/lsblk on any NAS host.
  #
  # NOTE: everything inside the indented string must share one base indentation
  # (4 spaces here) so Nix strips it down to valid Python. Keep the whole block
  # indented uniformly.
  server = pkgs.writeText "zfs-status.py" ''
    import http.server, subprocess, html, socket

    def sh(cmd):
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=15).stdout
        except Exception:
            return ""

    def serial_of(vdev):
        """Map a vdev name (by-id or /dev/sdX) to its base disk serial/model/size."""
        name = vdev.split('/')[-1]
        base = name
        # by-id devices (wwn-/scsi-/ata-/nvme-/usb-/nqn-) -> resolve symlink
        for prefix in ('wwn-', 'scsi-', 'ata-', 'nvme-', 'usb-', 'nqn-'):
            if base.startswith(prefix):
                rp = sh(['readlink', '-f', '/dev/disk/by-id/' + base]).strip()
                base = rp.split('/')[-1] if rp else base
                break
        # if it's a partition (e.g. sda1) resolve to its parent disk
        parent = sh(['lsblk', '-no', 'pkname', '/dev/' + base]).strip()
        if parent:
            base = parent
        disk = '/dev/' + base
        serial = sh(['lsblk', '-dno', 'serial', disk]).strip()
        model  = sh(['lsblk', '-dno', 'model',  disk]).strip()
        size   = sh(['lsblk', '-bdno', 'size',  disk]).strip()
        try:
            size = subprocess.run(['numfmt', '--to=iec', '--suffix=B', size],
                                  capture_output=True, text=True,
                                  timeout=5).stdout.strip()
        except Exception:
            pass
        return html.escape(serial or 'n/a'), html.escape(model or '''), size

    def st_class(state):
        s = state.upper()
        if s == 'ONLINE':
            return 'ok'
        if s in ('DEGRADED', 'REPLACING', 'SUSPENDED'):
            return 'warn'
        if s in ('FAULTED', 'UNAVAIL', 'OFFLINE', 'REMOVED'):
            return 'bad'
        return '''

    def page():
        status = sh(['zpool', 'status'])
        rows = []
        cur_pool, scan = None, '''
        in_config = False
        for line in status.splitlines():
            if line.startswith('  pool:'):
                cur_pool = line.split(':', 1)[1].strip()
            elif line.startswith('  scan:') and cur_pool:
                scan = line.split(':', 1)[1].strip()
            elif line.strip().startswith('NAME') and 'STATE' in line and 'CKSUM' in line:
                in_config = True
                continue
            elif in_config and cur_pool:
                if not line.strip():
                    in_config = False
                    continue
                f = line.split()
                if len(f) < 2:
                    continue
                name, state = f[0], f[1]
                # skip container rows; only map real leaf devices
                if name == cur_pool or name.startswith('mirror') or \
                   name.startswith('raidz') or name.startswith('spare') or \
                   name.startswith('replacing') or name.startswith('log') or \
                   name in ('special', 'cache'):
                    continue
                ser, mod, size = serial_of(name)
                # for legacy UNAVAIL vdevs the serial appears in the trailing
                # "was /dev/disk/by-id/<id>" comment
                if ser == 'n/a' and 'was /dev/disk/by-id/' in line:
                    old = line.split('was /dev/disk/by-id/', 1)[1].split()[0]
                    s, m, z = serial_of(old)
                    if s != 'n/a':
                        ser, mod, size = s, m, z
                rows.append((cur_pool, name, state, ser, mod, size))
        body = ['<table>',
                '<tr class="hdr"><td>pool</td><td>vdev</td><td>state</td>'
                '<td>serial</td><td>model</td><td>size</td></tr>']
        for p, name, state, ser, mod, size in rows:
            body.append(
                f'<tr><td>{html.escape(p)}</td>'
                f'<td>{html.escape(name)}</td>'
                f'<td class="st {st_class(state)}">{html.escape(state)}</td>'
                f'<td>{ser}</td><td>{mod}</td><td>{size}</td></tr>')
        body.append('</table>')
        if scan:
            body.append(f'<p class="scan">scan: {html.escape(scan)}</p>')
        status_h = html.escape(status)
        return f"""<!doctype html><html><head><meta charset="utf-8">
    <meta http-equiv="refresh" content="30">
    <title>ZFS status &mdash; {socket.gethostname()}</title>
    <style>
     body{{font-family:ui-monospace,Menlo,monospace;background:#111;color:#eee;margin:2rem}}
     h1{{font-size:1.1rem}} pre{{white-space:pre-wrap}}
     table{{border-collapse:collapse;margin-bottom:1rem}}
     td,th{{border:1px solid #333;padding:.3rem .6rem;text-align:left}}
     tr.hdr td{{background:#222;font-weight:bold}}
     .ok{{color:#4caf50;font-weight:bold}}
     .warn{{color:#ff9800;font-weight:bold}}
     .bad{{color:#f44336;font-weight:bold}}
     .scan{{color:#aaa}}
    </style></head><body>
    <h1>ZFS status &mdash; {socket.gethostname()}</h1>
    {'''.join(body)}
    <pre>{status_h}</pre>
    </body></html>"""

    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            body = page().encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *a): pass

    if __name__ == '__main__':
        http.server.HTTPServer(('0.0.0.0', ${toString cfg.port}),
                               H).serve_forever()
  '';
in
{
  options.services.zfsStatus = {
    enable = lib.mkEnableOption "minimal ZFS health web status page";
    port = lib.mkOption {
      type = lib.types.port;
      default = 8087;
      description = "TCP port the status page listens on.";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.zfs-status = {
      description = "Minimal ZFS health web status page";
      after = [ "zfs.target" "network.target" ];
      wants = [ "zfs.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${server}";
        Restart = "on-failure";
        User = "root";
      };
    };
    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
