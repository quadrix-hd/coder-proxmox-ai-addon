#!/bin/bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo "jq ist nicht installiert (siehe README, Abschnitt Prerequisites)" >&2
  exit 1
}

INPUT=$(cat)
API_URL=$(echo "$INPUT" | jq -r '.api_url')
TOKEN_ID=$(echo "$INPUT" | jq -r '.token_id')
TOKEN_SECRET=$(echo "$INPUT" | jq -r '.token_secret')
TLS_INSECURE=$(echo "$INPUT" | jq -r '.tls_insecure // "false"')

CURL_OPTS=(-s)
[ "$TLS_INSECURE" = "true" ] && CURL_OPTS+=(-k)

RESPONSE=$(curl "${CURL_OPTS[@]}" "${API_URL}/nodes" \
  -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}")

# Proxmox liefert {"data":[{"node":"pve","mem":123,"maxmem":456,...}, ...]}.
# Ergebnis wird nach Auslastung aufsteigend sortiert, dadurch ist der erste
# Eintrag automatisch der am wenigsten ausgelastete Knoten (= Default).
NODES_JSON=$(echo "$RESPONSE" | jq -c '
  [.data[]
    | select(.mem != null and .maxmem != null and .maxmem > 0)
    | {name: .node, load: ((.mem / .maxmem * 100 * 10 | round) / 10)}
  ] | sort_by(.load)
' 2>/dev/null || echo "")

if [ -z "$NODES_JSON" ] || [ "$NODES_JSON" = "[]" ] || [ "$NODES_JSON" = "null" ]; then
  echo "Keine (verwertbaren) Knotendaten von der Proxmox-API erhalten. Antwort war: $RESPONSE" >&2
  exit 1
fi

DEFAULT_NODE=$(echo "$NODES_JSON" | jq -r '.[0].name')

jq -n --arg nodes "$NODES_JSON" --arg default_node "$DEFAULT_NODE" \
  '{nodes_json: $nodes, default_node: $default_node}'
