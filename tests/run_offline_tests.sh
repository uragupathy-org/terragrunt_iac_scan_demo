#!/usr/bin/env bash
# Offline tests for scanner/scan_plan.sh. No Vision One key or AWS access needed:
# a local mock serves recorded-shape responses from tests/fixtures.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCAN="$ROOT/scanner/scan_plan.sh"
ALLOW="$ROOT/scanner/allowlist.json"
FIX="$HERE/fixtures"
PORT=8797
WORK="$(mktemp -d)"
MOCK_PID=""
PASS=0; FAILN=0

cleanup() { [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

start_mock() {  # start_mock <fixture-name> <key>
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null && wait "$MOCK_PID" 2>/dev/null
  python3 -I "$HERE/mock_api.py" "$PORT" "$FIX/$1" "$2" >/dev/null 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
}

check() {  # check <name> <expected-exit> <actual-exit> <report-file-or-empty> <expected-text-or-empty>
  local name="$1" want="$2" got="$3" report="$4" text="$5"
  local ok=1
  [[ "$got" == "$want" ]] || ok=0
  if [[ -n "$text" && -n "$report" ]]; then grep -q -- "$text" "$report" 2>/dev/null || ok=0; fi
  if (( ok )); then PASS=$((PASS+1)); echo "PASS  $name (exit $got)"
  else FAILN=$((FAILN+1)); echo "FAIL  $name (want exit $want, got $got${text:+, want text: $text})"; fi
}

run_scan() {  # run_scan <out-dir> <args...>  -> sets RC
  local out="$1"; shift
  VISION_ONE_BASE_URL="http://127.0.0.1:$PORT" VISION_ONE_API_KEY="${KEY:-test-key}" \
    "$SCAN" --out-dir "$out" "$@" >"$out.log" 2>&1
  RC=$?
}

# 1. Compliant plan, allowlist applied -> pass, 4 accepted findings listed.
start_mock resp-compliant.json test-key
run_scan "$WORK/c1" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$ALLOW"
check "compliant + allowlist passes at MEDIUM" 0 "$RC" "$WORK/c1/report.md" "Accepted by allowlist: 4"

# 2. Same findings, no allowlist -> must fail (the allowlist is what passes it).
run_scan "$WORK/c2" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist /dev/null/none.json
check "compliant without allowlist file is an error" 2 "$RC" "" ""
echo '[]' > "$WORK/empty-allow.json"
run_scan "$WORK/c3" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$WORK/empty-allow.json"
check "compliant with empty allowlist fails at MEDIUM" 1 "$RC" "$WORK/c3/report.md" "BLOCKING candidate"

# 3. Public SSH plan -> fails at MEDIUM (EC2-002 unaccepted).
start_mock resp-public.json test-key
run_scan "$WORK/p1" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$ALLOW"
check "public SSH fails at MEDIUM" 1 "$RC" "$WORK/p1/report.md" "EC2-002"

# 4. Same public SSH plan at HIGH -> passes (shows why the gate must be MEDIUM).
run_scan "$WORK/p2" --plan-json "$FIX/dummy-plan.json" --threshold HIGH --allowlist "$ALLOW"
check "public SSH passes at HIGH (gate level matters)" 0 "$RC" "" ""

# 5. Archive mode uses the same gate.
run_scan "$WORK/p3" --archive "$FIX/dummy-archive.zip" --threshold MEDIUM --allowlist "$ALLOW"
check "archive mode: public SSH fails at MEDIUM" 1 "$RC" "$WORK/p3/report.md" "EC2-002"

# 6. Unaccepted HIGH finding -> fails at MEDIUM.
start_mock resp-high.json test-key
run_scan "$WORK/h1" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$ALLOW"
check "unaccepted HIGH fails at MEDIUM" 1 "$RC" "$WORK/h1/report.md" "EC2-088"

# 7. Zero results -> error, never a pass.
start_mock resp-empty.json test-key
run_scan "$WORK/e1" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$ALLOW"
check "zero results is an error" 2 "$RC" "" ""

# 8. Wrong key -> API error.
start_mock resp-compliant.json test-key
KEY=wrong-key run_scan "$WORK/k1" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$ALLOW"
check "wrong key is an API error" 2 "$RC" "" ""

# 9. Allowlist entry without a reason is rejected.
echo '[{"ruleId":"EC2-021","resource":"aws_instance.this","reason":""}]' > "$WORK/bad-allow.json"
run_scan "$WORK/a1" --plan-json "$FIX/dummy-plan.json" --threshold MEDIUM --allowlist "$WORK/bad-allow.json"
check "allowlist entry without reason is rejected" 2 "$RC" "" ""

# 10. Dry run builds the input without calling the API.
run_scan "$WORK/d1" --plan-json "$FIX/dummy-plan.json" --dry-run
check "dry run does not call the API" 0 "$RC" "" ""

echo ""
echo "Offline tests: $PASS passed, $FAILN failed"
[[ $FAILN -eq 0 ]]
