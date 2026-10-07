# Placeholder so the example evaluates. Replace per machine with the output of
# `nixos-generate-config --show-hardware-config`, or with a disko layout when
# installing through nixos-anywhere. Give /var/lib/rancher plenty of disk.
{ lib, ... }:
{
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "umask=0077" ];
  };
}
