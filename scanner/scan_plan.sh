#!/usr/bin/env bash
# Scan generated Terraform with the Trend Vision One Cloud Risk Management
# Template Scanner. Two input modes:
#
#   --plan-json FILE   rendered plan (terraform show -json)
#                      POST /beta/cloudPosture/scanTemplate  (type: terraform-template)
#   --archive FILE     ZIP of rendered HCL (single root module)
#                      POST /beta/cloudPosture/scanTemplateArchive (type: terraform-archive)
#
# Usage:
#   scan_plan.sh (--plan-json FILE | --archive FILE) --out-dir DIR [--threshold MEDIUM] [--dry-run]
#
# Env:
#   VISION_ONE_API_KEY   required unless --dry-run
#   VISION_ONE_BASE_URL  default https://api.au.xdr.trendmicro.com
#
# Exit codes: 0 = pass, 1 = findings at/above threshold, 2 = usage/API error.

set -euo pipefail

PLAN_JSON=""
ARCHIVE=""
OUT_DIR=""
THRESHOLD="MEDIUM"
DRY_RUN="false"
BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"
MAX_CHARS=9000000   # API limit on "content" for scanTemplate.

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-json) PLAN_JSON="$2"; shift 2 ;;
    --archive)   ARCHIVE="$2"; shift 2 ;;
    --out-dir)   OUT_DIR="$2"; shift 2 ;;
    --threshold) THRESHOLD="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --dry-run)   DRY_RUN="true"; shift ;;
    -h|--help)   usage ;;
    *) echo "Unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -n "$PLAN_JSON" && -n "$ARCHIVE" ]] || [[ -z "$PLAN_JSON" && -z "$ARCHIVE" ]]; then
  echo "Specify exactly one of --plan-json or --archive" >&2; exit 2
fi
[[ -n "$OUT_DIR" ]] || { echo "--out-dir is required" >&2; exit 2; }

INPUT="${PLAN_JSON:-$ARCHIVE}"
[[ -f "$INPUT" ]] || { echo "Input file not found: $INPUT" >&2; exit 2; }

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
RESPONSE="$OUT_DIR/response.json"
REPORT_MD="$OUT_DIR/report.md"

if [[ -n "$PLAN_JSON" ]]; then
  REQUEST="$OUT_DIR/request.json"
  jq -n --rawfile content "$PLAN_JSON" '{type: "terraform-template", content: $content}' > "$REQUEST"
  SIZE="$(jq -r '.content | length' "$REQUEST")"
  if (( SIZE > MAX_CHARS )); then
    echo "Plan content is $SIZE chars; API limit is $MAX_CHARS. Split the unit." >&2
    exit 2
  fi
  SIZE_DESC="$SIZE chars"
else
  SIZE_DESC="$(wc -c < "$ARCHIVE" | tr -d ' ') bytes"
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] input $INPUT ($SIZE_DESC) prepared; API not called."
  exit 0
fi

[[ -n "${VISION_ONE_API_KEY:-}" ]] || { echo "VISION_ONE_API_KEY is not set" >&2; exit 2; }

if [[ -n "$PLAN_JSON" ]]; then
  HTTP_CODE="$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
    -X POST "$BASE_URL/beta/cloudPosture/scanTemplate" \
    -H "Authorization: Bearer $VISION_ONE_API_KEY" \
    -H "Content-Type: application/json;charset=utf-8" \
    --data-binary "@$REQUEST")"
else
  HTTP_CODE="$(curl -sS -o "$RESPONSE" -w '%{http_code}' \
    -X POST "$BASE_URL/beta/cloudPosture/scanTemplateArchive" \
    -H "Authorization: Bearer $VISION_ONE_API_KEY" \
    -F "type=terraform-archive" \
    -F "file=@$ARCHIVE;type=application/zip")"
fi

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Template Scanner API returned HTTP $HTTP_CODE" >&2
  cat "$RESPONSE" >&2 || true
  exit 2
fi

# Findings = FAILURE results that are not ignored; blocking = findings at/above threshold.
FAILED="$(jq '[.scanResults[] | select(.status == "FAILURE" and (.ignored | not))] | length' "$RESPONSE")"
TOTAL="$(jq '.scanResults | length' "$RESPONSE")"
BLOCKING="$(jq --arg t "$THRESHOLD" '
  def rank: {"LOW":1,"MEDIUM":2,"HIGH":3,"VERY_HIGH":4,"EXTREME":5}[.] // 0;
  [.scanResults[]
   | select(.status == "FAILURE" and (.ignored | not))
   | select(((.riskLevel // "") | rank) >= ($t | rank))] | length' "$RESPONSE")"

{
  echo "## Vision One Template Scan ($(basename "$INPUT"))"
  echo ""
  echo "- Input: \`$(basename "$INPUT")\` ($SIZE_DESC)"
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

# Zero results means nothing was evaluated; never report that as a pass.
if (( TOTAL == 0 )); then
  echo "ERROR: API returned 0 scan results; the input was not evaluated." >&2
  exit 2
fi

if (( BLOCKING > 0 )); then
  echo "FAIL: $BLOCKING finding(s) at or above $THRESHOLD."
  exit 1
fi
echo "PASS: no findings at or above $THRESHOLD."
exit 0
