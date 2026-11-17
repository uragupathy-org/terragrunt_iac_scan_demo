#!/usr/bin/env bash
# Diagnose Template Scanner failures (HTTP 500 or otherwise).
# Sends progressively larger requests and prints status + x-trace-id for each,
# so a failure can be tied to a specific payload. The key is never printed.
#
# Usage: VISION_ONE_API_KEY=... scanner/diagnose.sh [rendered-dir]
set -uo pipefail

BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"
REND="${1:-rendered/live/client-demo/dev/ap-southeast-2/ec2-web}"
HERE="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[[ -n "${VISION_ONE_API_KEY:-}" ]] || { echo "Set VISION_ONE_API_KEY first" >&2; exit 2; }
for f in "$REND/plan.json" "$REND/rendered-tf.zip"; do
  [[ -f "$f" ]] || { echo "Missing: $f" >&2; exit 2; }
done

# Minimal archive: one file, no modules.
(cd "$HERE/fixtures/minimal-tf" && zip -q "$TMP/minimal-tf.zip" main.tf)

probe() {  # probe <label> <curl args...>
  local label="$1"; shift
  local hdr="$TMP/h.txt" body="$TMP/b.txt"
  local code
  code="$(curl -sS --max-time 120 -D "$hdr" -o "$body" -w '%{http_code}' "$@" 2>"$TMP/err.txt")" || code="curl-error"
  local trace
  trace="$(grep -i '^x-trace-id:' "$hdr" 2>/dev/null | tr -d '\r' | cut -d' ' -f2)"
  printf '%-34s HTTP %-6s trace=%s\n' "$label" "$code" "${trace:-n/a}"
  if [[ "$code" != "200" ]]; then
    printf '    body: %s\n' "$(head -c 300 "$body" 2>/dev/null)"
    [[ -s "$TMP/err.txt" ]] && printf '    curl: %s\n' "$(cat "$TMP/err.txt")"
  fi
}

AUTH=(-H "Authorization: Bearer $VISION_ONE_API_KEY")

probe "1 GET scanner rules (auth only)" "${AUTH[@]}" "$BASE_URL/beta/cloudPosture/terraformTemplateScannerRules"


jq -n --rawfile c "$REND/plan.json" '{type:"terraform-template", content:$c}' > "$TMP/our-req.json"
probe "2 scanTemplate our plan.json" "${AUTH[@]}" -H 'Content-Type: application/json;charset=utf-8' \
  -X POST "$BASE_URL/beta/cloudPosture/scanTemplate" --data-binary "@$TMP/our-req.json"

probe "3 scanTemplateArchive minimal tf" "${AUTH[@]}" \
  -X POST "$BASE_URL/beta/cloudPosture/scanTemplateArchive" \
  -F "type=terraform-archive" -F "file=@$TMP/minimal-tf.zip;type=application/zip"

probe "4 scanTemplateArchive our zip" "${AUTH[@]}" \
  -X POST "$BASE_URL/beta/cloudPosture/scanTemplateArchive" \
  -F "type=terraform-archive" -F "file=@$REND/rendered-tf.zip;type=application/zip"

echo ""
echo "Interpretation:"
echo "  2 fails, 1 ok  -> service-side problem with scanTemplate; send trace IDs to Trend support"
echo "  3 fails, 2 ok  -> our plan.json triggers it; the failing trace ID is the one to report"
echo "  4/5 fail       -> archive endpoint; compare 4 vs 5 to see if the module layout matters"
echo "  all fail, 1 ok -> scanner endpoints only; contact support with the trace IDs"
