{ config, pkgs, ... }:
{
  # Enable nvenc support
  services.sunshine.package =
    with pkgs;
    (pkgs.sunshine.override {
      cudaSupport = true;
      cudaPackages = cudaPackages;
    }).overrideAttrs
      (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [
          cudaPackages.cuda_nvcc
          (lib.getDev cudaPackages.cuda_cudart)
        ];
        cmakeFlags = old.cmakeFlags ++ [
          "-DCMAKE_CUDA_COMPILER=${(lib.getExe cudaPackages.cuda_nvcc)}"
        ];
      });

  systemd.user.services.sunshine.serviceConfig.Environment =
    "LD_LIBRARY_PATH=${config.boot.kernelPackages.nvidiaPackages.latest.out}/lib:${config.boot.kernelPackages.nvidiaPackages.latest.out}/lib64";

  environment.systemPackages = with pkgs; [
    cudaPackages.cudatoolkit
  ];
}
