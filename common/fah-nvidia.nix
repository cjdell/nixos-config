{
  config,
  lib,
  pkgs,
  ...
}:

# NVIDIA folding wiring — the shared half of every NVIDIA heater's
# folding-heater.nix. Swaps the module's ROCm OpenCL ICD (useless here —
# no AMD GPU) for the NVIDIA driver's, and gives the FAH core the driver's
# own libraries:
#   * FAH v8 detects cards through OpenCL and runs the work units on the
#     OpenMM core's CUDA platform; the 580-branch ICD provides fp64 +
#     cl_khr_pci_bus_info, so the client flips its gpus.json entry to
#     supported and fah-provision enables the slot.
#   * libcuda.so.1 + libnvidia-ml.so.1 go on LD_LIBRARY_PATH from the same
#     package dir: OpenMM prefers its CUDA plugin, and NVML is how the
#     client reads utilisation for Web Control.
#   * The fah user's HOME is /var/empty (isSystemUser), and the NVIDIA
#     userspace keeps its JIT'd compute-kernel cache under $HOME/.nv —
#     point HOME into the CacheDirectory so kernels are not recompiled on
#     every service restart.
#
# Hosts that need a conditional ICD (e.g. hp-z240, where GPU folding is
# off and the ICD must be hidden) override systemd.services.fah-client.environment
# themselves — see that host's folding-heater.nix.
{
  systemd.services.fah-client.environment = lib.mkIf config.services.folding-at-home-native.enable {
    OCL_ICD_VENDORS = lib.mkForce "${config.hardware.nvidia.package}/etc/OpenCL/vendors";
    LD_LIBRARY_PATH = lib.mkForce (
      lib.makeLibraryPath [
        pkgs.ocl-icd
        pkgs.expat
        pkgs.zlib
        config.hardware.nvidia.package
      ]
    );
    HOME = "/var/cache/fah-client";
  };

  systemd.services.fah-client.serviceConfig.CacheDirectory = "fah-client";
}
