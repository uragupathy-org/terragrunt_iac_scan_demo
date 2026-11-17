#!/usr/bin/env bash
# Live test against the real Vision One API. Needs AWS (read-only plan) and VISION_ONE_API_KEY.
#   AWS_PROFILE=umatrenddemo VISION_ONE_API_KEY=... tests/live_scan.sh
# Expected: compliant plan exits 0 (after allowlist), public-SSH plan exits 1.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UNIT=live/client-demo/dev/ap-southeast-2/ec2-web
R="$ROOT/rendered/$UNIT"
OUT="$ROOT/scan-output/live-test"
BASE_URL="${VISION_ONE_BASE_URL:-https://api.au.xdr.trendmicro.com}"

[[ -n "${VISION_ONE_API_KEY:-}" ]] || { echo "Set VISION_ONE_API_KEY first" >&2; exit 2; }
export TG_NON_INTERACTIVE=true
mkdir -p "$OUT"
cd "$ROOT"

echo "== 1. Render and plan the compliant unit"
scripts/render_and_plan.sh "$UNIT" >"$OUT/render.log" 2>&1 || { echo "render/plan failed; see $OUT/render.log"; exit 2; }
cp "$R/plan.json" "$OUT/plan-compliant.json"

echo "== 2. Plan the same unit with public SSH (test input only)"
terraform -chdir="$R" plan -input=false -lock=false -no-color \
  -var 'allow_public_ingress=true' -var 'ingress_cidr_blocks=["0.0.0.0/0"]' -var 'ingress_port=22' \
  -out=tfplan-public >"$OUT/plan-public.log" 2>&1 || { echo "public plan failed; see $OUT/plan-public.log"; exit 2; }
terraform -chdir="$R" show -json tfplan-public > "$OUT/plan-public.json"

echo "== 3. Verify the allowlisted rule EC2-031 against the rule catalogue"
curl -sS -H "Authorization: Bearer $VISION_ONE_API_KEY" "$BASE_URL/beta/cloudPosture/terraformTemplateScannerRules" \
  > "$OUT/rules.json"
jq '[.. | objects | select(.ruleId? == "EC2-031")] | .[0] // "EC2-031 not found in rule catalogue"' "$OUT/rules.json" | tee "$OUT/ec2-031.txt"

echo "== 4. Scan compliant plan (expect exit 0)"
scanner/scan_plan.sh --plan-json "$OUT/plan-compliant.json" --out-dir "$OUT/compliant" --threshold MEDIUM
RC_COMPLIANT=$?

echo "== 5. Scan public-SSH plan (expect exit 1)"
scanner/scan_plan.sh --plan-json "$OUT/plan-public.json" --out-dir "$OUT/public" --threshold MEDIUM
RC_PUBLIC=$?

echo ""
echo "compliant exit=$RC_COMPLIANT (expect 0)   public exit=$RC_PUBLIC (expect 1)"
if [[ $RC_COMPLIANT -eq 0 && $RC_PUBLIC -eq 1 ]]; then echo "LIVE TEST: PASS"; exit 0; fi
echo "LIVE TEST: FAIL"; exit 1
