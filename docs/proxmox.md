# Proxmox VE: Intel iGPU for ollarc-intel

**Recommendation: an LXC container with `/dev/dri` passed through.**

| | LXC (recommended) | VM with iGPU passthrough |
|---|---|---|
| Effort | 2 lines of config | IOMMU, VFIO, blacklisting, often a ROM file |
| Overhead | practically none | small |
| RAM | shared dynamically, which matters because the iGPU uses system RAM | fixed allocation to the VM |
| iGPU usable in parallel (host, Jellyfin, …) | yes | no, exclusive |
| Isolation | container | full |

GVT-g (shared vGPU) no longer exists on Meteor Lake / Arrow Lake. SR-IOV for the
iGPU is still experimental on these generations, so LXC is the pragmatic way.

---

## Option A: LXC (recommended)

### 1. Check the host

```bash
ls -l /dev/dri                       # card1 + renderD128 should exist
getent group render video            # note the GIDs (Proxmox/Debian: video=44, render=993/104)
uname -r                             # Proxmox VE 9: kernel >= 6.14 supports Arrow Lake-H
lspci -nnk -s 00:02.0 | grep "driver in use"   # must be i915 or xe, NOT vfio-pci
```

If `/dev/dri` is missing, the i915/xe driver is usually not loaded
(`dmesg | grep -iE 'i915|xe '`). If the driver in use is `vfio-pci`, see
[Coming from a VM with iGPU passthrough](#coming-from-a-vm-with-igpu-passthrough).
You do **not** need to install anything from oneAPI on the host.

### 2. Create the container

Use a Debian 13 or Ubuntu 24.04/26.04 template. An **unprivileged** container is enough.

- CPU: all cores (e.g. 16 on a 285H)
- RAM: be generous. The model lives in system RAM, which the iGPU shares.
  At least 16 GB for 8B models, more for 14B–32B.
- Disk: ≥ 60 GB (models + images)

### 3. Pass the GPU through

Proxmox ≥ 8.2 can pass devices through directly. In the GUI go to
*Container → Resources → Add → Device Passthrough*, or edit
`/etc/pve/lxc/<CTID>.conf`:

```ini
features: nesting=1,keyctl=1
dev0: /dev/dri/renderD128,gid=993
dev1: /dev/dri/card1,gid=44
```

`gid=` is the GID of the group **inside the container** (`render` and `video`).
Docker inside LXC needs `nesting=1` + `keyctl=1`.

### 4. Inside the container

```bash
apt update && apt install -y curl git
curl -fsSL https://get.docker.com | sh

# is the GPU visible?
ls -l /dev/dri

git clone https://github.com/Dosperado74/ollarc-intel && cd ollarc-intel
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" > .env
docker compose up -d
docker compose logs ollama | grep -iE 'ollarc|sycl|inference compute'
```

The logs should contain a line like
`inference compute ... library=SYCL ... description="Intel(R) Arc(TM) ..."`.

---

## Coming from a VM with iGPU passthrough

If a VM used to own the iGPU, the host has it bound to `vfio-pci` and an LXC will
not see `/dev/dri`. To give it back to the host:

```bash
# 1. remove the GPU from the VM (or delete the VM)
grep hostpci /etc/pve/qemu-server/*.conf
qm set <VMID> --delete hostpci0

# 2. stop blacklisting the Intel GPU drivers (backup is written to .bak)
sed -i.bak -E '/^blacklist (i915|xe)$/d' /etc/modprobe.d/pve-blacklist.conf

# 3. drop the vfio binding for the iGPU (check the file first if other devices use vfio)
cat /etc/modprobe.d/vfio.conf
mv /etc/modprobe.d/vfio.conf /root/vfio.conf.bak

# 4. rebuild initramfs and reboot (restarts all guests)
update-initramfs -u -k all
reboot

# 5. verify
lspci -nnk -s 00:02.0 | grep "driver in use"   # -> i915 or xe
ls -l /dev/dri                                 # -> card1, renderD128
```

`intel_iommu=on` on the kernel command line can stay; it does no harm.

---

## Option B: VM with the whole iGPU (only if you need it)

Short version. The iGPU is gone from the host afterwards:

1. BIOS: enable VT-d.
2. `/etc/kernel/cmdline` (or GRUB): `intel_iommu=on iommu=pt`, then `proxmox-boot-tool refresh`.
3. `/etc/modprobe.d/pve-blacklist.conf`: `blacklist i915` and `blacklist xe`;
   `/etc/modprobe.d/vfio.conf`: `options vfio-pci ids=8086:<device-id>` (`lspci -nn | grep VGA`).
4. `update-initramfs -u -k all`, reboot.
5. VM: machine `q35`, BIOS `OVMF (UEFI)`, PCI device `0000:00:02.0` with *All Functions*
   and *PCI-Express*, Primary GPU **off**. Meteor/Arrow Lake often need a matching
   IGD ROM (`romfile=`); without it the GPU stays black or driverless in the VM.
6. In the VM: Ubuntu 26.04 and Docker, then continue with step 4 above.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `no /dev/dri/renderD* device` | `devices:`/`dev0:` missing or wrong path (sometimes `renderD129`) |
| host has no `/dev/dri`, driver is `vfio-pci` | the iGPU is still reserved for passthrough, see above |
| `Permission denied` on `/dev/dri/renderD128` | `RENDER_GID` does not match the GID of `renderD128` inside the container |
| `library=cpu` in the logs | run `docker compose exec ollama sycl-ls`; if it lists no `level_zero:gpu`, the container cannot reach the GPU |
| first model load is slow | one-time JIT compilation of the SYCL kernels for that model |
| model outputs `GGGG…` or loops endlessly | you run an old `latest-arl-h` (AOT) image: `docker compose pull` (AOT kernels break models > 4 GB) |
| OOM / container gets killed | raise the LXC RAM limit, because iGPU memory counts as RAM |
