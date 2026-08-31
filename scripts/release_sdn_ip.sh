#!/bin/bash
set -euo pipefail

# Gibt eine ueber allocate_sdn_ip.sh reservierte IP beim Zerstoeren des
# Workspaces wieder frei (DELETE /nodes/{node}/network/sdn/ips). Wird von
# main.tf als local-exec-Provisioner mit when=destroy aufgerufen, Parameter
# kommen als Umgebungsvariablen (nicht als stdin-JSON wie bei den
# "external"-Data-Source-Skripten).
#
# Ein Fehlschlag hier soll ein "terraform destroy" nicht blockieren -
# im schlimmsten Fall bleibt ein verwaister IPAM-Eintrag zurueck, der
# manuell in Proxmox (Datacenter > SDN > IPAM) bereinigt werden kann.

: "${API_URL:?}" "${TOKEN_ID:?}" "${TOKEN_SECRET:?}" "${NODE:?}" "${ZONE:?}" "${VNET:?}" "${IP:?}" "${MAC:?}"

CURL_OPTS=(-s)
[ "${TLS_INSECURE:-false}" = "true" ] && CURL_OPTS+=(-k)

AUTH_HEADER="Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}"

if ! curl "${CURL_OPTS[@]}" -X DELETE \
  "${API_URL}/nodes/${NODE}/network/sdn/ips" \
  -H "$AUTH_HEADER" \
  --data-urlencode "zone=${ZONE}" \
  --data-urlencode "vnet=${VNET}" \
  --data-urlencode "mac=${MAC}" \
  --data-urlencode "ip=${IP}" >/tmp/sdn-ip-release.log 2>&1; then
  echo "Warnung: IPAM-Freigabe fuer ${IP} (${MAC}) fehlgeschlagen - ggf. manuell in Proxmox unter Datacenter > SDN > IPAM bereinigen" >&2
fi

exit 0
