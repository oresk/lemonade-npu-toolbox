#!/bin/bash
# Install lemonade-npu stack inside a fresh Ubuntu 24.04 LXC/container.
# Validated clean on Proxmox 8, kernel 7.0.0-8-pve, 2026-04-14.
#
# Usage:
#   bash install.sh
#   bash install.sh 0.9.38 10.2.0   # pin FLM and lemonade-server versions

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

FLM_VERSION="${1:-0.9.38}"
LEMONADE_SERVER_VERSION="${2:-10.2.0}"

echo "==> FastFlowLM ${FLM_VERSION}  |  lemonade-server ${LEMONADE_SERVER_VERSION}"

# ── 1. Base packages + AMD XRT PPA + FastFlowLM ──────────────────────────────
# FastFlowLM depends on libavcodec60 etc. from the Ubuntu universe repo.
# These must be resolved while apt lists are still live — do NOT clear lists
# between XRT and FastFlowLM installs.
apt-get update -q
apt-get install -y --no-install-recommends \
  software-properties-common curl ca-certificates \
  python3-pip python3 rpm2cpio cpio libwebsockets-dev
add-apt-repository -y ppa:amd-team/xrt
apt-get update -q
apt-get install -y --no-install-recommends libxrt-npu2 libxrt-utils-npu
curl -fsSL -o /tmp/fastflowlm.deb \
  "https://github.com/FastFlowLM/FastFlowLM/releases/download/v${FLM_VERSION}/fastflowlm_${FLM_VERSION}_ubuntu24.04_amd64.deb"
apt-get install -y --no-install-recommends /tmp/fastflowlm.deb
rm /tmp/fastflowlm.deb
rm -rf /var/lib/apt/lists/*

# ── 2. libwebsockets.so.20 symlink ───────────────────────────────────────────
# Ubuntu 24.04 ships .so.19; lemonade-server requires .so.20.
# ABI is compatible within the 4.x series.
ln -sf /lib/x86_64-linux-gnu/libwebsockets.so.19 \
       /lib/x86_64-linux-gnu/libwebsockets.so.20
ldconfig

# ── 3. Lemonade Server (C++) ─────────────────────────────────────────────────
# Ships as RPM only (no .deb). Extract and install binaries + resources.
# resources/ must sit next to lemonade-server (path is relative to executable).
# v10.2.0+: binaries are lemonade, lemonade-server, lemonade-web-app, lemond
curl -fsSL -o /tmp/lemonade-server.rpm \
  "https://github.com/lemonade-sdk/lemonade/releases/download/v${LEMONADE_SERVER_VERSION}/lemonade-server-${LEMONADE_SERVER_VERSION}.x86_64.rpm"
cd /tmp && rpm2cpio /tmp/lemonade-server.rpm | cpio -idm 2>/dev/null || true
cp /tmp/opt/bin/lemonade /tmp/opt/bin/lemonade-server /usr/local/bin/
cp -f /tmp/opt/bin/lemonade-web-app /tmp/opt/bin/lemond /usr/local/bin/ 2>/dev/null || true
chmod +x /usr/local/bin/lemonade /usr/local/bin/lemonade-server
cp -a /tmp/opt/share/lemonade-server/resources /usr/local/bin/resources
mkdir -p /etc/lemonade/conf.d
cp -a /tmp/etc/lemonade/conf.d/. /etc/lemonade/conf.d/ 2>/dev/null || true
mkdir -p /opt/var/lib/lemonade
rm -rf /tmp/opt /tmp/etc /tmp/lemonade-server.rpm

# ── 4. Lemonade SDK (Python CLI tools) ───────────────────────────────────────
pip3 install --break-system-packages lemonade-sdk

# ── 5. Environment ───────────────────────────────────────────────────────────
grep -q 'usr/local/bin' /etc/environment 2>/dev/null || \
  echo 'PATH="/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"' >> /etc/environment

export PATH="/usr/local/bin:${PATH}"
export FLM_MODEL_PATH="${FLM_MODEL_PATH:-/mnt/models}"

# ── Validate ─────────────────────────────────────────────────────────────────
echo ""
flm validate
echo ""
lemonade --version
echo ""
echo "Done. Start the server with:"
echo "  FLM_MODEL_PATH=/mnt/models/NPU-models lemond"
