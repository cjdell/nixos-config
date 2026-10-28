{
  config,
  lib,
  pkgs,
  ...
}:

# fah-panel — the folding@home space-heater telemetry panel (crates/fah-panel),
# ONE app deployed on every heater: live GPU + CPU power/temp/clock graphs and
# the GPU power-cap slider, served on port 80 so each heater is just
# http://<heater>/ next to the FAH Web Control on :7396.
#
# The panel has one GPU backend per vendor; a host says which one it is:
#   gpu = "nvidia" + nvidiaSmi   asus-i7-6700 (GTX 1060 + GTX 970 via nvidia-smi;
#                                one card + one cap slider per GPU line)
#   gpu = "amd"                  zen1 (RX 5700 XT via amdgpu sysfs)
# Adding the next heater (haswellatx, ...) is another folding-heater.nix that
# imports this module and sets the two or three options below — never a copy
# of the service or the crate.
#
# The service runs as root: binding :80 needs it, RAPL energy_uj is 0400, and
# both power-cap controls (nvidia-smi -pl / hwmon power1_cap) want root too.
# The startup power cap is NOT this panel's job — a boot-time unit per host
# owns that (e.g. nvidia-power-limit.service); the slider only moves the live
# setting, exactly like the hardware state it reads.
{
  options.services.fah-panel = {
    enable = lib.mkEnableOption "folding@home heater telemetry web panel (crates/fah-panel)";

    listen = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0:80";
      description = "Address:port to serve the panel on (heater default: plain http on port 80).";
    };

    gpu = lib.mkOption {
      type = lib.types.enum [
        "auto"
        "nvidia"
        "amd"
      ];
      default = "auto";
      description = "GPU backend; auto = nvidia when nvidiaSmi is set, else amdgpu sysfs.";
    };

    nvidiaSmi = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression "\${config.hardware.nvidia.package.bin}/bin/nvidia-smi";
      description = "Absolute store path of nvidia-smi (required when gpu = nvidia).";
    };

    amdPci = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "1002:731f";
      description = ''
        PCI vendor:device id (or full BDF) of the folding GPU for the amd
        backend; empty auto-detects the first PCI device exporting an amdgpu
        hwmon. Prefer the id — BDFs shuffle between boots.
      '';
    };

    gpuName = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "Radeon RX 5700 XT";
      description = "Display name override (amdgpu sysfs exposes no product name).";
    };

    budget = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Flag the CPU+GPU DC-load estimate above this many watts (brownout
        margin) — only meaningful on PSU-crippled boxes like the old
        hp-z240 heater; 0 hides the budget marker.
      '';
    };

    cpuTempTarget = lib.mkOption {
      type = lib.types.ints.between 0 110;
      default = 0;
      example = 80;
      description = ''
        Startup CPU max-temperature target in °C (0 = off). The panel holds
        the package below it by moving every cpufreq `scaling_max_freq`
        ceiling; being ExecStart state this persists across panel restarts
        AND reboots. The panel's slider overrides the target live, per
        session — changing it here is what makes it permanent (same split
        as a boot-time power-limit unit vs the GPU cap slider on the old
        hp-z240).
      '';
    };
  };

  config =
    let
      cfg = config.services.fah-panel;
      package = pkgs.callPackage ../crates/fah-panel/nix/package.nix { };
      args = [
        "--listen"
        cfg.listen
        "--gpu"
        cfg.gpu
        "--dmidecode"
        "${pkgs.dmidecode}/bin/dmidecode"
      ]
      ++ lib.optionals (cfg.gpu == "nvidia") [
        "--nvidia-smi"
        (
          if cfg.nvidiaSmi == null then
            throw "services.fah-panel: nvidiaSmi must be set when gpu = \"nvidia\""
          else
            cfg.nvidiaSmi
        )
      ]
      ++ lib.optionals (cfg.gpu == "amd" && cfg.amdPci != "") [
        "--amd-pci"
        cfg.amdPci
      ]
      ++ lib.optionals (cfg.gpuName != "") [
        "--gpu-name"
        cfg.gpuName
      ]
      ++ lib.optionals (cfg.budget > 0) [
        "--budget"
        (toString cfg.budget)
      ]
      ++ lib.optionals (cfg.cpuTempTarget > 0) [
        "--cpu-target"
        (toString cfg.cpuTempTarget)
      ];
    in
    lib.mkIf cfg.enable {
      systemd.services.fah-panel = {
        description = "Folding heater telemetry panel (fah-panel)";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = "${package}/bin/fah-panel ${lib.escapeShellArgs args}";
          Restart = "always";
          RestartSec = 5;
        };
      };
    };
}
