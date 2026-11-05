# Host setup without Proxmox

ollarc-intel runs on any Linux host with Docker. The container brings the complete Intel
GPU user space (oneAPI, Level Zero, compute runtime). The **host** only needs the kernel
driver and the GPU firmware.

Proxmox VE already ships both (kernel `i915`/`xe`, firmware in `pve-firmware`); for
Proxmox follow [proxmox.md](proxmox.md) instead.

## 1. Kernel

Meteor Lake and Lunar Lake need Linux 6.8 or newer, Arrow Lake Linux 6.11 or newer; a
current distribution kernel is recommended. Dedicated Arc cards: A-series ≥ 6.2,
B-series ≥ 6.12, plus Resizable BAR, see [arc-dgpu.md](arc-dgpu.md).

```bash
uname -r
```

## 2. GPU firmware

Since Meteor Lake the GPU needs its GuC firmware; without it no compute work runs and
`sycl-ls` finds no GPU.

| Distribution | Package |
|---|---|
| **Debian 13** | `firmware-intel-graphics` (component `non-free-firmware`) |
| **Debian 12** | `firmware-misc-nonfree` (component `non-free-firmware`) |
| **Ubuntu** | `linux-firmware` (usually installed) |
| **Fedora** | `linux-firmware` (usually installed) |

Debian: enable `non-free-firmware` in `/etc/apt/sources.list` (or the `.sources` file),
then:

```bash
sudo apt update
sudo apt install firmware-intel-graphics        # Debian 13
# sudo apt install firmware-misc-nonfree        # Debian 12
sudo update-initramfs -u -k all
sudo reboot
```

## 3. Check

```bash
lspci -nnk -d ::0300 | grep -A3 -i intel        # "Kernel driver in use: i915" (or xe)
ls -l /dev/dri                                  # card* and renderD128
sudo dmesg | grep -iE "guc|huc" | head          # GuC firmware ... loaded / version
```

## 4. Docker and ollarc-intel

```bash
curl -fsSL https://get.docker.com | sh
git clone https://github.com/Dosperado74/ollarc-intel && cd ollarc-intel
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" > .env
docker compose up -d
```

Then continue with the README (*Quick start*). If the GPU is not detected, see
[diagnostics.md](diagnostics.md).
