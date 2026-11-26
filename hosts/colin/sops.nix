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
      htpasswd.content = "admin:${config.sops.placeholder.htpasswd}\n";
    };
  };
}
