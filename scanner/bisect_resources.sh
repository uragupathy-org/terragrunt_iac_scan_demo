#!/usr/bin/env bash
# Second bisect: find which resource (or value pattern) in resource_changes triggers the 500.
# Keeps format_version, terraform_version and configuration so the service still parses the format.
#
# Usage: VISION_ONE_API_KEY=... scanner/bisect_resources.sh [plan.json]
set -uo pipefail

BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"
PLAN="${1:-rendered/live/client-demo/dev/ap-southeast-2/ec2-web/plan.json}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -n "${VISION_ONE_API_KEY:-}" ]] || { echo "Set VISION_ONE_API_KEY first" >&2; exit 2; }
[[ -f "$PLAN" ]] || { echo "Missing plan: $PLAN" >&2; exit 2; }

run_variant() {  # run_variant <label> <jq filter>
  local label="$1" filter="$2"
  jq "$filter" "$PLAN" > "$TMP/plan.json" || { echo "$label: jq failed"; return; }
  jq -n --rawfile c "$TMP/plan.json" '{type:"terraform-template", content:$c}' > "$TMP/req.json"
  local hdr="$TMP/h.txt" body="$TMP/b.txt" code
  code="$(curl -sS --max-time 120 -D "$hdr" -o "$body" -w '%{http_code}' \
    -X POST "$BASE_URL/beta/cloudPosture/scanTemplate" \
    -H "Authorization: Bearer $VISION_ONE_API_KEY" \
    -H 'Content-Type: application/json;charset=utf-8' --data-binary "@$TMP/req.json")"
  local trace; trace="$(grep -i '^x-trace-id:' "$hdr" | tr -d '\r' | cut -d' ' -f2)"
  printf '%-44s HTTP %-4s bytes=%-7s trace=%s\n' "$label" "$code" "$(wc -c < "$TMP/plan.json" | tr -d ' ')" "${trace:-n/a}"
  if [[ "$code" != "200" && "$code" != "500" ]]; then printf '    body: %s\n' "$(head -c 200 "$body")"; fi
}

NULLS='walk(if type == "object" then with_entries(select(.value != null)) else . end)'

run_variant "R1 only aws_security_group.this"          '.resource_changes |= map(select(.address == "module.web_instance.aws_security_group.this"))'
run_variant "R2 only aws_instance.this"                '.resource_changes |= map(select(.address == "module.web_instance.aws_instance.this"))'
run_variant "R3 only egress rule"                      '.resource_changes |= map(select(.address | endswith("aws_vpc_security_group_egress_rule.all")))'
run_variant "R4 no planned_values"                     'del(.planned_values)'
run_variant "R5 change.after removed (keep before)"    '(.resource_changes[].change) |= del(.after)'
run_variant "R6 null values removed recursively"       "$NULLS"
run_variant "R7 after_unknown removed + nulls dropped" "(.resource_changes[].change) |= del(.after_unknown) | $NULLS"
run_variant "R8 empty resource_changes"                '.resource_changes = []'

echo ""
echo "Reading the table:"
echo "  R1/R2/R3 200 for one resource only -> that resource's values trigger it (look at its 'after')."
echo "  R5 or R6 200 -> the 'after' values (or nulls in them) trigger it."
echo "  R8 still 500 -> the failure is outside resource_changes; send the trace for baseline + R8."
