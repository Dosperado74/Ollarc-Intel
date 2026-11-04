# Proxmox VE: Intel iGPU für ollarc-intel

**Empfehlung: LXC-Container mit durchgereichtem `/dev/dri`.**

| | LXC (empfohlen) | VM mit iGPU-Passthrough |
|---|---|---|
| Aufwand | 2 Zeilen Config | IOMMU, VFIO, Blacklisting, oft ROM-File |
| Overhead | praktisch keiner | gering |
| RAM | dynamisch geteilt – wichtig, weil die iGPU System-RAM nutzt | fest der VM zugeteilt |
| iGPU parallel nutzbar (Host, Jellyfin, …) | ja | nein, exklusiv |
| Isolation | Container | voll |

GVT-g (geteilte vGPU) gibt es ab Meteor Lake/Arrow Lake nicht mehr. SR-IOV für die
iGPU ist auf diesen Generationen noch experimentell – LXC ist der pragmatische Weg.

---

## Variante A: LXC (empfohlen)

### 1. Host prüfen

```bash
ls -l /dev/dri                       # card1 + renderD128 sollten existieren
getent group render video            # GIDs merken (Proxmox/Debian: video=44, render=993/104)
uname -r                             # Proxmox VE 9: Kernel >= 6.14 unterstützt Arrow Lake-H
```

Fehlt `/dev/dri`, ist meist der i915/xe-Treiber nicht geladen
(`dmesg | grep -iE 'i915|xe '`). Auf dem Host muss **nichts** von oneAPI installiert werden.

### 2. Container anlegen

Debian 13 oder Ubuntu 24.04/26.04 Template, **unprivilegiert** reicht.

- CPU: alle Kerne (z. B. 16 beim 285H)
- RAM: großzügig – das Modell liegt im System-RAM, den die iGPU mitnutzt.
  Für 8B-Modelle mind. 16 GB, für 14B–32B entsprechend mehr.
- Disk: ≥ 60 GB (Modelle + Images)

### 3. GPU durchreichen

Proxmox ≥ 8.2 kann Geräte direkt durchreichen – in der GUI unter
*Container → Resources → Add → Device Passthrough* oder in
`/etc/pve/lxc/<CTID>.conf`:

```ini
features: nesting=1,keyctl=1
dev0: /dev/dri/renderD128,gid=993
dev1: /dev/dri/card1,gid=44
```

`gid=` ist die GID der Gruppe **im Container** (`render` bzw. `video`).
`nesting=1` + `keyctl=1` werden für Docker im LXC benötigt.

### 4. Im Container

```bash
apt update && apt install -y curl
curl -fsSL https://get.docker.com | sh

# GPU sichtbar?
ls -l /dev/dri

git clone https://github.com/Dosperado74/ollarc-intel && cd ollarc-intel
echo "RENDER_GID=$(stat -c %g /dev/dri/renderD128)" > .env
# nur bei Core Ultra 200H (Arrow Lake-H, z. B. 285H/255H):
# echo "OLLARC_TAG=latest-arl-h" >> .env
docker compose up -d
docker compose logs ollama | grep -iE 'ollarc|sycl|inference compute'
```

In den Logs sollte eine Zeile wie
`inference compute ... library=SYCL ... description="Intel(R) Arc(TM) ..."` erscheinen.

---

## Variante B: VM mit kompletter iGPU (nur wenn nötig)

Kurzfassung – die iGPU ist danach für den Host weg:

1. BIOS: VT-d an.
2. `/etc/kernel/cmdline` (bzw. GRUB): `intel_iommu=on iommu=pt`, dann `proxmox-boot-tool refresh`.
3. `/etc/modprobe.d/blacklist-igpu.conf`: `blacklist i915` und `blacklist xe`;
   `/etc/modprobe.d/vfio.conf`: `options vfio-pci ids=8086:<device-id>` (`lspci -nn | grep VGA`).
4. `update-initramfs -u -k all`, reboot.
5. VM: Maschine `q35`, BIOS `OVMF (UEFI)`, PCI-Gerät `0000:00:02.0` mit *All Functions*
   und *PCI-Express*, Primary GPU **aus**. Bei Meteor/Arrow Lake wird oft ein passendes
   IGD-ROM benötigt (`romfile=`), sonst bleibt die GPU in der VM schwarz/ohne Treiber.
6. In der VM: Ubuntu 26.04, Docker, dann wie oben ab Schritt 4.

---

## Troubleshooting

| Symptom | Ursache / Lösung |
|---|---|
| `no /dev/dri/renderD* device` | `devices:`/`dev0:` fehlt oder falscher Pfad (manchmal `renderD129`) |
| `Permission denied` auf `/dev/dri/renderD128` | `RENDER_GID` stimmt nicht mit der GID von `renderD128` im Container überein |
| `library=cpu` in den Logs | `docker compose exec ollama sycl-ls` – listet es keine `level_zero:gpu`, kommt der Container nicht an die GPU |
| Erster Modellstart dauert lange | JIT-Kompilierung der SYCL-Kernels; `latest-arl-h` (AOT) vermeiden das auf Arrow Lake-H |
| OOM / Container wird gekillt | LXC-RAM-Limit erhöhen – iGPU-Speicher zählt zum RAM |
