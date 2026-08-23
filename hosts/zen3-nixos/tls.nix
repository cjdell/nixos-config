{
  config,
  lib,
  pkgs,
  specialArgs,
  ...
}:

# SSL termination for the public *.ai.chrisdell.info hostname (DNS points the
# whole ai subzone at this box's IPv6). The cert is acquired AND renewed
# locally by the NixOS ACME module (DNS-01 via Route 53), so the router is
# not involved at runtime.
#
# One-time keys already copied over from the router (192.168.49.1) —
# re-run `setup-zen3-acme.sh` from the repo root if this box is rebuilt from
# scratch:
#   - Let's Encrypt lego account (me@chrisdell.info, prod):
#       /var/lib/acme/.lego/accounts/018b461aa17feb5bfd14/
#   - Route 53 AWS secret: sops-encrypted in secrets/zen3-ai.yaml
#     (decrypted with the shared age key at /var/lib/sops-nix/key.txt — the
#     same key grafton-router uses, recipient age1axfjvw2my…; back that key
#     up, without it this config cannot be built).
#
# Note: secrets/ is gitignored, but sops-nix copies the sops file into the
# store at evaluation time, so it MUST be tracked: secrets/zen3-ai.yaml was
# force-added (`git add -f`). Keep it tracked, or `nixos-rebuild` from the
# git flake will fail.

{
  imports = [
    ../../common/sops.nix
    # common/sops.nix sets sops.* options but does not import the module
    specialArgs.inputs.sops-nix.nixosModules.default
  ];

  sops = {
    secrets."aws_access_key_secret" = {
      # Own sops file so the pre-existing secrets/secrets.yaml (other
      # services' secrets, encrypted to the same key) stays untouched.
      sopsFile = ../../secrets/zen3-ai.yaml;
      owner = "root";
      mode = "0400";
    };

    # AWS creds for lego's route53 DNS-01 provider — same key pair the
    # grafton-router uses. The key ID is not secret and stays in the repo,
    # matching the router's http.nix.
    templates."route-53-creds.env" = {
      owner = "acme";
      mode = "0400";
      content = ''
        AWS_REGION="us-east-1"
        AWS_ACCESS_KEY_ID="AKIAW5QXYEAMOAWTXW4P"
        AWS_SECRET_ACCESS_KEY="${config.sops.placeholder.aws_access_key_secret}"
      '';
    };
  };

  security.acme = {
    acceptTerms = true;

    # Same Let's Encrypt account the router renews chrisdell.info with;
    # the account key was copied to /var/lib/acme/.lego/accounts/ so lego
    # reuses it instead of registering a new account.
    #
    # dnsProvider/dnsPropagationCheck are set PER-CERT below, not in
    # `defaults`: with them in defaults the generated lego script came out
    # with --http (no --dns flag) even though nix eval reported the option
    # as inherited. Per-cert options demonstrably make it into the script.

    # Stored in /var/lib/acme/ai.chrisdell.info/ (fullchain.pem + key.pem),
    # group-readable by nginx. Until the first ACME order succeeds the
    # acme-ai.chrisdell.info service puts a self-signed cert there so nginx
    # can start. Renewals run on acme-renew-ai.chrisdell.info.timer (lego
    # --dynamic, ~1/3 of lifetime) and the generated postrun reloads nginx
    # afterwards.
    certs."ai.chrisdell.info" = {
      email = "me@chrisdell.info";
      dnsProvider = "route53";
      dnsPropagationCheck = true;
      extraDomainNames = [ "*.ai.chrisdell.info" ];
      environmentFile = config.sops.templates."route-53-creds.env".path;
      group = config.services.nginx.group;
      # nginx normally injects this via enableACME, but the vhost below
      # consumes the cert files directly (DNS-01, no webroot), so set it
      # here to make the renew timer reload nginx after each renewal.
      reloadServices = [ "nginx.service" ];
    };
  };

  # Don't start nginx before the (self-signed until the first order) cert
  # files exist.
  systemd.services.nginx.after = [ "acme-ai.chrisdell.info.service" ];

  services.nginx.virtualHosts."ai.chrisdell.info" = {
    # One server block for the apex and every *.ai.chrisdell.info name.
    serverAliases = [ "*.ai.chrisdell.info" ];

    # HTTP -> HTTPS redirect for the same host names.
    forceSSL = true;

    # Point nginx at the locally-managed ACME cert instead of using
    # enableACME: with enableACME the nginx module injects
    # `webroot = /var/lib/acme/acme-challenge` into the cert entry (and adds
    # a `^~ /.well-known/acme-challenge/` location), which trips the ACME
    # assertion that exactly one of dnsProvider/webroot/listenHTTP/s3Bucket
    # is set. DNS-01 needs no webroot, so consume the cert files directly.
    # (security.acme.certs above creates/refreshes these on its own timer.)
    sslCertificate = "/var/lib/acme/ai.chrisdell.info/fullchain.pem";
    sslCertificateKey = "/var/lib/acme/ai.chrisdell.info/key.pem";

    # Serve exactly the same service set as the plain-IP vhost in
    # ai/nginx.nix (llama-swap `/`, `/mcp`, `/logs`, `/sd*`, `/recallium*`,
    # `/api`, `/recallium-mcp`) as the fallback for the apex and every
    # *.ai.chrisdell.info name NOT covered by an explicit subdomain vhost
    # (the explicit ones, e.g. llama./logs./recallium-mcp., live in
    # ai/nginx.nix and take precedence for their exact server names).
    # References that vhost's locations so there is one definition — if the
    # IP vhost is ever removed, update this reference.
    locations = config.services.nginx.virtualHosts."192.168.49.50".locations;
  };
}
