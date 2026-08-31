#!/bin/bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "jq ist nicht installiert (siehe README, Abschnitt Prerequisites)" >&2
  exit 1
}

INPUT=$(cat)
SUBNET=$(echo "$INPUT" | jq -r '.subnet')
START=$(echo "$INPUT" | jq -r '.range_start')
END=$(echo "$INPUT" | jq -r '.range_end')
API_URL=$(echo "$INPUT" | jq -r '.api_url')
TOKEN_ID=$(echo "$INPUT" | jq -r '.token_id')
TOKEN_SECRET=$(echo "$INPUT" | jq -r '.token_secret')
TLS_INSECURE=$(echo "$INPUT" | jq -r '.tls_insecure // "false"')
AUTH_HEADER="Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}"
SUBNET_RE="${SUBNET//./\\.}"

CURL_OPTS=(-s)
[ "$TLS_INSECURE" = "true" ] && CURL_OPTS+=(-k)

# Statt Ping-Sweep: die tatsaechlich in Proxmox konfigurierten IPs aller
# VMs/LXCs im Cluster auslesen. Erkennt auch gestoppte Container (die auf
# Ping nicht antworten wuerden, ihre IP aber weiterhin "besitzen").
RESOURCES=$(curl "${CURL_OPTS[@]}" "${API_URL}/cluster/resources?type=vm" -H "$AUTH_HEADER")

USED_IPS=""
while IFS=$'\t' read -r NODE VMID TYPE; do
  [ -z "$NODE" ] && continue
  CONFIG=$(curl "${CURL_OPTS[@]}" "${API_URL}/nodes/${NODE}/${TYPE}/${VMID}/config" -H "$AUTH_HEADER" || true)
  FOUND=$(echo "$CONFIG" | grep -oE "ip=${SUBNET_RE}\.[0-9]+" | cut -d= -f2 || true)
  USED_IPS="${USED_IPS}
${FOUND}"
done < <(echo "$RESOURCES" | jq -r '.data[] | select(.type=="lxc" or .type=="qemu") | "\(.node)\t\(.vmid)\t\(.type)"')

for i in $(seq "$START" "$END"); do
  IP="${SUBNET}.${i}"
  if ! echo "$USED_IPS" | grep -qx "$IP"; then
    jq -n --arg ip "$IP" '{ip: $ip}'
    exit 0
  fi
done

echo "Keine freie IP im Bereich ${SUBNET}.${START}-${END} gefunden (laut Proxmox-Konfigurationen)" >&2
exit 1
