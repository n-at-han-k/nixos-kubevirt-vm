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
