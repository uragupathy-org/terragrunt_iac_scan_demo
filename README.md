# terragrunt_iac_scan_demo

Deploys an EC2 instance with Terragrunt and scans the **rendered Terraform plan** with the
Trend Vision One Cloud Risk Management Template Scanner in GitHub Actions.

Raw HCL is not scanned. Each unit is planned (`terragrunt plan`), the plan is converted to JSON
(`terragrunt show -json`), and the JSON is sent to `POST /beta/cloudPosture/scanTemplate`
with `type: terraform-template`.

## Layout

```
live/                                   Client repo layer
  root.hcl                              Client-wide config, backend, provider
  client-demo/dev/ap-southeast-2/ec2-web/terragrunt.hcl   Unit: environment values
products/web-tier/                      Product layer (composes modules)
  defaults.hcl                          Static product defaults
  main.tf / variables.tf / outputs.tf
modules/ec2-instance/                   Module layer (EC2, SG, IMDSv2, encrypted gp3)
scanner/scan_plan.sh                    Plan JSON -> scanTemplate -> report + gate
.github/workflows/iac-scan.yml          Fan-out per unit: plan, scan, upload report
```

Input values flow `products/web-tier/defaults.hcl` -> unit `inputs` -> product variables -> module.

## Scanner

```bash
scanner/scan_plan.sh --plan-json plan.json --out-dir out --threshold HIGH [--dry-run]
```

| Env | Purpose |
|-----|---------|
| `VISION_ONE_API_KEY` | API key with Cloud Risk Management View and Configure settings (secret) |
| `VISION_ONE_BASE_URL` | Default `https://api.au.xdr.trendmicro.com` |

Exit codes: `0` pass, `1` findings at or above threshold, `2` usage or API error.
Failing results are counted only when `status == FAILURE` and `ignored` is false.
Risk levels: `LOW < MEDIUM < HIGH < VERY_HIGH < EXTREME`.
The plan is refused if its content exceeds the API's 9,000,000-character limit.

## Run locally

```bash
export AWS_PROFILE=umatrenddemo
cd live/client-demo/dev/ap-southeast-2/ec2-web
terragrunt init
terragrunt plan -out=tfplan
terragrunt show -json tfplan > /tmp/plan.json
cd ../../../../..
VISION_ONE_API_KEY=... scanner/scan_plan.sh --plan-json /tmp/plan.json --out-dir /tmp/scan
```

Replace `VISION_ONE_API_KEY=...` with the key value. Do not commit it.

## GitHub setup

1. Repository secret `VISION_ONE_API_KEY`.
2. The workflow assumes `arn:aws:iam::834797984653:role/github-terragrunt-plan-readonly` via OIDC
   (`ReadOnlyAccess`, plan only; no apply role exists).

**Trust policy caveat:** that role trusts `repo:uragupathy-trend@119544981/terragrunt-ec2-scan@1436654096:*`.
The repo name in this project is `terragrunt_iac_scan_demo`. Either name the remote repo
`terragrunt-ec2-scan` under `uragupathy-trend`, or update the role's trust policy to the new repo
subject (`repo:<owner>/terragrunt_iac_scan_demo:*`). Without this, `configure-aws-credentials` fails.

## Known limitations (demo scope)

- State is local (`terraform.tfstate` per unit); there is no shared remote state or lock.
  For a real client use an S3 backend with DynamoDB locking.
- The dev unit uses the account's default VPC and an `ap-southeast-2a` subnet.
- Apply is not wired; the OIDC role is read-only by design.
- Plan JSON can include sensitive values and is sent to the Vision One cloud. Keep secrets out
  of EC2 user data and inputs, and do not upload plan JSON as an artifact (the workflow uploads only the report).
- The end-to-end API call was tested against a local mock only. It has not been run against the
  live Vision One API, because no API key was available in this environment.
