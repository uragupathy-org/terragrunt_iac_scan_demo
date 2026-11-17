#!/usr/bin/env bash
# Send a Terraform plan (JSON) to the Trend Vision One Cloud Risk Management
# Template Scanner, print the payload and the findings, and fail on severity.
#
#   POST https://<region>/beta/cloudPosture/scanTemplate
#   body: {"type": "terraform-template", "content": "<plan.json as a string>"}
#
# Usage:
#   scanner/scan_plan.sh --plan-json FILE --out-dir DIR [--fail-on SEVERITY] [--dry-run]
#
# Severity (LOW, MEDIUM, HIGH, VERY_HIGH, EXTREME). Precedence: --fail-on, then
# the FAIL_ON environment variable, then HIGH.
#
# Env:
#   VISION_ONE_API_KEY   required unless --dry-run
#   VISION_ONE_BASE_URL  default https://api.au.xdr.trendmicro.com
#   FAIL_ON              default severity gate if --fail-on is not given
#
# Exit codes: 0 = no findings at/above the gate, 1 = findings at/above the gate,
#             2 = usage or API error (including zero results).

set -euo pipefail

PLAN_JSON=""
OUT_DIR=""
FAIL_ON_ARG=""
DRY_RUN="false"
BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"
MAX_CHARS=9000000   # API limit on "content".

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-json) PLAN_JSON="$2"; shift 2 ;;
    --out-dir)   OUT_DIR="$2"; shift 2 ;;
    --fail-on)   FAIL_ON_ARG="$2"; shift 2 ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$PLAN_JSON" ]] || { echo "--plan-json is required" >&2; exit 2; }
[[ -f "$PLAN_JSON" ]] || { echo "Plan file not found: $PLAN_JSON" >&2; exit 2; }
[[ -n "$OUT_DIR" ]] || { echo "--out-dir is required" >&2; exit 2; }

# Severity gate: CLI beats environment beats default.
FAIL_ON="$(echo "${FAIL_ON_ARG:-${FAIL_ON:-HIGH}}" | tr '[:lower:]' '[:upper:]')"
rank() {
  case "$1" in
    LOW) echo 1 ;; MEDIUM) echo 2 ;; HIGH) echo 3 ;; VERY_HIGH) echo 4 ;; EXTREME) echo 5 ;;
    *) echo 0 ;;
  esac
}
GATE_RANK="$(rank "$FAIL_ON")"
[[ "$GATE_RANK" -gt 0 ]] || { echo "Invalid severity '$FAIL_ON': use LOW, MEDIUM, HIGH, VERY_HIGH or EXTREME" >&2; exit 2; }

mkdir -p "$OUT_DIR"
REQUEST="$OUT_DIR/request.json"
RESPONSE="$OUT_DIR/response.json"
REPORT="$OUT_DIR/report.md"

# Step 0: build the exact request body and print it.
jq -n --rawfile content "$PLAN_JSON" '{type: "terraform-template", content: $content}' > "$REQUEST"
SIZE="$(jq -r '.content | length' "$REQUEST")"
if (( SIZE > MAX_CHARS )); then
  echo "Plan content is $SIZE chars; API limit is $MAX_CHARS." >&2
  exit 2
fi

echo "=== Step 0: payload sent to Vision One"
echo "POST $BASE_URL/beta/cloudPosture/scanTemplate"
echo "Authorization: Bearer <redacted>"
echo "Content-Type: application/json;charset=utf-8"
echo "Body ($(wc -c < "$REQUEST" | tr -d ' ') bytes, content = $SIZE chars):"
cat "$REQUEST"
echo ""
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] payload built; API not called. Gate: $FAIL_ON"
  exit 0
fi

[[ -n "${VISION_ONE_API_KEY:-}" ]] || { echo "VISION_ONE_API_KEY is not set" >&2; exit 2; }

HTTP_CODE="$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
  -X POST "$BASE_URL/beta/cloudPosture/scanTemplate" \
  -H "Authorization: Bearer $VISION_ONE_API_KEY" \
  -H "Content-Type: application/json;charset=utf-8" \
  --data-binary "@$REQUEST")"

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Template Scanner API returned HTTP $HTTP_CODE" >&2
  cat "$RESPONSE" >&2 || true
  exit 2
fi

TOTAL="$(jq '.scanResults | length' "$RESPONSE")"
if (( TOTAL == 0 )); then
  echo "ERROR: API returned 0 scan results; the plan was not evaluated." >&2
  exit 2
fi

# Step 1: findings = FAILURE and not ignored.
FINDINGS_JSON="$(jq '[.scanResults[] | select(.status == "FAILURE" and (.ignored | not))]' "$RESPONSE")"
FAILED="$(echo "$FINDINGS_JSON" | jq 'length')"
SUCCESS_N="$(jq '[.scanResults[] | select(.status == "SUCCESS")] | length' "$RESPONSE")"
FAILURE_N="$(jq '[.scanResults[] | select(.status == "FAILURE")] | length' "$RESPONSE")"
GATED="$(echo "$FINDINGS_JSON" | jq --arg g "$FAIL_ON" '
  def rank: {"LOW":1,"MEDIUM":2,"HIGH":3,"VERY_HIGH":4,"EXTREME":5}[.] // 0;
  [.[] | select(((.riskLevel // "") | rank) >= ($g | rank))] | length')"

FINDINGS_TABLE="$(echo "$FINDINGS_JSON" | jq -r '
  if length == 0 then "No findings (FAILURE, not ignored)."
  else
    "| Severity | Rule | Resource type | Title | Status |\n|----------|------|---------------|-------|--------|\n" +
    (map("| \(.riskLevel // "-") | \(.ruleId) | \(.resourceType // "-") | \(.ruleTitle) | \(.status) |") | join("\n"))
  end')"

ALL_TABLE="$(jq -r '
  "| Severity | Rule | Resource type | Title | Status |\n|----------|------|---------------|-------|--------|\n" +
  ([.scanResults[] | "| \(.riskLevel // "-") | \(.ruleId) | \(.resourceType // "-") | \(.ruleTitle) | \(.status) |"] | join("\n"))' "$RESPONSE")"

HEADER="$(cat <<HDR
## Vision One Template Scan

- Input: \`$(basename "$PLAN_JSON")\`
- Results returned: $TOTAL (status SUCCESS: $SUCCESS_N, FAILURE: $FAILURE_N)
- Findings (FAILURE, not ignored): $FAILED
- Gate (fail on this severity or higher): \`$FAIL_ON\`
- Findings at or above gate: $GATED
HDR
)"

{
  echo "$HEADER"
  echo ""
  echo "### Findings (FAILURE): $FAILED"
  echo ""
  echo "$FINDINGS_TABLE"
  echo ""
  echo "<details>"
  echo "<summary>All $TOTAL results (SUCCESS and FAILURE)</summary>"
  echo ""
  echo "$ALL_TABLE"
  echo ""
  echo "</details>"
} > "$REPORT"

echo "=== Step 1: findings"
echo "$HEADER"
echo ""
echo "$FINDINGS_TABLE"
echo ""
echo "Full list of $TOTAL results: $REPORT"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"; fi

# Step 2: fail on findings at or above the gate.
if (( GATED > 0 )); then
  echo "=== Step 2: FAIL. $GATED finding(s) at or above $FAIL_ON."
  exit 1
fi
echo "=== Step 2: PASS. No findings at or above $FAIL_ON."
exit 0
