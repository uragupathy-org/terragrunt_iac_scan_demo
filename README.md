# terragrunt_iac_scan_demo (flat product)

Deploys one EC2 instance from a flat Terraform product (resources declared directly in
`products/web-tier/main.tf`), and scans its Terraform plan with the Vision One Cloud Risk Management
Template Scanner before anything is deployed. The module-based version is in
`terragrunt_iac_scan_demo_module`.

## Pipeline

0. **Payload:** the exact request body sent to the scanner is printed.
1. **Scan:** the plan (`terraform show -json`) is sent to
   `POST /beta/cloudPosture/scanTemplate`, and the findings are printed.
2. **Gate:** the job fails if any finding is at or above the gate severity.

The gate defaults to **HIGH**. Set it per run:

- **CLI:** `scanner/scan_plan.sh --plan-json plan.json --out-dir out --fail-on MEDIUM`
- **Environment:** `FAIL_ON=MEDIUM`
- **Manual GitHub run:** choose `fail_on` in the "Run workflow" form

Precedence: `--fail-on` beats `FAIL_ON`, which beats the default `HIGH`.

Severity order: LOW < MEDIUM < HIGH < VERY_HIGH < EXTREME.

Exit codes: `0` pass, `1` findings at or above the gate, `2` error (including zero results from the
API, which is never treated as a pass).

## Layout

```
live/root.hcl                                                client-wide config (backend, provider)
live/client-demo/dev/ap-southeast-2/ec2-web/terragrunt.hcl   unit: environment values
products/web-tier/                                           flat product
scripts/render_and_plan.sh                                   render the unit and plan it
scanner/scan_plan.sh                                         payload, scan, findings, gate
tests/run_offline_tests.sh                                   offline tests (no key, no AWS)
tests/live_scan.sh                                           live test against the real API
.github/workflows/iac-scan.yml                               scanner tests, then plan and scan
```

## Run locally

```bash
export AWS_PROFILE=umatrenddemo
scripts/render_and_plan.sh live/client-demo/dev/ap-southeast-2/ec2-web
export VISION_ONE_API_KEY='<key>'          # set in your terminal, never commit it
scanner/scan_plan.sh --plan-json rendered/live/client-demo/dev/ap-southeast-2/ec2-web/plan.json \
  --out-dir scan-output --fail-on HIGH
```

## Tests

- `tests/run_offline_tests.sh`: 13 offline tests of the scanner, against a local mock of the API.
  Runs in CI before the scan.
- `tests/live_scan.sh`: live test against the real API. Needs `VISION_ONE_API_KEY` and AWS read-only
  access.

## GitHub setup

- Secret: `VISION_ONE_API_KEY`.
- OIDC plan role: `arn:aws:iam::834797984653:role/github-terragrunt-plan-readonly`, trusting
  `repo:uragupathy-trend/terragrunt_iac_scan_demo:*`.

## Known limitations

- State is local per run. No shared state or lock; a real deployment needs an S3 backend and a lock
  table (approval needed to create them).
- Apply is not wired yet. The plan role is read-only by design.
- The default VPC and an `ap-southeast-2a` subnet of umatrenddemo are hard-coded in the unit.
- The allowlist and debugging scripts from earlier were removed to keep this repo simple; they
  remain in git history (commit `0e5d689`).
