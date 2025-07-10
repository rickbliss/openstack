#!/usr/bin/env bash
set -euo pipefail

HOSTS=(bc00 bc01 bc02 bc03 bc04)
PRIMARY_NODE=""
declare -A NODE_ROLE

echo "Identifying MariaDB node roles..."
for HOST in "${HOSTS[@]}"; do
  echo -n "→ [$HOST] Checking grastate.dat... "
  OUT=$(ssh "$HOST" "grep safe_to_bootstrap /var/lib/containers/storage/volumes/mariadb/_data/grastate.dat 2>/dev/null" || true)
  
  if [[ -z "$OUT" ]]; then
    echo "NOT A DB NODE"
    NODE_ROLE["$HOST"]="NON-DB"
  elif echo "$OUT" | grep -q "safe_to_bootstrap: 1"; then
    echo "PRIMARY"
    NODE_ROLE["$HOST"]="PRIMARY"
    PRIMARY_NODE="$HOST"
  else
    echo "NON-PRIMARY"
    NODE_ROLE["$HOST"]="NON-PRIMARY"
  fi
done

echo ""
echo "Rebooting non-DB and NON-PRIMARY DB nodes..."
for HOST in "${HOSTS[@]}"; do
  ROLE=${NODE_ROLE["$HOST"]}
  if [[ "$ROLE" == "NON-DB" || "$ROLE" == "NON-PRIMARY" ]]; then
    echo "→ [$HOST] Rebooting..."
    ssh "$HOST" "sudo reboot" || true

    echo "→ [$HOST] Waiting for port 22 to become available..."
    until socat -T 1 - TCP4:"$HOST":22 >/dev/null 2>&1; do
      sleep 2
    done
    sleep 10

    echo "→ [$HOST] Waiting for podman mariadb to become healthy..."
    while ! ssh "$HOST" "podman ps --format '{{.Names}} {{.Status}}' | grep -q 'mariadb.*(healthy)'"; do
      echo "→ [$HOST] Waiting for mariadb to be healthy..."; sleep 5
    done
    echo "→ [$HOST] mariadb is healthy. Done."
  fi
done

if [[ -n "$PRIMARY_NODE" ]]; then
  echo ""
  echo "Rebooting PRIMARY node last: $PRIMARY_NODE"
  ssh "$PRIMARY_NODE" "sudo reboot" || true

  echo "→ [$PRIMARY_NODE] Waiting for port 22 to become available..."
  until socat -T 1 - TCP4:"$PRIMARY_NODE":22 >/dev/null 2>&1; do
    sleep 2
  done
  sleep 10

  echo "→ [$PRIMARY_NODE] Waiting for podman mariadb to become healthy..."
  while ! ssh "$PRIMARY_NODE" "podman ps --format '{{.Names}} {{.Status}}' | grep -q 'mariadb.*(healthy)'"; do
    echo "→ [$PRIMARY_NODE] Waiting for mariadb to be healthy..."; sleep 5
  done
  echo "→ [$PRIMARY_NODE] mariadb is healthy. Done."
else
  echo "❌ No PRIMARY node found. Aborting."
  exit 1
fi
