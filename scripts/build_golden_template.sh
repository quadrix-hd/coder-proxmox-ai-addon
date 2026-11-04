#!/bin/bash
# Baut ein "goldenes" LXC-Template mit vorinstalliertem Docker + Claude Code,
# damit neue Workspaces diese Downloads nicht jedes Mal neu machen muessen.
#
# Auf einem Proxmox-Node als root ausfuehren. Ergebnis landet auf dem Storage
# OUT_STORAGE (Default: local = nur dieser Node). Mit einem geteilten Storage
# wie CephFS (Inhaltstyp "Container template" aktiviert) sehen es alle Nodes,
# z.B. OUT_STORAGE=cephfs.
#
# Alle Einstellungen per Umgebungsvariable, z.B.:
#   OUT_STORAGE=cephfs STORAGE=vm-pool NET_IP=10.0.75.99/24 NET_GW=10.0.75.1 VLAN_TAG=75 ./build_golden_template.sh
set -euo pipefail

BASE_TEMPLATE="${BASE_TEMPLATE:-local:vztmpl/ubuntu-ssh-ready.tar.zst}"
OUT_NAME="${OUT_NAME:-ubuntu-golden.tar.zst}"
OUT_STORAGE="${OUT_STORAGE:-local}"
VMID="${VMID:-9999}"
STORAGE="${STORAGE:-local-lvm}"
BRIDGE="${BRIDGE:-vmbr0}"
VLAN_TAG="${VLAN_TAG:-}"
NET_IP="${NET_IP:-dhcp}"
NET_GW="${NET_GW:-}"

# Zielverzeichnis des Storages fuer vztmpl-Inhalte direkt von Proxmox
# erfragen (local -> /var/lib/vz/template/cache, CephFS -> /mnt/pve/<id>/...).
CACHE_DIR=$(dirname "$(pvesm path "$OUT_STORAGE:vztmpl/$OUT_NAME")")
mkdir -p "$CACHE_DIR"

if pct status "$VMID" >/dev/null 2>&1; then
  echo "VMID $VMID ist schon belegt - andere VMID per VMID=... waehlen." >&2
  exit 1
fi

NET0="name=eth0,bridge=$BRIDGE,ip=$NET_IP"
[ -n "$NET_GW" ] && NET0="$NET0,gw=$NET_GW"
[ -n "$VLAN_TAG" ] && NET0="$NET0,tag=$VLAN_TAG"

cleanup() { pct stop "$VMID" >/dev/null 2>&1 || true; pct destroy "$VMID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> Build-Container $VMID aus $BASE_TEMPLATE erstellen"
pct create "$VMID" "$BASE_TEMPLATE" \
  --hostname golden-build --unprivileged 1 --features nesting=1 \
  --cores 2 --memory 2048 --rootfs "$STORAGE:8" --net0 "$NET0"
pct start "$VMID"

echo "==> Auf Netzwerk warten"
for _ in $(seq 1 30); do
  pct exec "$VMID" -- bash -c 'getent hosts get.docker.com >/dev/null' && break
  sleep 2
done

echo "==> Docker + Claude Code installieren"
pct exec "$VMID" -- bash -c '
  set -e
  # pct exec setzt HOME nicht zuverlaessig auf /root - der Claude-Installer
  # legt claude aber unter $HOME/.local/bin ab, und der Coder-Agent laeuft
  # spaeter als root mit HOME=/root.
  export HOME=/root
  export LC_ALL=C.UTF-8
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y curl sudo git ca-certificates jq python3
  curl -fsSL https://get.docker.com | sh
  useradd -m -s /bin/bash coder 2>/dev/null || true
  usermod -aG docker coder
  curl -fsSL https://claude.ai/install.sh | bash
  ln -sf /root/.local/bin/claude /usr/local/bin/claude
  /usr/local/bin/claude --version
  # Aufraeumen: Paketcache weg, machine-id leeren (jede Kopie bekommt beim
  # ersten Boot eine eigene). SSH-Hostkeys erzeugt Proxmox bei pct create
  # fuer jeden neuen Container ohnehin neu.
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /root/.cache
  truncate -s0 /etc/machine-id
'

echo "==> Container stoppen und als Template-Archiv sichern"
pct stop "$VMID"
TMPDUMP=$(mktemp -d)
vzdump "$VMID" --mode stop --compress zstd --dumpdir "$TMPDUMP"
DUMPFILE=$(ls -t "$TMPDUMP"/vzdump-lxc-"$VMID"-*.tar.zst | head -n1)

if [ -f "$CACHE_DIR/$OUT_NAME" ]; then
  mv "$CACHE_DIR/$OUT_NAME" "$CACHE_DIR/$OUT_NAME.bak"
  echo "    (vorherige Version gesichert als $OUT_NAME.bak)"
fi
mv "$DUMPFILE" "$CACHE_DIR/$OUT_NAME"
rm -rf "$TMPDUMP"

echo
echo "Fertig: $OUT_STORAGE:vztmpl/$OUT_NAME"
echo "In terraform.tfvars:"
echo "  lxc_template      = \"$OUT_STORAGE:vztmpl/$OUT_NAME\""
echo "  prebaked_template = \"true\""
