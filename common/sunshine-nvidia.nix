{ config, lib, pkgs, ... }:

{
  # Enable nvenc support
  services.sunshine.package =
    (pkgs.sunshine.override {
      cudaSupport = true;
      cudaPackages = pkgs.cudaPackages;
    }).overrideAttrs
      (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [
          pkgs.cudaPackages.cuda_nvcc
          (lib.getDev pkgs.cudaPackages.cuda_cudart)
        ];
        cmakeFlags = old.cmakeFlags ++ [
          "-DCMAKE_CUDA_COMPILER=${(lib.getExe pkgs.cudaPackages.cuda_nvcc)}"
        ];
      });

  systemd.user.services.sunshine.serviceConfig.Environment =
    "LD_LIBRARY_PATH=${config.boot.kernelPackages.nvidiaPackages.latest.out}/lib:${config.boot.kernelPackages.nvidiaPackages.latest.out}/lib64";

  environment.systemPackages = [
    pkgs.cudaPackages.cudatoolkit
  ];
}
