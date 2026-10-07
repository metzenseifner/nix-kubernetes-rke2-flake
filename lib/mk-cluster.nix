# Turns an inventory (plain data, see ../inventory.nix) into one
# nixosSystem per node. Exposed as `lib.mkCluster` so other flakes can
# reuse it with their own inventory.
{ rke2Module }:
{
  nixpkgs,
  inventory,
  # NixOS modules added to every node (base system, secrets, monitoring...).
  modules ? [ ],
  specialArgs ? { },
}:
builtins.mapAttrs (
  name: node:
  nixpkgs.lib.nixosSystem {
    specialArgs = specialArgs // {
      inherit inventory;
      nodeName = name;
    };
    modules = [
      rke2Module
      {
        networking.hostName = nixpkgs.lib.mkDefault name;
        nixpkgs.hostPlatform = nixpkgs.lib.mkDefault (node.system or "x86_64-linux");
        rke2Cluster.enable = true;
      }
      # Two separate definitions so the module system merges them, and
      # reports a conflict if a node redefines a cluster-wide value.
      { rke2Cluster = inventory.cluster; }
      { rke2Cluster = node.rke2; }
    ]
    ++ modules
    ++ (node.modules or [ ]);
  }
) inventory.nodes
