#!/bin/bash
set -euo pipefail

# Reserviert eine IP atomar ueber Proxmox SDN + IPAM statt sie nur "frei zu
# raten": POST /nodes/{node}/network/sdn/ips ruft im PVE-Kern letztlich
# PVE::Network::SDN::Ipams::PVEPlugin::add_ip auf, das die IPAM-Datenbank
# per cfs_lock_file sperrt, auf ein bereits belegtes "ip" mit
# 'die "IP already exist"' abbricht und erst dann committet. Zwei
# gleichzeitige Aufrufe fuer dieselbe IP koennen sich damit nicht mehr in
# die Quere kommen (anders als beim reinen Ist-Abfrage-Ansatz in
# find_free_ip.sh). Setzt eine vorbereitete SDN Zone/VNet/Subnet mit dem
# eingebauten "pve"-IPAM voraus, siehe README ("SDN + IPAM").

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
NODE=$(echo "$INPUT" | jq -r '.node')
ZONE=$(echo "$INPUT" | jq -r '.zone')
VNET=$(echo "$INPUT" | jq -r '.vnet')
AUTH_HEADER="Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}"

CURL_OPTS=(-s)
[ "$TLS_INSECURE" = "true" ] && CURL_OPTS+=(-k)

if [ -z "$ZONE" ] || [ -z "$VNET" ]; then
  echo "sdn_zone/sdn_vnet sind nicht gesetzt (siehe README, Abschnitt 'SDN + IPAM')" >&2
  exit 1
fi

random_mac() {
  # Locally administered, unicast MAC (I/G-Bit=0, U/L-Bit=1) - erstes Oktett "02",
  # passend zur Anforderung des telmate/proxmox-Providers fuer network.hwaddr.
  printf '02'
  for _ in 1 2 3 4 5; do
    printf ':%02x' "$((RANDOM % 256))"
  done
}

for i in $(seq "$START" "$END"); do
  IP="${SUBNET}.${i}"
  MAC=$(random_mac)

  HTTP_RESPONSE=$(curl "${CURL_OPTS[@]}" -w '\n%{http_code}' -X POST \
    "${API_URL}/nodes/${NODE}/network/sdn/ips" \
    -H "$AUTH_HEADER" \
    --data-urlencode "zone=${ZONE}" \
    --data-urlencode "vnet=${VNET}" \
    --data-urlencode "mac=${MAC}" \
    --data-urlencode "ip=${IP}")

  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
  BODY=$(echo "$HTTP_RESPONSE" | sed '$d')

  if [ "$HTTP_CODE" -ge 200 ] 2>/dev/null && [ "$HTTP_CODE" -lt 300 ] 2>/dev/null; then
    jq -n --arg ip "$IP" --arg mac "$MAC" '{ip: $ip, mac: $mac}'
    exit 0
  fi

  if echo "$BODY" | grep -qi "already exist"; then
    continue
  fi

  echo "Proxmox-API-Fehler beim Reservieren von ${IP} (HTTP ${HTTP_CODE}): $BODY" >&2
  exit 1
done

echo "Keine freie IP im Bereich ${SUBNET}.${START}-${END} in Zone/VNet ${ZONE}/${VNET} reservierbar" >&2
exit 1
