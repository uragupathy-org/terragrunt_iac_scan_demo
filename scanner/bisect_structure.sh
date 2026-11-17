#!/usr/bin/env bash
# Third bisect: the 500 persists with resource_changes emptied (R8), so test the
# plan structure: module calls, Terraform version, and format fields.
#
# Usage: VISION_ONE_API_KEY=... scanner/bisect_structure.sh [plan.json]
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
  printf '%-46s HTTP %-4s bytes=%-7s trace=%s\n' "$label" "$code" "$(wc -c < "$TMP/plan.json" | tr -d ' ')" "${trace:-n/a}"
  if [[ "$code" != "200" && "$code" != "500" ]]; then printf '    body: %s\n' "$(head -c 200 "$body")"; fi
}

run_variant "S1 empty resource_changes, no module_calls" \
  '.resource_changes = [] | del(.configuration.root_module.module_calls)'
run_variant "S2 empty resource_changes, planned_values emptied" \
  '.resource_changes = [] | .planned_values = {"root_module": {}}'
run_variant "S3 terraform_version set to 1.5.7" \
  '.terraform_version = "1.5.7" | .resource_changes = []'
run_variant "S4 format_version set to 1.1" \
  '.format_version = "1.1" | .resource_changes = []'
run_variant "S5 configuration.root_module.outputs removed" \
  '.resource_changes = [] | del(.configuration.root_module.outputs)'
run_variant "S6 configuration.provider_config removed" \
  '.resource_changes = [] | del(.configuration.provider_config)'
run_variant "S7 minimal shell: format + versions + planned_values only" \
  '{format_version, terraform_version, planned_values: {root_module: {}}}'

echo ""
echo "Reading the table:"
echo "  S1 200 -> module_calls in configuration trigger it (flatten or drop module calls)."
echo "  S3 or S4 200 -> the version string triggers it (the service may not accept 1.12.x)."
echo "  S5 or S6 200 -> that configuration section triggers it."
echo "  S7 still 500 -> send Trend support the S7 trace: a minimal valid-looking plan fails server-side."
