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
#   scan_plan.sh (--plan-json FILE | --archive FILE) --out-dir DIR
#                [--threshold MEDIUM] [--allowlist FILE] [--dry-run]
#
# Env:
#   VISION_ONE_API_KEY   required unless --dry-run
#   VISION_ONE_BASE_URL  default https://api.au.xdr.trendmicro.com
#
# Allowlist: findings matching ruleId + resource are accepted, listed in the
# report with their reason, and do not count toward the gate.
#
# Exit codes: 0 = pass, 1 = unaccepted findings at/above threshold,
#             2 = usage, API, or allowlist error (including zero results).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLAN_JSON=""
ARCHIVE=""
OUT_DIR=""
THRESHOLD="MEDIUM"
ALLOWLIST="$SCRIPT_DIR/allowlist.json"
DRY_RUN="false"
BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"
MAX_CHARS=9000000   # API limit on "content" for scanTemplate.

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan-json) PLAN_JSON="$2"; shift 2 ;;
    --archive)   ARCHIVE="$2"; shift 2 ;;
    --out-dir)   OUT_DIR="$2"; shift 2 ;;
    --threshold) THRESHOLD="$(echo "$2" | tr '[:lower:]' '[:upper:]')"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
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

rank() {
  case "$1" in
    LOW) echo 1 ;; MEDIUM) echo 2 ;; HIGH) echo 3 ;; VERY_HIGH) echo 4 ;; EXTREME) echo 5 ;;
    *) echo 0 ;;
  esac
}
THRESHOLD_RANK="$(rank "$THRESHOLD")"
[[ "$THRESHOLD_RANK" -gt 0 ]] || { echo "--threshold must be LOW|MEDIUM|HIGH|VERY_HIGH|EXTREME" >&2; exit 2; }

[[ -f "$ALLOWLIST" ]] || { echo "Allowlist not found: $ALLOWLIST" >&2; exit 2; }
jq -e 'type == "array" and all(.[]; (.ruleId|type=="string") and (.resource|type=="string") and ((.reason // "")|length > 0))' \
  "$ALLOWLIST" >/dev/null || { echo "Allowlist must be an array of {ruleId, resource, reason} with a non-empty reason" >&2; exit 2; }

mkdir -p "$OUT_DIR"
RESPONSE="$OUT_DIR/response.json"
FINDINGS="$OUT_DIR/findings.json"
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

TOTAL="$(jq '.scanResults | length' "$RESPONSE")"

# Failing results (FAILURE and not ignored), each with its allowlist entry if accepted.
jq --slurpfile allow "$ALLOWLIST" '
  ($allow[0]) as $a
  | [ .scanResults[]
      | select(.status == "FAILURE" and (.ignored | not))
      | . as $f
      | ([$a[] | select(.ruleId == $f.ruleId and .resource == $f.resource)] | .[0]) as $acc
      | $f + {accepted: $acc} ]' "$RESPONSE" > "$FINDINGS"

FAILED="$(jq 'length' "$FINDINGS")"
ACCEPTED="$(jq '[.[] | select(.accepted != null)] | length' "$FINDINGS")"
BLOCKING="$(jq --arg t "$THRESHOLD" '
  def rank: {"LOW":1,"MEDIUM":2,"HIGH":3,"VERY_HIGH":4,"EXTREME":5}[.] // 0;
  [ .[] | select(.accepted == null and (((.riskLevel // "") | rank) >= ($t | rank))) ] | length' "$FINDINGS")"

{
  echo "## Vision One Template Scan ($(basename "$INPUT"))"
  echo ""
  echo "- Input: \`$(basename "$INPUT")\` ($SIZE_DESC)"
  echo "- Results returned: $TOTAL"
  echo "- Failing (not ignored): $FAILED"
  echo "- Accepted by allowlist: $ACCEPTED"
  echo "- Blocking at threshold \`$THRESHOLD\`: $BLOCKING"
  echo ""
  if (( FAILED > 0 )); then
    echo "| Risk | Rule | Resource | Title | Status |"
    echo "|------|------|----------|-------|--------|"
    jq -r '.[] | "| \(.riskLevel // "-") | \(.ruleId) | \(.resource) | \(.ruleTitle) | \(if .accepted then "accepted" else "BLOCKING candidate" end) |"' "$FINDINGS"
    if (( ACCEPTED > 0 )); then
      echo ""
      echo "Accepted findings and reasons:"
      jq -r '.[] | select(.accepted != null) | "- \(.ruleId) on \(.resource): \(.accepted.reason)"' "$FINDINGS"
    fi
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
  echo "FAIL: $BLOCKING unaccepted finding(s) at or above $THRESHOLD."
  exit 1
fi
echo "PASS: no unaccepted findings at or above $THRESHOLD."
exit 0
