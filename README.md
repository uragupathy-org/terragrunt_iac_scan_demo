# terragrunt_iac_scan_demo (flat product, expected to PASS the scan)

Deploys one EC2 instance from a **flat** Terraform product: resources are declared directly in
`products/web-tier/main.tf`, with no child module. The Vision One Template Scanner evaluates this
layout's plan JSON, so the pipeline can gate on real findings.

The module-based version of this demo is in the separate repo `terragrunt_iac_scan_demo_module`,
which is expected to fail the scan.

## Layout

```
live/root.hcl                                          client-wide config (backend, provider)
live/client-demo/dev/ap-southeast-2/ec2-web/terragrunt.hcl   unit: environment values
products/web-tier/                                     flat product (defaults.hcl, main.tf, ...)
scripts/render_and_plan.sh                             render unit to Terraform, plan, export plan JSON
scanner/scan_plan.sh                                   scan plan JSON or HCL archive with Vision One
.github/workflows/iac-scan.yml                         PR: render, plan, scan; reports uploaded
```

## Scan gate

- Threshold: `MEDIUM` (workflow `SCAN_THRESHOLD`, and scanner default). Any unaccepted
  MEDIUM or higher finding fails the build.
- Zero results from the API is an error (exit 2), never a pass.
- Accepted findings (allowlist): not yet implemented, pending a decision.

## Tests

- `tests/run_offline_tests.sh`: 11 offline tests of the scan gate, against a local mock of the API.
  Runs in CI as the `scanner-tests` job before any scan.
- `tests/live_scan.sh`: live test against the real API (needs `VISION_ONE_API_KEY` and AWS read-only
  access). Expects the compliant plan to exit 0 and the public-SSH plan to exit 1. It also fetches
  the rule catalogue entry for `EC2-031`, the one allowlist entry not yet verified.

## Run locally

```bash
export AWS_PROFILE=umatrenddemo
scripts/render_and_plan.sh live/client-demo/dev/ap-southeast-2/ec2-web
export VISION_ONE_API_KEY='<key>'   # set in your terminal, never commit it
scanner/scan_plan.sh --plan-json rendered/live/client-demo/dev/ap-southeast-2/ec2-web/plan.json \
  --out-dir scan-output/plan --threshold MEDIUM
```

## GitHub setup

- Secret: `VISION_ONE_API_KEY`.
- OIDC plan role: `arn:aws:iam::834797984653:role/github-terragrunt-plan-readonly`, trusting
  `repo:uragupathy-trend/terragrunt_iac_scan_demo:*`.

## Known limitations

- State is local per run; no shared state or lock. A real deployment needs an S3 backend with a
  lock table (approval needed to create them).
- Apply is not wired yet. The plan role is read-only by design; a separate apply role is planned.
- The default VPC and an `ap-southeast-2a` subnet of umatrenddemo are hard-coded in the unit.
