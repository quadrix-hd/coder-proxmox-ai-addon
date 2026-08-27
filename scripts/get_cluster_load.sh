#!/bin/bash
set -e
INPUT=$(cat)
API_URL=$(echo "$INPUT" | sed -n 's/.*"api_url":"\([^"]*\)".*/\1/p')
TOKEN_ID=$(echo "$INPUT" | sed -n 's/.*"token_id":"\([^"]*\)".*/\1/p')
TOKEN_SECRET=$(echo "$INPUT" | sed -n 's/.*"token_secret":"\([^"]*\)".*/\1/p')

PREFERRED_NODE="pve"
FAILOVER_NODE="pve4"
THRESHOLD=90

RESPONSE=$(curl -sk "${API_URL}/nodes" \
  -H "Authorization: PVEAPIToken=${TOKEN_ID}=${TOKEN_SECRET}")

LINES=$(echo "$RESPONSE" | sed 's/},{/}\n{/g')

RESULT="{"
i=1
PREFERRED_PCT=""

while IFS= read -r LINE; do
  NODE=$(echo "$LINE" | sed -n 's/.*"node":"\([^"]*\)".*/\1/p')
  MEM=$(echo "$LINE" | sed -n 's/.*"mem":\([0-9]*\).*/\1/p')
  MAXMEM=$(echo "$LINE" | sed -n 's/.*"maxmem":\([0-9]*\).*/\1/p')

  if [ -z "$NODE" ] || [ -z "$MEM" ] || [ -z "$MAXMEM" ]; then
    continue
  fi

  PCT=$(LC_NUMERIC=C awk "BEGIN { printf \"%.1f\", ($MEM/$MAXMEM)*100 }")
  RESULT="${RESULT}\"node${i}_name\":\"${NODE}\",\"node${i}_load\":\"${PCT}\","

  if [ "$NODE" = "$PREFERRED_NODE" ]; then
    PREFERRED_PCT=$PCT
  fi

  i=$((i+1))
done <<EOF
$LINES
EOF

if [ -z "$PREFERRED_PCT" ]; then
  PREFERRED_PCT=0
fi

IS_OVER_THRESHOLD=$(LC_NUMERIC=C awk "BEGIN { if ($PREFERRED_PCT >= $THRESHOLD) print 1; else print 0 }")

if [ "$IS_OVER_THRESHOLD" = "1" ]; then
  DEFAULT_NODE=$FAILOVER_NODE
else
  DEFAULT_NODE=$PREFERRED_NODE
fi

RESULT="${RESULT}\"default_node\":\"${DEFAULT_NODE}\"}"
echo "$RESULT"
