{
  description = "RKE2 Kubernetes on NixOS: reusable node module, inventory-driven hosts, VM test";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      inventory = import ./inventory.nix;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      linuxSystems = lib.filter (lib.hasSuffix "-linux") systems;
      mapIfDarwinToLinux = builtins.replaceStrings [ "darwin" ] [ "linux" ];

      checkSets = lib.genAttrs linuxSystems (
        system:
        (
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          {
            rke2-cluster = pkgs.testers.runNixOSTest (
              import ./tests/cluster.nix {
                inherit pkgs;
                rke2Module = self.nixosModules.default;
                clusterSettings = inventory.cluster;
              }
            );
          }
        )
      );

      interactiveApp =
        host: stem:
        let
          guest = mapIfDarwinToLinux host;
          native = guest == host;
          pkgs = nixpkgs.legacyPackages.${host};
          driver = checkSets.${guest}.${stem}.driverInteractive;

          defaultBuilder = if native then "" else "builder@linux-builder";
          # path to program for building the test driver, saved for later without
          # auto-built dependency so that we can delay build until runtime.
          drv = builtins.unsafeDiscardOutputDependency driver.drvPath;
          # path to output of the test driver, saved for later, withouth auto-built
          # dependency so that we can delay build until runtime.
          out = builtins.unsafeDiscardStringContext driver.outPath;

          # Delayed Derivation Build until Runtime (The ^* suffix is how Nix names the outputs of a recipe, as opposed to the recipe file itself.)
          realize = "nix build --no-link --extra-experimental-features 'nix-command flakes' '${drv}^*'";

          refuseLocal =
            lib.optionalString (!native)
              ''[ -n "$builder" ] || { echo "${stem}: ${host} cannot run an ${guest} test driver itself; set VM_BUILDER to an ${guest} machine, or unset it for ${defaultBuilder}." >&2; exit 1; }'';

          # Worst case every node grows its image to the declared diskSize. The
          # images are sparse, so VM_MIN_FREE_MIB can lower this when you know
          # the guests stay well under it.
          minFreeMiB = lib.foldl' lib.add 0 (
            lib.mapAttrsToList (_: node: node.virtualisation.diskSize) checkSets.${guest}.${stem}.nodes
          );

          # The driver keeps the disk images and the vsock sockets in its state
          # directory, which it takes from XDG_RUNTIME_DIR, then TMPDIR, and only
          # then the working directory (get_tmp_dir in nixos-test-driver). Every
          # ssh login sets XDG_RUNTIME_DIR to /run/user/<uid>, a tmpfs sized at a
          # tenth of RAM, so `cd` alone is not enough: the images land in memory
          # and the guests hit ENOSPC somewhere in the middle of the run. Pin all
          # three, and refuse to start when the directory is too small anyway.
          #
          # `esc` is the backslash that `$` and `"` need where this is pasted:
          # empty in the local branch, `\` inside the double-quoted ssh command.
          checkSpace =
            dir: esc:
            let
              d = "${esc}$";
              q = esc + "\"";
            in
            ''
              df -PTm ${dir} | awk -v need=${d}need '
                NR != 2 { next }
                ${d}5 < need {
                  printf ${q}${stem}: %s has %d MiB free, the VMs may need up to %d MiB; point VM_STATE_DIR at a bigger, disk-backed path\n${q}, ${d}7, ${d}5, need > ${q}/dev/stderr${q}
                  exit 1
                }
                ${d}2 == ${q}tmpfs${q} {
                  printf ${q}${stem}: warning: %s is tmpfs, so the disk images compete with guest memory\n${q}, ${d}7 > ${q}/dev/stderr${q}
                }'
            '';

          runner = pkgs.writeShellScriptBin "vm-${stem}" ''
            set -euo pipefail

            builder="''${VM_BUILDER-${defaultBuilder}}"
            statedir="''${VM_STATE_DIR:-/tmp/vm-${stem}}"
            need="''${VM_MIN_FREE_MIB:-${toString minFreeMiB}}"
            ${refuseLocal}

            if [ -z "$builder" ]; then
              echo "→ ${stem}: realizing the driver, then handing you the prompt" >&2
              ${realize}
              mkdir -p "$statedir"
              ${checkSpace "\"$statedir\"" ""}
              cd "$statedir"
              exec env XDG_RUNTIME_DIR="$statedir" TMPDIR="$statedir" \
                '${out}/bin/nixos-test-driver' "$@"
            fi

            echo "→ ${stem}: shipping the driver derivation to $builder" >&2
            nix copy --derivation --to "ssh-ng://$builder" ${drv}

            echo "→ ${stem}: realizing it there, then handing you the prompt" >&2
            exec ssh -t "$builder" "
              set -e
              need='$need'
              ${realize}
              mkdir -p '$statedir'
              cd '$statedir'
              ${checkSpace "'$statedir'" "\\"}
              exec env XDG_RUNTIME_DIR='$statedir' TMPDIR='$statedir' \
                '${out}/bin/nixos-test-driver' $*
            "
          '';
        in
        {
          type = "app";
          program = "${runner}/bin/vm-${stem}";
          meta.description =
            "Interactive NixOS test driver for ${stem}, ${guest} guests, "
            + (if native then "run here" else "run on ${defaultBuilder}");
        };
    in
    {
      # Import this from other flakes: inputs.rke2.nixosModules.default
      nixosModules = {
        rke2-node = ./modules/rke2-node.nix;
        default = self.nixosModules.rke2-node;
      };

      # lib.mkCluster { nixpkgs = ...; inventory = import ./staging.nix; modules = [ ... ]; }
      lib.mkCluster = import ./lib/mk-cluster.nix { rke2Module = self.nixosModules.default; };

      # One configuration per node: cp1, cp2, cp3, worker1, worker2.
      nixosConfigurations = self.lib.mkCluster {
        inherit nixpkgs inventory;
        modules = [ ./hosts/common.nix ];
      };

      checks = checkSets;

      apps = lib.genAttrs systems (host: {
        # One interactive driver per test, named after the test: nix run .#rke2-cluster
        rke2-cluster = interactiveApp host "rke2-cluster";

        # Plain `nix run` opens the same driver.
        default = interactiveApp host "rke2-cluster";

        deploy = {
          type = "app";
          program = lib.getExe (
            nixpkgs.legacyPackages.${host}.callPackage ./lib/deploy.nix { inherit inventory; }
          );
        };
      });

      # apps = forAllSystems (pkgs: {
      #   deploy = {
      #     type = "app";
      #     program = lib.getExe (pkgs.callPackage ./lib/deploy.nix { inherit inventory; });
      #   };
      # });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
