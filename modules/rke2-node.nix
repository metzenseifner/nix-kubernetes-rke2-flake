# One module for every RKE2 node, control (server) or worker (agent).
#
# Cluster-wide values (same on every node) and per-node values share the
# `rke2Cluster` namespace. The flake's `lib.mkCluster` feeds them in from
# `inventory.nix`; the NixOS test feeds them in from the test network.
#
# Anything not covered here can still be set directly on `services.rke2.*`;
# the NixOS module system merges it with what this module sets.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.rke2Cluster;
  isServer = cfg.role == "server";
  isBootstrap = isServer && cfg.bootstrap;

  supervisorPort = 9345;
  apiServerPort = 6443;

  # Wrap IPv6 literals in brackets for use inside a URL.
  urlHost = host: if lib.hasInfix ":" host then "[${host}]" else host;

  # Inbound rules from https://docs.rke2.io/install/requirements#inbound-network-rules
  # "interfaces" are trusted so traffic between pods and their own host is not
  # dropped by the NixOS firewall. The "+" suffix is the iptables wildcard.
  cniNetworking = {
    canal = {
      tcp = [ 9099 ];
      udp = [ 8472 ];
      interfaces = [
        "cali+"
        "flannel.1"
      ];
    };
    calico = {
      tcp = [
        179
        5473
        9098
        9099
      ];
      udp = [ 4789 ];
      interfaces = [
        "cali+"
        "tunl0"
        "vxlan.calico"
      ];
    };
    cilium = {
      tcp = [ 4240 ];
      udp = [ 8472 ];
      interfaces = [
        "cilium_+"
        "lxc+"
      ];
    };
    flannel = {
      tcp = [ ];
      udp = [ 8472 ];
      interfaces = [
        "cni0"
        "flannel.1"
      ];
    };
    none = {
      tcp = [ ];
      udp = [ ];
      interfaces = [ ];
    };
  };
  cniNet = cniNetworking.${cfg.cni};

  # Airgap image tarballs shipped as passthru attributes of the rke2 package.
  imageArch =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "rke2Cluster: RKE2 has no airgap images for ${pkgs.stdenv.hostPlatform.system}");
  imageTarball = name: cfg.package."images-${name}-linux-${imageArch}-tar-zst";
  airgapImages = lib.optionals cfg.airgapImages (
    [ (imageTarball "core") ] ++ lib.optional (cfg.cni != "none") (imageTarball cfg.cni)
  );

  tlsSans = lib.unique (lib.optional (cfg.serverAddress != null) cfg.serverAddress ++ cfg.tlsSan);

  notInStore = path: path == null || !(lib.hasPrefix builtins.storeDir path);
  secretPath = lib.types.nullOr (lib.types.strMatching "/.+");
in
{
  options.rke2Cluster = {
    enable = lib.mkEnableOption "this machine as an RKE2 Kubernetes node";

    # ---------------------------------------------------------------- per node

    role = lib.mkOption {
      type = lib.types.enum [
        "server"
        "agent"
      ];
      description = ''
        `server` is a control node (API server, etcd, scheduler; it also runs
        workloads unless `dedicatedControlPlane` is set). `agent` is a worker.
      '';
    };

    bootstrap = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether this server creates the cluster. Exactly one server should set
        this. It starts without `--server`; every other node joins through
        `serverAddress`. Do not wipe and redeploy this node while the flag is
        still set, or it will start a second, separate cluster.
      '';
    };

    nodeIP = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "10.0.0.11";
      description = "Address this node advertises. Null lets RKE2 pick the default-route interface.";
    };

    nodeLabels = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "topology.kubernetes.io/zone=rack-a" ];
      description = "Labels applied when the node registers.";
    };

    nodeTaints = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "gpu=true:NoSchedule" ];
      description = "Taints applied when the node registers.";
    };

    # ------------------------------------------------------------ cluster-wide

    kubernetesVersion = lib.mkOption {
      type = lib.types.strMatching "1\\.[0-9]+";
      example = "1.35";
      description = ''
        Kubernetes minor version. Selects `pkgs.rke2_<major>_<minor>`, so that
        bumping nixpkgs never moves the cluster to a new minor version on its
        own. Upgrade one minor version at a time, servers first.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      default =
        let
          attr = "rke2_" + lib.replaceStrings [ "." ] [ "_" ] cfg.kubernetesVersion;
        in
        pkgs.${attr} or (throw ''
          rke2Cluster: this nixpkgs has no `${attr}`. Pick a kubernetesVersion it provides
          (compare `nix eval nixpkgs#rke2_stable.version` and `nix eval nixpkgs#rke2_latest.version`).
        '');
      defaultText = lib.literalExpression ''pkgs."rke2_<major>_<minor>" (from kubernetesVersion)'';
      description = "The RKE2 package. Normally derived from `kubernetesVersion`.";
    };

    serverAddress = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "k8s-api.example.internal";
      description = ''
        Fixed registration address (host name or IP, no scheme, no port) that
        joining nodes contact on port ${toString supervisorPort}. Use a load
        balancer or DNS name in front of all servers for high availability.
        Automatically added to the API server certificate.
      '';
    };

    tlsSan = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra subject alternative names for the API server certificate.";
    };

    tokenFile = lib.mkOption {
      type = secretPath;
      default = null;
      example = "/run/secrets/rke2-token";
      description = ''
        Runtime path of the cluster join token (for example from sops-nix or
        agenix). Must be outside the Nix store, which is world-readable.
        Required on servers; also used by agents if `agentTokenFile` is null.
      '';
    };

    agentTokenFile = lib.mkOption {
      type = secretPath;
      default = null;
      example = "/run/secrets/rke2-agent-token";
      description = ''
        Optional separate token for workers, so worker machines never hold the
        server token. Servers accept it; agents join with it.
      '';
    };

    cni = lib.mkOption {
      type = lib.types.enum (builtins.attrNames cniNetworking);
      default = "canal";
      description = "Container Network Interface plugin. Drives firewall rules and airgap images.";
    };

    canalInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "eth1";
      description = ''
        Interface Canal uses between nodes. Leave null to use the
        default-route interface. Must be the same name on every node.
      '';
    };

    clusterCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.42.0.0/16";
      description = "Pod address range. Cannot be changed after the cluster is created.";
    };

    serviceCidr = lib.mkOption {
      type = lib.types.str;
      default = "10.43.0.0/16";
      description = "Service address range. Cannot be changed after the cluster is created.";
    };

    disable = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "rke2-ingress-nginx" ];
      description = "Packaged components to skip (RKE2 `--disable`). Applied on servers.";
    };

    dedicatedControlPlane = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Taint servers with CriticalAddonsOnly=true:NoExecute so ordinary workloads run only on workers.";
    };

    airgapImages = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Preload the RKE2 core and Container Network Interface images from the
        Nix store, so nodes boot without reaching a container registry and every
        node runs the exact images pinned by your flake.lock.
      '';
    };

    extraImages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "More image tarballs to preload (for example from `dockerTools.pullImage`).";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open the ports RKE2 and the chosen network plugin need, and trust the plugin's interfaces.";
    };

    openNodePortRange = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Also open 30000-32767/TCP for NodePort services.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = isServer || !cfg.bootstrap;
        message = "rke2Cluster.bootstrap can only be true on a server.";
      }
      {
        assertion = isBootstrap || cfg.serverAddress != null;
        message = "rke2Cluster.serverAddress must be set on every node except the bootstrap server.";
      }
      {
        assertion = !isServer || cfg.tokenFile != null;
        message = "rke2Cluster.tokenFile must be set on servers.";
      }
      {
        assertion = isServer || cfg.tokenFile != null || cfg.agentTokenFile != null;
        message = "rke2Cluster: agents need agentTokenFile or tokenFile.";
      }
      {
        assertion = notInStore cfg.tokenFile && notInStore cfg.agentTokenFile;
        message = "rke2Cluster token files must live outside ${builtins.storeDir}, which every local user can read.";
      }
    ];

    warnings =
      lib.optional (cfg.canalInterface != null && cfg.cni != "canal")
        "rke2Cluster.canalInterface has no effect unless cni = \"canal\"."
      ++ lib.optional (cfg.openFirewall && config.networking.nftables.enable)
        "rke2Cluster: the trusted-interface wildcards assume the iptables-based NixOS firewall; check them with networking.nftables.enable.";

    services.rke2 = lib.mkMerge [
      {
        enable = true;
        inherit (cfg) package role nodeIP;
        nodeLabel = cfg.nodeLabels;
        nodeTaint =
          cfg.nodeTaints
          ++ lib.optional (isServer && cfg.dedicatedControlPlane) "CriticalAddonsOnly=true:NoExecute";
        images = airgapImages ++ cfg.extraImages;
        gracefulNodeShutdown.enable = lib.mkDefault true;
      }

      (lib.mkIf (!isBootstrap) {
        serverAddr = "https://${urlHost cfg.serverAddress}:${toString supervisorPort}";
      })

      (lib.mkIf isServer {
        inherit (cfg) tokenFile agentTokenFile cni;
        disable = cfg.disable;
        extraFlags = [
          "--cluster-cidr=${cfg.clusterCidr}"
          "--service-cidr=${cfg.serviceCidr}"
        ]
        ++ map (san: "--tls-san=${san}") tlsSans;

        # HelmChartConfig overrides the packaged rke2-canal chart. Every server
        # gets an identical copy, which is what RKE2 expects.
        manifests.nixos-rke2-canal-config = lib.mkIf (cfg.cni == "canal" && cfg.canalInterface != null) {
          content = {
            apiVersion = "helm.cattle.io/v1";
            kind = "HelmChartConfig";
            metadata = {
              name = "rke2-canal";
              namespace = "kube-system";
            };
            spec.valuesContent = builtins.toJSON { flannel.iface = cfg.canalInterface; };
          };
        };
      })

      (lib.mkIf (!isServer) {
        tokenFile = if cfg.agentTokenFile != null then cfg.agentTokenFile else cfg.tokenFile;
      })
    ];

    boot.kernelModules = [
      "overlay"
      "br_netfilter"
    ];
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-iptables" = lib.mkDefault 1;
      "net.bridge.bridge-nf-call-ip6tables" = lib.mkDefault 1;
    };

    networking.firewall = lib.mkMerge [
      # Strict reverse-path filtering drops legitimate overlay and service traffic.
      { checkReversePath = lib.mkDefault "loose"; }
      (lib.mkIf cfg.openFirewall {
        allowedTCPPorts = [
          10250 # kubelet
        ]
        ++ cniNet.tcp
        ++ lib.optionals isServer [
          apiServerPort
          supervisorPort
          2379 # etcd client
          2380 # etcd peer
        ];
        allowedUDPPorts = cniNet.udp;
        allowedTCPPortRanges = lib.optional cfg.openNodePortRange {
          from = 30000;
          to = 32767;
        };
        trustedInterfaces = cniNet.interfaces;
      })
    ];

    # kubectl for root on servers; the admin kubeconfig is root-only (0600).
    environment.systemPackages = lib.optional isServer pkgs.kubectl;
    environment.sessionVariables = lib.mkIf isServer {
      KUBECONFIG = "/etc/rancher/rke2/rke2.yaml";
    };
  };
}
