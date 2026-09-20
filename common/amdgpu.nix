{ ... }:

# amdgpu overdrive plumbing.
#
# `ppfeaturemask=0xffffffff` unlocks the SMU overdrive sysfs interfaces
# (gpu_od/fan_ctrl, pp_od_clk_voltage) that gpu-panel writes to directly.
# There is no LACT daemon in the loop: gpu-panel is the single writer, so a
# control set in its web UI is not fought over or reverted by a second daemon.
{
  boot.initrd.kernelModules = [ "amdgpu" ];

  boot.kernelParams = [
    "amdgpu.ppfeaturemask=0xffffffff"
  ];
}
