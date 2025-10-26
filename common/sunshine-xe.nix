{ config, pkgs, ... }:
{
  systemd.user.services.sunshine.serviceConfig.Environment =
    "LD_LIBRARY_PATH=${pkgs.vpl-gpu-rt}/lib64:${pkgs.vaapiIntel}/lib64:${pkgs.intel-media-driver}/lib64";
}
