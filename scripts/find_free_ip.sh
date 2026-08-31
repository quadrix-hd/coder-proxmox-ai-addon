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
#
# Fail closed statt fail open: wenn die Resource-Liste oder eine einzelne
# Guest-Config nicht (vollstaendig) abgerufen/geparst werden kann, brechen
# wir ab statt eine IP zu vergeben, die in Wirklichkeit schon belegt sein
# koennte. -f laesst curl bei HTTP-Fehlern fehlschlagen (statt eine
# Fehler-Seite als "Erfolg" durchzureichen); die Guest-Liste wird in einer
# normalen Variable statt einer Process-Substitution erfasst, damit ein
# jq-Fehler (z.B. .data ist null) von "set -e" auch tatsaechlich erkannt wird.
RESOURCES=$(curl "${CURL_OPTS[@]}" -f "${API_URL}/cluster/resources?type=vm" -H "$AUTH_HEADER")

if ! echo "$RESOURCES" | jq -e '.data | type == "array"' >/dev/null 2>&1; then
  echo "Unerwartete Antwort von ${API_URL}/cluster/resources: $RESOURCES" >&2
  exit 1
fi

GUEST_LIST=$(echo "$RESOURCES" | jq -r '.data[] | select(.type=="lxc" or .type=="qemu") | "\(.node)\t\(.vmid)\t\(.type)"')

USED_IPS=""
while IFS=$'\t' read -r NODE VMID TYPE; do
  [ -z "$NODE" ] && continue
  if ! CONFIG=$(curl "${CURL_OPTS[@]}" -f "${API_URL}/nodes/${NODE}/${TYPE}/${VMID}/config" -H "$AUTH_HEADER"); then
    echo "Konnte Config von ${TYPE} ${VMID} auf Node ${NODE} nicht abrufen - breche ab statt mit unvollstaendigen Daten eine IP zu vergeben" >&2
    exit 1
  fi
  FOUND=$(echo "$CONFIG" | grep -oE "ip=${SUBNET_RE}\.[0-9]+" | cut -d= -f2 || true)
  USED_IPS="${USED_IPS}
${FOUND}"
done <<< "$GUEST_LIST"

for i in $(seq "$START" "$END"); do
  IP="${SUBNET}.${i}"
  if ! echo "$USED_IPS" | grep -qx "$IP"; then
    jq -n --arg ip "$IP" '{ip: $ip}'
    exit 0
  fi
done

echo "Keine freie IP im Bereich ${SUBNET}.${START}-${END} gefunden (laut Proxmox-Konfigurationen)" >&2
exit 1
