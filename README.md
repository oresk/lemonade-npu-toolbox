# lemonade-npu-toolbox

Container image for running [Lemonade Server](https://github.com/lemonade-sdk/lemonade) + [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) on the AMD XDNA2 NPU (Strix Halo).

The NPU counterpart to the GPU toolboxes at [strix-halo-toolboxes.com](https://strix-halo-toolboxes.com/) / [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) — same concept, ready-to-run container — but targeting `/dev/accel` instead of `/dev/dri`/`/dev/kfd`.

**Tested on:** AMD Ryzen AI MAX+ 395 (Strix Halo, XDNA2), Proxmox 8, kernel `7.0.0-8-pve` (jaminmc), Ubuntu 24.04 LXC.

## Stack

| Component | Version | Role |
|---|---|---|
| [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM) | 0.9.36 | NPU-native LLM runtime (~52 tok/s @ 16K ctx) |
| [lemonade-router](https://github.com/lemonade-sdk/lemonade) | 10.0.1 | C++ OpenAI-compatible API server |
| [lemonade-sdk](https://github.com/lemonade-sdk/lemonade) | 9.1.4 | Python CLI tools (`flm-load`, `lemonade-install`) |
| AMD XRT NPU | 2.21.75 | Userspace NPU runtime (`libxrt-npu2`) |
| Base | Ubuntu 24.04 | AMD PPA only ships for Ubuntu |

**vs GPU inference:**

| | GPU ([kyuz0 toolbox](https://github.com/kyuz0/amd-strix-halo-toolboxes)) | NPU (this) |
|---|---|---|
| Speed | ~200+ tok/s (Vulkan) | ~52 tok/s |
| Power | ~60–80 W | ~5–15 W |
| Device | `/dev/dri`, `/dev/kfd` | `/dev/accel/accel0` |
| Kernel | ≥ 6.18.6 | jaminmc 7.0.0-8-pve |

---

## Host requirements

These must be satisfied on the **host** before the container will work. They cannot be fixed from inside the container.

### 1. Kernel — jaminmc v7

The stock Proxmox kernel ships an `amdxdna` driver incompatible with the Strix Halo `17f0` firmware. The jaminmc v7 kernel (`amdxdna` 0.7.0) is required.

- Repo: [github.com/jaminmc/pve-kernel](https://github.com/jaminmc/pve-kernel)
- Tested: `7.0.0-8-pve`

Verify after install:

```bash
uname -r                  # 7.0.0-8-pve
ls /dev/accel/            # accel0
dmesg | grep xdna         # [drm] Initialized amdxdna_accel_driver 0.7.0
```

### 2. NPU firmware ≥ 1.1.0.0

File: `/lib/firmware/amdnpu/17f0_11/npu_7.sbin`, version ≥ 1.1.0.0 (1.1.2.65 confirmed working). Ships with `amdxdna-dkms` from `ppa:amd-team/xrt`.

```bash
dmesg | grep "Load firmware"
# Expected: amdxdna 0000:c6:00.1: [drm] Load firmware amdnpu/17f0_11/npu_7.sbin
```

### 3. IOMMU passthrough

The NPU uses SVA (Shared Virtual Addressing) — requires `iommu=pt`. With `iommu=off` the driver loads but every open call returns `-ENODEV`.

`/etc/default/grub`:
```
GRUB_CMDLINE_LINUX="... iommu=pt"
```

Then `update-grub && reboot`.

### 4. Device permissions

```bash
# /etc/udev/rules.d/99-amdxdna.rules
SUBSYSTEM=="accel", KERNEL=="accel0", MODE="0666"
```

```bash
udevadm control --reload && udevadm trigger
# Verify: ls -la /dev/accel/accel0  →  crw-rw-rw- ... 261, 0
```

---

## Proxmox LXC 

This is the validated path — tested clean from scratch.

### Create the container

```bash
pct create 103 local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst \
  --hostname lemonade \
  --arch amd64 \
  --cores 32 \
  --memory 122880 \
  --swap 512 \
  --rootfs local-lvm:50 \
  --mp0 local-lvm:<model-disk>,mp=/mnt/models,size=900G \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,ip6=auto,type=veth \
  --ostype ubuntu \
  --timezone Europe/Zagreb \
  --unprivileged 1 \
  --features nesting=1,keyctl=1 \
  --onboot 1
```

### Add NPU passthrough to `/etc/pve/lxc/103.conf`

```
lxc.cgroup2.devices.allow: c 261:0 rwm
lxc.mount.entry: /dev/accel dev/accel none bind,optional,create=dir
lxc.idmap: u 0 100000 65536
lxc.idmap: g 0 100000 44
lxc.idmap: g 44 44 1
lxc.idmap: g 45 100045 948
lxc.idmap: g 993 993 1
lxc.idmap: g 994 100994 64542
lxc.prlimit.memlock: unlimited
```

`261:0` is the major:minor of `/dev/accel/accel0` — verify with `ls -la /dev/accel/accel0`.

### Install inside the container

```bash
pct start 103
pct exec 103 -- bash /path/to/install.sh
```

### Validate

```bash
export PATH="/usr/local/bin:$PATH"
export FLM_MODEL_PATH=/mnt/models/NPU-models

flm validate
# [Linux]  NPU: /dev/accel/accel0 with 8 columns
# [Linux]  NPU FW Version: 1.1.2.65
# [Linux]  amdxdna version: 0.7
# [Linux]  Memlock Limit: infinity

lemonade-router --version
# lemonade-router version 10.0.1
```

### Start the server

```bash
export FLM_MODEL_PATH=/mnt/models/NPU-models
lemonade-router --host 0.0.0.0 --port 8000
```

Check available models:

```bash
curl http://localhost:8000/v1/models
```

---

## OpenWebUI

In **Settings → Connections → OpenAI API**:

| Field | Value |
|---|---|
| URL | `http://<lemonade-ct-ip>:8000/v1` |
| API key | anything (not enforced) |

OpenWebUI will discover all installed NPU models automatically.

---

## Docker / Podman

```bash
podman run --rm -it \
  --device /dev/accel/accel0 \
  --ulimit memlock=-1:-1 \
  --security-opt seccomp=unconfined \
  -v /path/to/NPU-models:/mnt/models \
  -p 8000:8000 \
  ghcr.io/oresk/lemonade-npu-toolbox:latest \
  lemonade-router --host 0.0.0.0 --port 8000
```

## Toolbx (Fedora)

```bash
toolbox create --assumeyes lemonade-npu \
  --image ghcr.io/oresk/lemonade-npu-toolbox:latest \
  -- --device /dev/accel/accel0 \
     --ulimit memlock=-1:-1 \
     --security-opt seccomp=unconfined
toolbox enter lemonade-npu
```

## Distrobox

```bash
distrobox create lemonade-npu \
  --image ghcr.io/oresk/lemonade-npu-toolbox:latest \
  -- --device /dev/accel/accel0 \
     --ulimit memlock=-1:-1 \
     --security-opt seccomp=unconfined
distrobox enter lemonade-npu
```

---

## CI/CD

Images rebuild automatically when a new FastFlowLM release is detected (polled every 6 hours). Lemonade Server version is also resolved at build time from the latest GitHub release.

**Tags:**
- `latest` — latest FastFlowLM release
- `flm-<version>` — pinned to a specific FastFlowLM version
- `flm-<version>_<timestamp>` — immutable build reference

Manual build:

```bash
./refresh-toolboxes.sh           # latest FastFlowLM
./refresh-toolboxes.sh 0.9.36   # specific version
```

---

## Notes

**One NPU model at a time** — FastFlowLM holds an exclusive NPU lock while a model is loaded. Lemonade handles model switching but there is a load/unload delay between models.

**Ubuntu 24.04 only** — the AMD XRT PPA also supports Ubuntu 25.10 and 26.04, but 24.04 LTS is used here for stability.

---

## References

- [FastFlowLM](https://github.com/FastFlowLM/FastFlowLM)
- [Lemonade Server](https://github.com/lemonade-sdk/lemonade)
- [jaminmc/pve-kernel](https://github.com/jaminmc/pve-kernel)
- [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) — GPU toolbox reference
- [strix-halo-toolboxes.com](https://strix-halo-toolboxes.com/)
- [AMD XRT PPA](https://launchpad.net/~amd-team/+archive/ubuntu/xrt)
