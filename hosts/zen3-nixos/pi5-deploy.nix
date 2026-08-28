# Deployment parameters for the Pi 5 netboot bundle.
#
# The gc-rust-node template deliberately contains NO deployment values (no
# IPs, no join codes): everything the Pi needs is passed in from here via
# inputs.gc-rust-node.lib.mkPi5Netboot (see pi5-netboot.nix). These options
# are the ONLY Pi-related values that live on this side.
#
# joinCode is single-use and the Pi is stateless (tmpfs root), so a fresh
# code is needed on every deploy — scripts/update-pi5-node.sh enrolls one and
# replaces the value below before rebuilding.
{ lib, ... }:
{
  options.services.pi5Netboot = {
    nfsServer = lib.mkOption {
      type = lib.types.str;
      description = "IP of this host, which the Pi's initrd mounts its Nix store from (NFSv4, :/nix-store).";
    };
    grpcAddr = lib.mkOption {
      type = lib.types.str;
      description = "gc-server gRPC address for the Pi's worker node (IP literal = plaintext, hostname = TLS).";
    };
    joinCode = lib.mkOption {
      type = lib.types.str;
      description = "Fresh single-use gc-node enrollment code for the next boot (replaced by scripts/update-pi5-node.sh on every deploy).";
    };
  };

  config.services.pi5Netboot = {
    nfsServer = "192.168.49.50";
    grpcAddr = "192.168.49.50:9002";
    joinCode = "ZZ9-3FD"; # update-pi5-node.sh replaces this per deploy
  };
}
