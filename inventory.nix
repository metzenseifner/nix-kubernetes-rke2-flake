# Every environment-dependent value lives here. Copy this file per
# environment (staging, production...) and pass each to lib.mkCluster.
{
  # Applied to every node. Keys are rke2Cluster options (see modules/rke2-node.nix);
  # a typo fails evaluation instead of being silently ignored.
  cluster = {
    kubernetesVersion = "1.35";

    # Fixed registration address. Pointing it at cp1 works to get started;
    # for real high availability put a load balancer or a DNS name with all
    # server addresses in front, so nodes can still (re)join while cp1 is down.
    serverAddress = "10.0.0.11";
    tlsSan = [ "k8s-api.example.internal" ];

    # Runtime paths, provisioned by sops-nix or agenix (not by this flake).
    tokenFile = "/run/secrets/rke2-token";
    agentTokenFile = "/run/secrets/rke2-agent-token";

    cni = "canal";
    dedicatedControlPlane = true;
  };

  # Read by hosts/common.nix; nothing RKE2-specific.
  common = {
    adminSshKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIReplaceMeWithYourRealPublicKey000000000 admin@laptop"
    ];
    timeZone = "UTC";
  };

  nodes = {
    cp1 = {
      system = "x86_64-linux";
      deploy.targetHost = "root@10.0.0.11";
      rke2 = {
        role = "server";
        bootstrap = true;
        nodeIP = "10.0.0.11";
      };
      modules = [ ./hosts/hardware-placeholder.nix ];
    };
    cp2 = {
      system = "x86_64-linux";
      deploy.targetHost = "root@10.0.0.12";
      rke2 = {
        role = "server";
        nodeIP = "10.0.0.12";
      };
      modules = [ ./hosts/hardware-placeholder.nix ];
    };
    cp3 = {
      system = "x86_64-linux";
      deploy.targetHost = "root@10.0.0.13";
      rke2 = {
        role = "server";
        nodeIP = "10.0.0.13";
      };
      modules = [ ./hosts/hardware-placeholder.nix ];
    };

    worker1 = {
      system = "x86_64-linux";
      deploy.targetHost = "root@10.0.0.21";
      rke2 = {
        role = "agent";
        nodeIP = "10.0.0.21";
      };
      modules = [ ./hosts/hardware-placeholder.nix ];
    };
    worker2 = {
      system = "x86_64-linux";
      deploy.targetHost = "root@10.0.0.22";
      rke2 = {
        role = "agent";
        nodeIP = "10.0.0.22";
        nodeLabels = [ "example.com/pool=general" ];
      };
      modules = [ ./hosts/hardware-placeholder.nix ];
    };
  };
}
