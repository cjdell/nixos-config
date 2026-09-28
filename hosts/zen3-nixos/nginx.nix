{

  # The base nginx configuration for zen3-nixos.
  #
  # This used to live in ./netboot.nix, which was wrong: nginx fronts EVERY
  # service on this host (llama-swap's llama./llm. vhosts, the log viewer,
  # Recallium, sd-gate, the GPU panel, plus the ACME/TLS vhosts in
  # ./tls.nix), while netboot.nix is only about the Pi 5 images. Because
  # `services.nginx.enable` existed nowhere else, dropping ./netboot.nix from
  # ./default.nix silently took the whole HTTP surface down - no listener on
  # :80/:443, a nginx.service with no ExecStart ("bad-setting"), and every
  # client pointed at *.ai.chrisdell.info (e.g. opencode, which uses
  # https://llama.ai.chrisdell.info/upstream/r9700/v1) failing to connect.
  # Keep it here, next to the vhosts that depend on it.
  #
  # Nothing about the netboot images is required for nginx to run: the
  # `zen3-nixos.grafton.lan` image-serving vhost stays in ./netboot.nix and
  # simply isn't defined when that module is not imported.
  services.nginx = {
    enable = true;

    recommendedTlsSettings = true;
    recommendedOptimisation = true;
    recommendedGzipSettings = true;

    # nginx's compiled-in temp dirs point at /tmp/nginx_* — nothing important
    # may live in /tmp (it can vanish mid-run). When the client_body temp dir
    # is missing, nginx 500s every request whose body exceeds the in-memory
    # client_body_buffer_size (agent prompts run to hundreds of KB) with
    # `open() "/tmp/nginx_client_body/..." failed (2: No such file or directory)`.
    # Point all spill dirs at /var/cache/nginx (the unit's CacheDirectory,
    # persistent on disk) — pre-created for the nginx worker user below.
    appendHttpConfig = ''
      client_body_temp_path /var/cache/nginx/client_body_temp;
      proxy_temp_path /var/cache/nginx/proxy_temp;
      fastcgi_temp_path /var/cache/nginx/fastcgi_temp;
      uwsgi_temp_path /var/cache/nginx/uwsgi_temp;
      scgi_temp_path /var/cache/nginx/scgi_temp;
    '';
  };

  # nginx spill dirs (see appendHttpConfig above) — owned by the worker user
  # (workers run as nginx:nginx; /var/cache/nginx itself is 0750 nginx:nginx
  # and not group-writable, so these subdirs must exist ahead of the service).
  systemd.tmpfiles.rules = [
    "d /var/cache/nginx/client_body_temp 0700 nginx nginx -"
    "d /var/cache/nginx/proxy_temp 0700 nginx nginx -"
    "d /var/cache/nginx/fastcgi_temp 0700 nginx nginx -"
    "d /var/cache/nginx/uwsgi_temp 0700 nginx nginx -"
    "d /var/cache/nginx/scgi_temp 0700 nginx nginx -"
  ];
}
