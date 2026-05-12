{ config, lib, pkgs, modulesPath, ... }:
{
  imports = [ "${toString modulesPath}/profiles/qemu-guest.nix" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  boot.growPartition = true;
  boot.kernelParams = [ "console=ttyS0" ];
  boot.loader.grub.device = lib.mkDefault "/dev/vda";
  boot.loader.timeout = 0;

  system.build.qcow2 = import "${modulesPath}/../lib/make-disk-image.nix" {
    inherit lib config pkgs;
    diskSize = 8192;        # MiB — virtual size baked into the qcow2
    format = "qcow2";
    partitionTableType = "hybrid";
  };
}
