{ config, lib, pkgs, modulesPath, ... }:

let
  constants = import ./constants.nix;
  route53Creds = config.sops.templates."route-53-creds.env".path;
  r53DDNS = import ./utils/r53-ddns.nix { inherit pkgs route53Creds; };
in
{
  imports = [
    (r53DDNS { hostname = "server"; domain = "${constants.BASE_DOMAIN}"; zone = "Z09459613U5DJIXXHIEVL"; })
  ];

  # Use DNS based challenge to acquire SSL certificates. Works even if NGINX is down.
  security.acme = {
    acceptTerms = true;

    defaults = {
      dnsProvider = "route53";
      dnsPropagationCheck = true;
      email = "me@chrisdell.info"; # Your email for Let's Encrypt notifications
      # server = "https://acme-staging-v02.api.letsencrypt.org/directory";
    };

    # Certs stored in /var/lib/acme
    certs = {
      "${constants.BASE_DOMAIN}" = {
        environmentFile = route53Creds;
        group = config.services.nginx.group; # Ensure nginx can access the certificates
        extraDomainNames = [
          "*.${constants.BASE_DOMAIN}"
          "*.www.${constants.BASE_DOMAIN}"
        ];
      };
    };
  };

  # NGINX is configured to use pre-existing certicates acquired by the ACME client
  services.nginx = {
    enable = true;

    commonHttpConfig = ''
      geo $internal {
        default         0;
        192.168.0.0/16  1;
        10.0.0.0/8      1;
        # 51.148.168.145  1;
        217.155.0.0/16  1;
      }
    '';

    virtualHosts = {
      # 404
      "_" = {
        useACMEHost = "${constants.BASE_DOMAIN}";
        forceSSL = true;
        locations."/" = {
          return = "404";
        };
      };

      # Home page
      "${constants.BASE_DOMAIN}" = {
        serverAliases = [ "www.${constants.BASE_DOMAIN}" ];
        useACMEHost = "${constants.BASE_DOMAIN}";
        forceSSL = true;

        extraConfig = ''
          auth_basic_user_file ${config.sops.templates."htpasswd".path};

          if ($internal = 0) {
            # rewrite ^ /go-away;
            set $auth_basic Restricted;
          }
          if ($internal = 1) {
            set $auth_basic off;
          }

          auth_basic $auth_basic;
        '';

        locations."/" = {
          root = "${./home-page}";
        };

        # locations."/go-away" = {
        #   return = "200 'Go Away!'";
        #   extraConfig = ''
        #     add_header Content-Type text/plain;
        #   '';
        # };
      };

      "hello.${constants.BASE_DOMAIN}" = {
        serverAliases = [ "hello.www.${constants.BASE_DOMAIN}" ];
        useACMEHost = "${constants.BASE_DOMAIN}";
        forceSSL = true;

        locations."/" = {
          return = "200 'Hello'";
          extraConfig = ''
            add_header Content-Type text/plain;
          '';
        };
      };
    };
  };
}

