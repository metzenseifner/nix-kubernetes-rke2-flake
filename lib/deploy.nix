# `nix run .#deploy [-- node ...]`
#
# Rolls nodes out with nixos-rebuild in a safe order: the bootstrap server,
# then the remaining servers one at a time, then workers. With node names as
# arguments only those nodes are deployed (still in that order).
#
# Environment: FLAKE (default ".") and ACTION (default "switch"; "boot",
# "test" and "dry-activate" also work).
{
  lib,
  writeShellApplication,
  nixos-rebuild-ng,
  inventory,
}:
let
  rank =
    node:
    if node.rke2.role == "server" then
      (if node.rke2.bootstrap or false then 0 else 1)
    else
      2;
  ordered = lib.sort (
    a: b: if rank a.value == rank b.value then a.name < b.name else rank a.value < rank b.value
  ) (lib.attrsToList inventory.nodes);
  plan = lib.concatMapStrings (n: "${n.name} ${n.value.deploy.targetHost}\n") ordered;
in
writeShellApplication {
  name = "deploy";
  runtimeInputs = [ nixos-rebuild-ng ];
  text = ''
    flake="''${FLAKE:-.}"
    action="''${ACTION:-switch}"
    selected=" $* "

    # The plan is read from file descriptor 3 so that ssh (inside nixos-rebuild)
    # keeps the terminal and cannot swallow the remaining lines.
    while read -r name target <&3; do
      [ -n "$name" ] || continue
      if [ "$#" -gt 0 ] && [[ "$selected" != *" $name "* ]]; then
        continue
      fi
      echo ">>> $action $name on $target"
      nixos-rebuild "$action" --flake "$flake#$name" --target-host "$target"
    done 3<<'PLAN'
    ${plan}
    PLAN
  '';
}
