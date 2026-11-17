#!/usr/bin/env bash
# Find which section of a plan.json makes scanTemplate return HTTP 500.
# Each variant removes one section (or one field type) from the plan and posts it.
# The first variant that returns 200 after removing a section points at that section.
#
# Usage: VISION_ONE_API_KEY=... scanner/bisect_plan.sh [plan.json]
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
  printf '%-40s HTTP %-4s bytes=%-7s trace=%s\n' "$label" "$code" "$(wc -c < "$TMP/plan.json" | tr -d ' ')" "${trace:-n/a}"
}

run_variant "A  full plan (baseline)"                  '.'
run_variant "B  without prior_state"                   'del(.prior_state)'
run_variant "C  without configuration"                 'del(.configuration)'
run_variant "D  without variables"                     'del(.variables)'
run_variant "E  without output_changes"                'del(.output_changes)'
run_variant "F  without relevant_attributes"           'del(.relevant_attributes)'
run_variant "G  without timestamp/applyable/flags"     'del(.timestamp, .applyable, .complete, .errored)'
run_variant "H  without after_identity/before_identity" '(.resource_changes[].change) |= del(.after_identity, .before_identity)'
run_variant "I  without module_address"                '(.resource_changes[]) |= del(.module_address)'
run_variant "J  without any *_sensitive/_unknown"      '(.resource_changes[].change) |= del(.after_sensitive, .before_sensitive, .after_unknown)'
run_variant "K  minimal: versions + resource_changes"  '{format_version, terraform_version, resource_changes: [.resource_changes[] | {address, mode, type, name, provider_name, change: {actions: .change.actions, before: .change.before, after: .change.after}}]}'

echo ""
echo "Read the table: the variant that turns 500 into 200 identifies the section to report."
echo "If only K returns 200, the problem is in a section you removed in K (ask for the trace of A)."
