{ config, pkgs, ... }:
{
  networking.hostName = "dev";

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "prohibit-password";
  };

  services.qemuGuest.enable = true;
  services.cloud-init.enable = true;

  # Login prompt on serial console (so `virtctl console dev` works)
  systemd.services."serial-getty@ttyS0".enable = true;

  users.users.snowman = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
  };

  security.sudo.wheelNeedsPassword = false;

  # Auto-format the second disk (/dev/vdb) on first boot, then mount it.
  systemd.services.format-home = {
    wantedBy = [ "home.mount" ];
    before   = [ "home.mount" ];
    unitConfig.ConditionPathExists = "!/dev/disk/by-label/home";
    serviceConfig.Type = "oneshot";
    script = "${pkgs.e2fsprogs}/bin/mkfs.ext4 -L home /dev/vdb";
  };

  fileSystems."/home" = {
    device  = "/dev/disk/by-label/home";
    fsType  = "ext4";
    options = [ "nofail" ];
  };

  environment.systemPackages = with pkgs; [
    git vim tmux ripgrep fd htop
  ];

  system.stateVersion = "25.11";
}
