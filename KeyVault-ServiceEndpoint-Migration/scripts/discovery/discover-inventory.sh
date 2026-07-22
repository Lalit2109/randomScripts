#!/usr/bin/env bash
#
# Discover-Inventory: runs all Resource Graph queries for the Key Vault
# Service Endpoint migration and consolidates the results into one JSON
# inventory file, joined on subscriptionId + vnetSubnetId.
#
# Requires: az cli >= 2.55 with the resource-graph extension
#   az extension add --name resource-graph
#
# Usage:
#   ./discover-inventory.sh --subscription <sub-id> [--subscription <sub-id> ...] --output ./inventory.json
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERY_DIR="$SCRIPT_DIR/queries"
SUBSCRIPTIONS=()
OUTPUT="./inventory-$(date +%Y%m%d-%H%M%S).json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription) SUBSCRIPTIONS+=("$2"); shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ ${#SUBSCRIPTIONS[@]} -eq 0 ]]; then
  echo "At least one --subscription <sub-id> is required." >&2
  exit 1
fi

SUB_ARGS=()
for s in "${SUBSCRIPTIONS[@]}"; do SUB_ARGS+=(--subscriptions "$s"); done

run_query() {
  local query_file="$1"
  az graph query -q "$(cat "$query_file")" "${SUB_ARGS[@]}" --first 1000 -o json | jq '.data'
}

echo "Running discovery queries against ${#SUBSCRIPTIONS[@]} subscription(s)..." >&2

KEYVAULTS=$(run_query "$QUERY_DIR/keyvaults.kql")
FUNCTIONAPPS=$(run_query "$QUERY_DIR/function-apps.kql")
PRIVATEENDPOINTS=$(run_query "$QUERY_DIR/private-endpoints.kql")
SUBNETS=$(run_query "$QUERY_DIR/subnets.kql")
RBAC=$(run_query "$QUERY_DIR/rbac-assignments.kql")

jq -n \
  --argjson keyVaults "$KEYVAULTS" \
  --argjson functionApps "$FUNCTIONAPPS" \
  --argjson privateEndpoints "$PRIVATEENDPOINTS" \
  --argjson subnets "$SUBNETS" \
  --argjson rbacAssignments "$RBAC" \
  --arg generatedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    generatedAt: $generatedAt,
    keyVaults: $keyVaults,
    functionApps: $functionApps,
    privateEndpoints: $privateEndpoints,
    subnets: $subnets,
    rbacAssignments: $rbacAssignments
  }' > "$OUTPUT"

echo "Discovery complete. Consolidated inventory written to: $OUTPUT" >&2
echo "  Key Vaults:         $(echo "$KEYVAULTS" | jq 'length')" >&2
echo "  Function Apps:       $(echo "$FUNCTIONAPPS" | jq 'length')" >&2
echo "  Private Endpoints:   $(echo "$PRIVATEENDPOINTS" | jq 'length')" >&2
echo "  Subnets:             $(echo "$SUBNETS" | jq 'length')" >&2
echo "  RBAC Assignments:    $(echo "$RBAC" | jq 'length')" >&2
