# Two-node RKE2 cluster: cp1 (server, bootstrap) and worker1 (agent).
#
# It reuses the cluster-wide settings from inventory.nix (version, network
# plugin, address ranges, taints...) and replaces only the values that depend
# on the environment: addresses, token path and interface names.
#
#   headless:     nix build .#checks.x86_64-linux.rke2-cluster -L
#   interactive:  nix run .#checks.x86_64-linux.rke2-cluster.driverInteractive
{
  pkgs,
  rke2Module,
  clusterSettings,
}:
let
  inherit (pkgs) lib;

  # Values that only make sense on real hardware.
  sharedSettings = removeAttrs clusterSettings [
    "serverAddress"
    "tlsSan"
    "tokenFile"
    "agentTokenFile"
    "canalInterface"
  ];

  # Test workloads cannot pull from a registry, so build one with Nix.
  echoImage = pkgs.dockerTools.buildImage {
    name = "test.local/echo";
    tag = "local";
    copyToRoot = pkgs.buildEnv {
      name = "echo-image-root";
      paths = with pkgs; [
        tini
        bashInteractive
        coreutils
        socat
      ];
    };
    config.Entrypoint = [
      "/bin/tini"
      "--"
      "/bin/sleep"
      "inf"
    ];
  };

  # One pod per node (tolerating any taint, including a dedicated control plane).
  echoDaemonSet = pkgs.writeText "echo-daemonset.json" (
    builtins.toJSON {
      apiVersion = "apps/v1";
      kind = "DaemonSet";
      metadata.name = "echo";
      spec = {
        selector.matchLabels.app = "echo";
        template = {
          metadata.labels.app = "echo";
          spec = {
            tolerations = [ { operator = "Exists"; } ];
            containers = [
              {
                name = "echo";
                image = "test.local/echo:local";
                imagePullPolicy = "Never";
                command = [
                  "socat"
                  "TCP4-LISTEN:8000,fork"
                  "EXEC:echo hello"
                ];
                resources.limits.memory = "20Mi";
              }
            ];
          };
        };
      };
    }
  );
in
{
  name = "rke2-cluster";

  # Root login over vsock with an empty password, interactive driver only.
  # The driver prints one ssh command per machine when it starts.
  interactive.sshBackdoor.enable = true;

  # systemd-ssh-generator only writes sshd-vsock.socket when /dev/vsock is
  # already there, and generators run before udev loads the virtio transport.
  # Without this the backdoor silently never listens and every one of those
  # printed commands answers "Port 22 on ... is not open".
  interactive.defaults.boot.initrd.kernelModules = [ "vmw_vsock_virtio_transport" ];

  defaults =
    { config, nodes, ... }:
    {
      imports = [ rke2Module ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
        diskSize = 8192;
      };

      # Stands in for /run/secrets/... from sops-nix or agenix.
      environment.etc."rke2/token" = {
        text = "test-only-cluster-token";
        mode = "0400";
      };

      rke2Cluster = lib.mkMerge [
        sharedSettings
        {
          enable = true;
          serverAddress = nodes.cp1.networking.primaryIPAddress;
          tokenFile = "/etc/rke2/token";
          nodeIP = config.networking.primaryIPAddress;
          # eth0 is the driver's control link; nodes talk to each other on eth1.
          canalInterface = "eth1";
          extraImages = [ echoImage ];
          # Fewer components, so two virtual machines fit in a laptop's memory.
          disable = [
            "rke2-coredns"
            "rke2-metrics-server"
            "rke2-ingress-nginx"
            "rke2-snapshot-controller"
            "rke2-snapshot-controller-crd"
            "rke2-snapshot-validation-webhook"
          ];
        }
      ];
    };

  nodes = {
    cp1.rke2Cluster = {
      role = "server";
      bootstrap = true;
    };
    worker1.rke2Cluster.role = "agent";
  };

  # Interactive only: reach the API server from the host on 127.0.0.1:16443.
  interactive.nodes.cp1.virtualisation.forwardPorts = [
    {
      from = "host";
      host.port = 16443;
      guest.port = 6443;
    }
  ];

  testScript = ''
    import json

    start_all()

    cp1.wait_for_unit("rke2-server.service")
    worker1.wait_for_unit("rke2-agent.service")

    with subtest("both nodes register and become Ready"):
        cp1.wait_until_succeeds("kubectl get node worker1", timeout=900)
        cp1.wait_until_succeeds(
            "kubectl wait --for=condition=Ready --timeout=30s node/cp1 node/worker1",
            timeout=900,
        )

    with subtest("roles match the declaration"):
        control = cp1.succeed(
            "kubectl get nodes -l node-role.kubernetes.io/control-plane=true -o name"
        ).split()
        t.assertEqual(control, ["node/cp1"])

    with subtest("pods on different nodes reach each other through the firewall"):
        cp1.succeed("kubectl apply -f ${echoDaemonSet}")
        cp1.wait_until_succeeds("kubectl rollout status daemonset/echo --timeout=30s", timeout=900)
        pods = json.loads(cp1.succeed("kubectl get pods -l app=echo -o json"))["items"]
        t.assertEqual(sorted(p["spec"]["nodeName"] for p in pods), ["cp1", "worker1"])

        for target in pods:
            ip = target["status"]["podIP"]
            for machine in (cp1, worker1):
                machine.succeed(f"ping -c 1 -W 5 {ip}")
            for source in pods:
                name = source["metadata"]["name"]
                reply = cp1.succeed(f"kubectl exec {name} -- socat TCP:{ip}:8000 -")
                t.assertEqual(reply.strip(), "hello")
  '';
}
