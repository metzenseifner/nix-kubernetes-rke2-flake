# RKE2 on NixOS

A reusable NixOS module for Rancher Kubernetes Engine 2 (RKE2) nodes, an inventory that holds every environment-dependent value, one `nixosConfiguration` per node, an ordered deploy command, and a NixOS virtual machine test you can also run interactively.

```
flake.nix
inventory.nix               every environment-dependent value (addresses, roles, token paths)
modules/rke2-node.nix       nixosModules.default: the rke2Cluster.* options
lib/mk-cluster.nix          lib.mkCluster: inventory -> nixosConfigurations
lib/deploy.nix              apps.deploy: ordered nixos-rebuild rollout
hosts/common.nix            non-RKE2 baseline for real machines (Secure Shell keys, stateVersion)
hosts/hardware-placeholder.nix
tests/cluster.nix           checks.<system>.rke2-cluster
```

## What the module decides for you

The Kubernetes minor version is pinned by name (`kubernetesVersion = "1.35"` selects `pkgs.rke2_1_35`), so updating nixpkgs never moves the cluster to a new minor version by itself. Core and network plugin images are preloaded from the Nix store (`airgapImages = true`), so a node boots without reaching a container registry and runs exactly the images your `flake.lock` pins. Firewall ports follow the RKE2 inbound rules for the node's role and the chosen network plugin, the plugin's interfaces are trusted, and reverse-path filtering is relaxed to `loose`. Kernel modules and forwarding settings are loaded, graceful node shutdown is on, and token files are rejected at evaluation time if they point into the world-readable Nix store.

Anything the module does not cover can be set directly on `services.rke2.*` in a node's modules; the module system merges it.

## Using it for a real cluster

1. Run `nix flake lock`, then edit `inventory.nix`. Exactly one server has `bootstrap = true`. For high availability, point `serverAddress` at a load balancer or a Domain Name System (DNS) name covering all servers rather than at cp1.
2. Generate two tokens (`openssl rand -hex 32`), one for servers and one for workers, and provision them at the paths named in the inventory with sops-nix or agenix. For example, with sops-nix in `hosts/common.nix`: `sops.secrets.rke2-token = { };` produces `/run/secrets/rke2-token`. Workers only need the agent token. On a fresh install, the machine's host key must already be able to decrypt the secret (for example, pre-seed it with `nixos-anywhere --extra-files`).
3. Replace `hosts/hardware-placeholder.nix` per node with real hardware configuration or a disko layout, then install each machine once:
   `nix run github:nix-community/nixos-anywhere -- --flake .#cp1 --target-host root@10.0.0.11`
4. From then on, `nix run .#deploy` rolls out every node in a safe order (bootstrap server, other servers one at a time, then workers). `nix run .#deploy -- worker2` deploys only that node. `ACTION=boot` or `ACTION=dry-activate` change the `nixos-rebuild` action.
5. On a server, `kubectl get nodes` works as root. For a workstation, copy `/etc/rancher/rke2/rke2.yaml` and replace `127.0.0.1` with `serverAddress`, which is already in the certificate.

To manage several environments, copy `inventory.nix` (for example `staging.nix`) and call `self.lib.mkCluster { inherit nixpkgs; inventory = import ./staging.nix; modules = [ ./hosts/common.nix ]; }`. Other flakes can import only `nixosModules.default` and supply `rke2Cluster.*` values however they like.

## Running the test

The test boots `cp1` (bootstrap server) and `worker1` (agent) using the same cluster-wide settings as `inventory.nix`, with only the addresses, token path, and interface swapped for the test network. It checks that both nodes become Ready, that roles match, and that pods on different nodes can reach each other through the firewall. It needs hardware virtualization (`/dev/kvm`) and roughly 8 gigabytes of free memory.

Headless: `nix build .#checks.x86_64-linux.rke2-cluster -L`

Interactive:

```
nix run .#checks.x86_64-linux.rke2-cluster.driverInteractive
>>> start_all()
>>> test_script()          # optional: run the assertions, then keep poking around
>>> dump_machine_ssh()     # prints the ssh commands again
```

When the driver starts, it prints one Secure Shell command per machine, in the form `ssh -o User=root vsock-mux//tmp/.../cp1_host.socket`. Run it from a second terminal; root has an empty password inside the test only. This needs `systemd-ssh-proxy` on the host, which is on by default on NixOS 25.05 and newer; on other distributions, enable the configuration described in `systemd-ssh-proxy(1)`.

To use `kubectl` from the host in interactive mode, port 6443 on cp1 is forwarded to 127.0.0.1:16443:

```
ssh -o User=root vsock-mux//tmp/.../cp1_host.socket cat /etc/rancher/rke2/rke2.yaml \
  | sed 's/127.0.0.1:6443/127.0.0.1:16443/' > rke2-test.yaml
kubectl --kubeconfig rke2-test.yaml get nodes
```

`--keep-machine-state` on the driver reuses virtual machine disks between runs, which saves several minutes of image import.

### Where the virtual machine state goes

`nix run .#` keeps the disk images, the vsock sockets, and the driver history in one state directory, `/tmp/vm-rke2-cluster` unless `VM_STATE_DIR` says otherwise. The driver reads that directory from `XDG_RUNTIME_DIR` before `TMPDIR` and the working directory, so the runner sets all three: left alone, every Secure Shell login would put it under `/run/user/<uid>`, which is usually a tmpfs of a few hundred megabytes, and the guests would hit `ENOSPC` partway through importing the airgap images. Both nodes together can grow to the sum of their `diskSize`, so point `VM_STATE_DIR` at a disk-backed path with that much room; `VM_MIN_FREE_MIB` lowers the requirement when you know the sparse images stay below it.

This bites hardest on a remote builder whose root filesystem is a tmpfs, such as the nix-darwin `linux-builder` under the Virtualization.framework backend, where only the Nix store volume is on disk. Give that virtual machine a writable directory on its data disk and name it in `VM_STATE_DIR`.

## Upgrading

Change `kubernetesVersion` one minor version at a time, once your nixpkgs provides the package (`nix eval .#nixosConfigurations.cp1.pkgs.rke2_latest.version`). Run the test, then `nix run .#deploy`; servers go first, as Kubernetes requires. Kubernetes cannot skip minor versions.

## Limits to know about

The firewall rules open ports to every source address. If nodes sit on a network with untrusted machines, restrict the etcd ports (2379, 2380) and the supervisor port (9345) to cluster members at an upstream firewall. The trusted-interface wildcards assume the default iptables-based NixOS firewall. Airgap images add several hundred megabytes to each node's closure; set `airgapImages = false` if you would rather pull from a registry. Changing `clusterCidr` or `serviceCidr` after creation is not supported by RKE2.
