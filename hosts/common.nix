# Baseline for real (non-test) machines. Nothing here is RKE2-specific.
{ inventory, lib, ... }:
{
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };
  users.users.root.openssh.authorizedKeys.keys = inventory.common.adminSshKeys;

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  time.timeZone = lib.mkDefault inventory.common.timeZone;

  # Set once at first install, then leave alone (it is not "the NixOS version").
  system.stateVersion = "26.05";
}
