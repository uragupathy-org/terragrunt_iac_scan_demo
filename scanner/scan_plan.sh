#!/usr/bin/env bash
# Scan a rendered Terraform plan (JSON) with the Trend Vision One
# Cloud Risk Management Template Scanner:
#   POST /beta/cloudPosture/scanTemplate  (type: terraform-template)
#
# Usage:
#   scan_plan.sh --plan-json plan.json --out-dir out [--threshold HIGH] [--dry-run]
#
# Env:
#   VISION_ONE_API_KEY   required unless --dry-run
#   VISION_ONE_BASE_URL  default https://api.au.xdr.trendmicro.com
#
# Exit codes: 0 = pass, 1 = findings at/above threshold, 2 = usage/API error.

set -euo pipefail

PLAN_JSON=""
OUT_DIR=""
THRESHOLD="HIGH"
DRY_RUN="false"
BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"
MAX_BYTES=9000000   # API limit on "content" is 9,000,000 characters.

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-json) PLAN_JSON="$2"; shift 2 ;;
    --out-dir)   OUT_DIR="$2"; shift 2 ;;
    --threshold) THRESHOLD="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

[[ -n "$PLAN_JSON" && -f "$PLAN_JSON" ]] || { echo "--plan-json must point to an existing file" >&2; exit 2; }
[[ -n "$OUT_DIR" ]] || { echo "--out-dir is required" >&2; exit 2; }

# Severity ranking. Matches the API riskLevel enum.
rank() {
  case "$1" in
    LOW) echo 1 ;; MEDIUM) echo 2 ;; HIGH) echo 3 ;; VERY_HIGH) echo 4 ;; EXTREME) echo 5 ;;
    *) echo 0 ;;
  esac
}
THRESHOLD_RANK="$(rank "$THRESHOLD")"
[[ "$THRESHOLD_RANK" -gt 0 ]] || { echo "--threshold must be LOW|MEDIUM|HIGH|VERY_HIGH|EXTREME" >&2; exit 2; }

mkdir -p "$OUT_DIR"
REQUEST="$OUT_DIR/request.json"
RESPONSE="$OUT_DIR/response.json"
REPORT_MD="$OUT_DIR/report.md"

# Build the request. The plan JSON is sent as a string in "content".
jq -n --rawfile content "$PLAN_JSON" '{type: "terraform-template", content: $content}' > "$REQUEST"

CONTENT_BYTES="$(jq -r '.content | length' "$REQUEST")"
if (( CONTENT_BYTES > MAX_BYTES )); then
  echo "Plan content is $CONTENT_BYTES chars; API limit is $MAX_BYTES. Split the unit." >&2
  exit 2
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] request built at $REQUEST ($CONTENT_BYTES chars); API not called."
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

# Findings = FAILURE results that are not ignored.
TOTAL="$(jq '.scanResults | length' "$RESPONSE")"
FAILED="$(jq '[.scanResults[] | select(.status == "FAILURE" and (.ignored | not))] | length' "$RESPONSE")"

# Findings at or above threshold.
BLOCKING_JSON="$(jq --arg t "$THRESHOLD" '
  def rank: {"LOW":1,"MEDIUM":2,"HIGH":3,"VERY_HIGH":4,"EXTREME":5}[.] // 0;
  [.scanResults[]
   | select(.status == "FAILURE" and (.ignored | not))
   | select(((.riskLevel // "") | rank) >= ($t | rank))]' "$RESPONSE")"
BLOCKING="$(echo "$BLOCKING_JSON" | jq 'length')"

{
  echo "## Vision One Template Scan"
  echo ""
  echo "- Plan file: \`$(basename "$PLAN_JSON")\`"
  echo "- Results returned: $TOTAL"
  echo "- Failing (not ignored): $FAILED"
  echo "- Blocking at threshold \`$THRESHOLD\`: $BLOCKING"
  echo ""
  if (( FAILED > 0 )); then
    echo "| Risk | Rule | Resource | Title |"
    echo "|------|------|----------|-------|"
    jq -r '.scanResults[]
      | select(.status == "FAILURE" and (.ignored | not))
      | "| \(.riskLevel // "-") | \(.ruleId) | \(.resource) | \(.ruleTitle) |"' "$RESPONSE"
  else
    echo "No failing results."
  fi
} > "$REPORT_MD"

cat "$REPORT_MD"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$REPORT_MD" >> "$GITHUB_STEP_SUMMARY"
fi

if (( BLOCKING > 0 )); then
  echo "FAIL: $BLOCKING finding(s) at or above $THRESHOLD."
  exit 1
fi
echo "PASS: no findings at or above $THRESHOLD."
exit 0
