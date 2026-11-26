# colin's secrets. Same age key as the rest of the fleet
# (/var/lib/sops-nix/key.txt); see .sops.yaml and hosts/colin/README.md.
{ config, ... }:

{
  sops = {
    age.keyFile = "/var/lib/sops-nix/key.txt";
    defaultSopsFile = ./secrets/secrets.yaml;

    secrets = {
      aws_access_key_secret = { };
      wireguard_key = { };
      tailscale_pre_auth_key = { };
      ap_passphrase = { };
      htpasswd = { };

      # Brave Search API key for the brave-search MCP server that
      # users/cjdell/opencode.nix spawns (BRAVE_API_KEY_FILE). colin is the one
      # host with its own sops file instead of common/sops.nix, so name the
      # fleet file explicitly — same key, same value, and this host's age key
      # decrypts it. 0440 root:wheel matches common/sops.nix: cjdell is in
      # wheel, so the MCP server can read it and nobody else can.
      brave_api_key = {
        sopsFile = ../../secrets/secrets.yaml;
        group = "wheel";
        mode = "0440";
      };
    };

    templates = {
      # Route53 credentials for ACME DNS-01 and r53-ddns. The access key ID is
      # the same IAM user the rest of the fleet uses; the secret comes from
      # sops. AWS_REGION/AWS_ACCESS_KEY_ID are not secrets (the ID is already
      # in hosts/grafton-router/http.nix).
      "route-53-creds.env".content = ''
        AWS_REGION=us-east-1
        AWS_ACCESS_KEY_ID=AKIAW5QXYEAMOAWTXW4P
        AWS_SECRET_ACCESS_KEY=${config.sops.placeholder.aws_access_key_secret}
      '';

      # nginx basic-auth file (home page + Frigate). The sops value is the
      # apr1 hash; the "admin:" prefix is added here.
      #
      # Group/mode are load-bearing: nginx workers run as the `nginx` user and
      # open this file per request. The sops-nix default (0400 root:root) is
      # unreadable to them, so any request that actually carries credentials
      # dies with `[crit] open() ... Permission denied` -> 500, while a
      # credential-less request still gets a 401. 0440 root:nginx is the
      # minimum that works.
      htpasswd = {
        content = "admin:${config.sops.placeholder.htpasswd}\n";
        group = config.services.nginx.group;
        mode = "0440";
        reloadUnits = [ "nginx.service" ];
      };
    };
  };
}
