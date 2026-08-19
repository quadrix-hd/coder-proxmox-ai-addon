#!/bin/bash
set -e
INPUT=$(cat)
SUBNET=$(echo "$INPUT" | sed -n 's/.*"subnet":"\([^"]*\)".*/\1/p')
START=$(echo "$INPUT" | sed -n 's/.*"range_start":"\([^"]*\)".*/\1/p')
END=$(echo "$INPUT" | sed -n 's/.*"range_end":"\([^"]*\)".*/\1/p')

for i in $(seq "$START" "$END"); do
  IP="${SUBNET}.${i}"
  if ! ping -c 1 -W 1 "$IP" >/dev/null 2>&1; then
    echo "{\"ip\":\"$IP\"}"
    exit 0
  fi
done
echo "Keine freie IP gefunden" >&2
exit 1
