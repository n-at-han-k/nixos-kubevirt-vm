# nixos-kubevirt-vm

NixOS dev VM for KubeVirt — qcow2 image built with Nix, deployed via CDI DataVolume + `kubectl apply`.

## Prerequisites

- [Nix](https://nixos.org/download/) with flakes enabled
- A Kubernetes cluster with [KubeVirt](https://kubevirt.io/) and [CDI](https://github.com/kubevirt/containerized-data-importer) installed
- A Linux builder (if building from macOS — see [Building from macOS](#building-from-macos))

## Setup

1. Clone the repo:

   ```bash
   git clone https://github.com/n-at-han-k/nixos-kubevirt-vm.git
   cd nixos-kubevirt-vm
   ```

2. Add your SSH public key in `configuration.nix`:

   ```nix
   openssh.authorizedKeys.keys = [
     "ssh-ed25519 AAAA...your_actual_key... nathan@macair"
   ];
   ```

3. (Optional) Adjust resource sizes in `flake.nix`:

   | Variable   | Default | Description                          |
   |------------|---------|--------------------------------------|
   | `rootSize` | `20Gi`  | PVC size for the root disk           |
   | `dataSize` | `50Gi`  | PVC size for the persistent data disk |

## Building locally

```bash
# Build the qcow2 image
nix build .#qcow2

# Build the Kubernetes manifest
nix build .#manifest
```

The qcow2 lands at `result/nixos.qcow2`. The manifest at `result` (a text file).

## Deploying via GitHub Actions (recommended)

Push a tag to trigger a release build:

```bash
git tag v0.1.0
git push --tags
```

GitHub Actions will:
1. Build the qcow2 image and manifest with Nix
2. Create a GitHub Release with both files attached

Then deploy the VM:

```bash
# From the raw manifest on main
curl -sL https://raw.githubusercontent.com/n-at-han-k/nixos-kubevirt-vm/main/dev-vm.yaml \
  | kubectl apply -f -

# Or from the latest release artifact
gh release download latest -R n-at-han-k/nixos-kubevirt-vm -p dev-vm.yaml -O - \
  | kubectl apply -f -
```

## Deploying manually

If you have an HTTP server your cluster can reach:

```bash
nix build .#qcow2
cp -L result/nixos.qcow2 /srv/images/nixos-dev.qcow2

nix build .#manifest
kubectl apply -f result
```

Update `imageUrl` in `flake.nix` to point at wherever you're hosting the image.

## Injecting SSH keys into a pre-built image

If you're using a qcow2 from a CI release and didn't bake your key in at build time, there are several ways to get your SSH key into the VM.

### Option 1: Kubernetes Secret + cloud-init disk (recommended)

KubeVirt supports attaching a `cloudInitNoCloud` disk. Create a Secret with your key and wire it into the VM spec.

1. Create the Secret:

   ```bash
   kubectl create secret generic dev-ssh-key \
     --from-literal=userdata="$(cat <<'EOF'
   #cloud-config
   users:
     - name: nathan
       ssh_authorized_keys:
         - ssh-ed25519 AAAA...your_actual_key... nathan@macair
   EOF
   )"
   ```

2. Add a cloud-init disk to the VirtualMachine spec (in `flake.nix` or by patching the manifest):

   ```yaml
   spec:
     template:
       spec:
         domain:
           devices:
             disks:
               # ... existing disks ...
               - name: cloudinit
                 disk: { bus: virtio }
         volumes:
           # ... existing volumes ...
           - name: cloudinit
             cloudInitNoCloud:
               secretRef:
                 name: dev-ssh-key
   ```

   NixOS needs `services.cloud-init.enable = true;` in `configuration.nix` for this to work. Add it before building, or use Option 2 if you're working with an image that doesn't have cloud-init.

### Option 2: Mount a Secret as an extra disk and use a startup script

If you don't want cloud-init in the image, you can mount a ConfigMap/Secret as a disk and have a systemd service read the key on boot.

1. Create a ConfigMap with your public key:

   ```bash
   kubectl create configmap dev-ssh-pubkey \
     --from-file=authorized_keys=$HOME/.ssh/id_ed25519.pub
   ```

2. Add a `configMap` volume to the VM and a systemd unit in `configuration.nix` to copy it:

   ```yaml
   # In the VirtualMachine manifest, add to volumes:
   - name: ssh-pubkey
     configMap:
       name: dev-ssh-pubkey

   # And to devices.disks:
   - name: ssh-pubkey
     disk: { bus: virtio }
   ```

   ```nix
   # In configuration.nix — mount the config disk and install the key
   systemd.services.install-ssh-key = {
     wantedBy = [ "multi-user.target" ];
     after = [ "local-fs.target" ];
     serviceConfig.Type = "oneshot";
     script = ''
       mkdir -p /home/nathan/.ssh
       cp /mnt/ssh-pubkey/authorized_keys /home/nathan/.ssh/authorized_keys
       chown -R nathan:users /home/nathan/.ssh
       chmod 700 /home/nathan/.ssh
       chmod 600 /home/nathan/.ssh/authorized_keys
     '';
   };

   fileSystems."/mnt/ssh-pubkey" = {
     device = "/dev/disk/by-id/virtio-ssh-pubkey";
     fsType = "iso9660";
     options = [ "ro" "nofail" ];
   };
   ```

### Option 3: virtctl SSH access (no key injection needed)

If you just need quick access and have `virtctl` on your path:

```bash
# Uses the Kubernetes API — no SSH key in the image required
virtctl ssh --local-ssh=false nathan@dev

# Or forward a port and SSH normally
virtctl port-forward dev 2222:22 &
ssh -p 2222 nathan@localhost
```

Note: `virtctl ssh --local-ssh=false` uses the guest agent, which requires `services.qemuGuest.enable = true;` (already set in this repo's `configuration.nix`).

### Option 4: Patch the qcow2 directly with guestfish

If you have a downloaded qcow2 and want to inject a key before importing:

```bash
# Requires libguestfs
guestfish --rw -a nixos-dev.qcow2 -i <<'EOF'
  mkdir-p /home/nathan/.ssh
  write /home/nathan/.ssh/authorized_keys "ssh-ed25519 AAAA...your_key... nathan@macair\n"
  chown 1000 100 /home/nathan/.ssh
  chown 1000 100 /home/nathan/.ssh/authorized_keys
  chmod 0700 /home/nathan/.ssh
  chmod 0600 /home/nathan/.ssh/authorized_keys
EOF
```

Then serve the patched image and deploy as normal.

## Connecting to the VM

```bash
# SSH (requires a route or NodePort/LB to the VM's pod network)
ssh nathan@<vm-ip>

# Serial console via virtctl
virtctl console dev

# VNC (if you add a VNC device later)
virtctl vnc dev
```

## How it works

| File               | Purpose                                                        |
|--------------------|----------------------------------------------------------------|
| `flake.nix`        | Flake outputs: `qcow2` (image), `manifest` (YAML), `default`  |
| `qcow.nix`         | Wires `make-disk-image.nix` to produce a bootable qcow2       |
| `configuration.nix` | NixOS system config — SSH, user, packages, data disk auto-format |
| `.github/workflows/build.yml` | CI: builds on tag push, creates GitHub Release      |

### What happens at deploy time

1. `kubectl apply` creates a `DataVolume` pointing at the qcow2 URL.
2. CDI downloads the qcow2, converts it to raw, writes it onto a PVC.
3. KubeVirt boots the VM from that PVC.
4. NixOS grows the root partition to fill the PVC (`boot.growPartition` + `autoResize`).
5. On first boot, the data disk (`/dev/vdb`) is formatted ext4 and mounted at `/data`.

### Size relationship

`diskSize` in `qcow.nix` (8 GiB) is the virtual size baked into the qcow2 at build time. The PVC (`rootSize`, 20 GiB) is what CDI actually provisions. Because `boot.growPartition` and `autoResize` are enabled, NixOS resizes root to fill the PVC on first boot. The qcow2 stays small for faster builds and downloads.

## Building from macOS

`nix build .#qcow2` produces a Linux derivation. From macOS you need a Linux builder:

- **nix-darwin linux-builder** (built-in): enable `nix.linux-builder.enable = true;` in your darwin config
- **Remote builder**: `ssh://nixbuild@some-linux-host` added to `/etc/nix/machines`
- **GitHub Actions**: just push a tag and let CI handle it

## Persistent data

The `/data` disk is created via `dataVolumeTemplates` in the `VirtualMachine` spec. This means **it gets deleted when you delete the VM**. If you want `/data` to survive VM deletion, pull it out into a standalone `DataVolume` and reference it by name in the VM's volumes.
