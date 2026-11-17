#!/usr/bin/env bash
# Live test against the real Vision One API. Needs AWS (read-only plan) and VISION_ONE_API_KEY.
#   AWS_PROFILE=umatrenddemo VISION_ONE_API_KEY=... tests/live_scan.sh
# Expected:
#   compliant plan, default gate HIGH  -> exit 0
#   public-SSH plan, default gate HIGH -> exit 0 (SSH finding is MEDIUM)
#   public-SSH plan, gate MEDIUM       -> exit 1 (SSH finding blocks)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UNIT=live/client-demo/dev/ap-southeast-2/ec2-web
R="$ROOT/rendered/$UNIT"
OUT="$ROOT/scan-output/live-test"

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

echo "== 3. Scan compliant plan, gate HIGH (expect exit 0)"
scanner/scan_plan.sh --plan-json "$OUT/plan-compliant.json" --out-dir "$OUT/compliant" --fail-on HIGH >"$OUT/compliant.log" 2>&1
RC1=$?; tail -2 "$OUT/compliant.log"

echo "== 4. Scan public-SSH plan, gate HIGH (expect exit 0: SSH is MEDIUM)"
scanner/scan_plan.sh --plan-json "$OUT/plan-public.json" --out-dir "$OUT/public-high" --fail-on HIGH >"$OUT/public-high.log" 2>&1
RC2=$?; tail -2 "$OUT/public-high.log"

echo "== 5. Scan public-SSH plan, gate MEDIUM (expect exit 1: SSH blocks)"
scanner/scan_plan.sh --plan-json "$OUT/plan-public.json" --out-dir "$OUT/public-medium" --fail-on MEDIUM >"$OUT/public-medium.log" 2>&1
RC3=$?; tail -2 "$OUT/public-medium.log"

echo ""
echo "compliant@HIGH=$RC1 (want 0)  public@HIGH=$RC2 (want 0)  public@MEDIUM=$RC3 (want 1)"
if [[ $RC1 -eq 0 && $RC2 -eq 0 && $RC3 -eq 1 ]]; then echo "LIVE TEST: PASS"; exit 0; fi
echo "LIVE TEST: FAIL"; exit 1
