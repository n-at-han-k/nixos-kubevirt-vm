{
  description = "NixOS dev VM for KubeVirt — qcow2 + manifest";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # ── Tweak these per environment ──────────────────────────────
      owner = "n-at-han-k";
      repo  = "nixos-kubevirt-vm";
      # The release-download URL; overridden at build time by CI.
      imageUrl = "https://github.com/${owner}/${repo}/releases/latest/download/nixos-dev.qcow2";
      rootSize = "20Gi";
      dataSize = "50Gi";
      # ─────────────────────────────────────────────────────────────

      nixos = nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [ ./configuration.nix ./qcow.nix ];
      };

      qcow = nixos.config.system.build.qcow2;

      manifest = pkgs.writeText "dev-vm.yaml" ''
        apiVersion: cdi.kubevirt.io/v1beta1
        kind: DataVolume
        metadata:
          name: dev-root
        spec:
          source:
            http:
              url: ${imageUrl}
          storage:
            resources:
              requests:
                storage: ${rootSize}
        ---
        apiVersion: kubevirt.io/v1
        kind: VirtualMachine
        metadata:
          name: dev
        spec:
          running: true
          dataVolumeTemplates:
            - metadata:
                name: dev-data
              spec:
                storage:
                  resources:
                    requests:
                      storage: ${dataSize}
                source:
                  blank: {}
          template:
            metadata:
              labels:
                kubevirt.io/domain: dev
            spec:
              domain:
                cpu: { cores: 4 }
                memory: { guest: 8Gi }
                devices:
                  disks:
                    - name: rootdisk
                      disk: { bus: virtio }
                    - name: datadisk
                      disk: { bus: virtio }
                  interfaces:
                    - name: default
                      masquerade: {}
              networks:
                - name: default
                  pod: {}
              volumes:
                - name: rootdisk
                  dataVolume:
                    name: dev-root
                - name: datadisk
                  dataVolume:
                    name: dev-data
      '';
    in {
      packages.${system} = {
        qcow2    = qcow;
        manifest = manifest;
        default  = qcow;
      };
    };
}
