# terragrunt_iac_scan_demo (flat product)

Deploys one EC2 instance from a **flat** Terraform product (resources are declared directly in
`products/web-tier/main.tf`, with no child module). Before anything is deployed, the Terraform
plan is sent to the Vision One Cloud Risk Management Template Scanner, and the pipeline fails if a
finding is at or above the gate severity.

The module-based version of this demo is in the separate repo `terragrunt_iac_scan_demo_module`.

## 1. Repository layout

```
live/root.hcl                                                 client-wide config: backend, provider
live/client-demo/dev/ap-southeast-2/ec2-web/terragrunt.hcl    unit: one environment's values
products/web-tier/defaults.hcl                                product defaults (static)
products/web-tier/main.tf, variables.tf                       flat product: the Terraform resources
scripts/render_and_plan.sh                                    Terragrunt -> Terraform -> plan -> plan.json
scanner/scan_plan.sh                                          payload, scan, findings, gate
tests/run_offline_tests.sh, tests/live_scan.sh                scanner tests (offline, live)
.github/workflows/iac-scan.yml                                CI: scanner tests, then plan and scan
```

## 2. How the Terragrunt files become Terraform files

Terragrunt is not Terraform. It reads the Terragrunt HCL files (`*.hcl`), resolves them, and writes
plain Terraform files into a separate folder. Terraform then runs in that folder. Nothing Terragrunt
does is written into the repo's `*.tf` files.

The pieces, and what each one contributes:

| File | Terragrunt concept | What it contributes |
|------|--------------------|---------------------|
| `live/root.hcl` | `locals`, `generate` | Client-wide values (region, client name). Writes `backend.tf` and `provider.tf` into the Terraform folder. |
| `products/web-tier/defaults.hcl` | `locals` (read with `read_terragrunt_config`) | Static product defaults: instance type, volume size, AMI filter, tags, ingress settings. |
| `live/.../ec2-web/terragrunt.hcl` | `include`, `terraform.source`, `inputs` | Points at the root config and the product, and sets this environment's `inputs` (name, subnet, VPC, tags), with defaults read from `defaults.hcl`. |
| `products/web-tier/*.tf` | Terraform | The resources (security group, instance, AMI lookup) and their variables. |

## 3. Step-by-step: what `render_and_plan.sh` does

`scripts/render_and_plan.sh live/client-demo/dev/ap-southeast-2/ec2-web` produces a self-contained
Terraform folder at `rendered/live/client-demo/dev/ap-southeast-2/ec2-web/`:

1. **Resolve the unit.** `terragrunt render --json` evaluates the unit, including its `include`,
   `read_terragrunt_config`, `locals`, `inputs` and `generate` blocks. The result is saved as
   `terragrunt-render.json`. Its `inputs` are the resolved values for this environment.
2. **Find the product source.** The render's `terraform.source` (`<repo>//products/web-tier`) gives the
   product folder.
3. **Copy the product's `.tf` files** into the rendered folder. The repo's `modules/` folder is copied
   too, but this flat repo has none, so it is skipped.
4. **Write the generated files.** Each `generate` block becomes a file: `backend.tf` (local state) and
   `provider.tf` (AWS provider, region `ap-southeast-2`, default tags).
5. **Write `terraform.tfvars`.** Each resolved input becomes one HCL assignment, for example
   `tags = {"Product":"web-tier"}`.
6. **Build `rendered-tf.zip`.** An archive of the `.tf` files and `terraform.tfvars`. This is not used by
   the flat pipeline; it is kept for the archive scanner, which the module repo uses.
7. **Plan.** `terraform init`, then `terraform plan -out=tfplan`, then `terraform show -json tfplan >
   plan.json`. The plan JSON is the rendered result with every variable and default resolved. This is the
   file the scanner reads.

The rendered folder ends up with:

```
backend.tf  provider.tf  main.tf  variables.tf  terraform.tfvars   generated / copied Terraform
terragrunt-render.json                                             resolved Terragrunt config
tfplan  plan.json                                                  the plan and its JSON form
rendered-tf.zip                                                    HCL archive (not used here)
```

## 4. Which file is scanned

Only **`plan.json`** is scanned. It is produced in step 7 from the rendered folder, not from the raw
HCL in the repo. The plan JSON has the values Terraform will use, so the scanner evaluates the real
configuration, for example the security group's `ingress` after variables are applied.

The scanner does not read `tfplan` (binary) or the HCL. The workflow uploads only the scan report.

## 5. Payload sent to Vision One

The scanner (`scanner/scan_plan.sh`) sends one request:

```
POST https://api.au.xdr.trendmicro.com/beta/cloudPosture/scanTemplate
Authorization: Bearer <VISION_ONE_API_KEY>
Content-Type: application/json;charset=utf-8
```

The body has two fields. `content` is the whole `plan.json` file, as one JSON string:

```json
{
  "type": "terraform-template",
  "content": "{\"format_version\":\"1.2\",\"terraform_version\":\"1.12.1\",\"variables\":{...},\"planned_values\":{...},\"resource_changes\":[...],\"configuration\":{...}, ...}"
}
```

The `content` string is the full plan JSON, escaped. It is about 12,000 characters for this unit, under
the API's 9,000,000-character limit. The scanner prints the exact body before sending it (step 0).

## 6. The scan result

The API returns `scanResults`. Each result has a `status` (`SUCCESS` or `FAILURE`), a `riskLevel`
(LOW, MEDIUM, HIGH, VERY_HIGH, EXTREME), a `ruleId`, a `resourceType` (for example `aws_instance`), and a
`ruleTitle`. The scanner counts a finding when `status` is `FAILURE` and `ignored` is false.

The report (`report.md`) shows:
- A header with the counts: results returned, SUCCESS and FAILURE, findings, and the gate.
- A findings table with only the FAILURE findings: Severity, Rule, Resource type, Title, Status.
- A collapsible section with all results, SUCCESS and FAILURE, in the same columns.

The console prints the header and the findings table. The full list is in the report file and the job
summary.

## 7. Step-by-step: what the pipeline does

Run locally or in CI:

0. **Payload:** the scanner prints the request body it will send.
1. **Scan:** the plan JSON is sent and the findings table is printed, one row per result.
2. **Gate:** the job fails (exit 1) if any finding is at or above the gate.

The gate defaults to **HIGH**. Set it per run:

- Command line: `scanner/scan_plan.sh --plan-json plan.json --out-dir out --fail-on MEDIUM`
- Environment: `FAIL_ON=MEDIUM`
- GitHub: "Run workflow" has a `fail_on` input.

Precedence: `--fail-on` beats `FAIL_ON`, which beats the default `HIGH`.
Severity order: LOW < MEDIUM < HIGH < VERY_HIGH < EXTREME.

Exit codes: `0` pass, `1` findings at or above the gate, `2` error. A response with zero results is
an error, never a pass.

## 8. Run locally

```bash
export AWS_PROFILE=umatrenddemo
scripts/render_and_plan.sh live/client-demo/dev/ap-southeast-2/ec2-web

export VISION_ONE_API_KEY='<key>'          # set in your terminal, never commit it
scanner/scan_plan.sh --plan-json rendered/live/client-demo/dev/ap-southeast-2/ec2-web/plan.json \
  --out-dir scan-output --fail-on HIGH

# payload only, no API call:
scanner/scan_plan.sh --plan-json rendered/live/client-demo/dev/ap-southeast-2/ec2-web/plan.json \
  --out-dir scan-output --dry-run
```

## 9. Tests

- `tests/run_offline_tests.sh`: 17 offline tests of the scanner, against a local mock of the API. No key
  or AWS needed. Each test prints the scanner's full output (payload, findings, gate). Use `--quiet`
  for PASS/FAIL only.
- `tests/live_scan.sh`: against the real API, with `VISION_ONE_API_KEY` and AWS read-only access. It
  renders the unit, makes a public-SSH plan for comparison, and checks the gate results.

## 10. GitHub setup and OIDC role

The workflow logs in to AWS with OpenID Connect (no stored AWS keys). Two things must exist in GitHub,
and one role must exist in AWS.

### 10.1 Repository settings

| Type | Name | Value |
|------|------|-------|
| Variable | `AWS_ROLE_ARN` | ARN of the read-only plan role, for example `arn:aws:iam::834797984653:role/github-terragrunt-plan-readonly` |
| Secret | `VISION_ONE_API_KEY` | Vision One API key with Cloud Risk Management view and configure permissions |

Set them under **Settings > Secrets and variables > Actions** (variables tab for `AWS_ROLE_ARN`), or from
the command line:

```bash
gh variable set AWS_ROLE_ARN --repo uragupathy-org/terragrunt_iac_scan_demo \
  --body "arn:aws:iam::834797984653:role/github-terragrunt-plan-readonly"
gh secret set VISION_ONE_API_KEY --repo uragupathy-org/terragrunt_iac_scan_demo
```

If `AWS_ROLE_ARN` is missing, the first step of the job fails with a message that points here.

### 10.2 Create the OIDC role (one time, run by an IAM admin)

The role's trust policy must match the subject GitHub puts in the token for this repository. The
subject has the form:

```
repo:<owner>@<owner-id>/<repo>@<repo-id>:*
```

**a. Find the owner and repo IDs** (requires `gh auth login`):

```bash
gh api repos/uragupathy-org/terragrunt_iac_scan_demo --jq '{owner_id: .owner.id, repo_id: .id}'
```

For this repo the values are `owner_id: 320367889` and `repo_id: 1461166536`.

**b. Write the trust policy.** `github-trust-policy.json` in this repo is already set to this subject.
If you use a different repo, change the `sub` value to the form above:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::834797984653:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
        "StringLike": { "token.actions.githubusercontent.com:sub": "repo:uragupathy-org@320367889/terragrunt_iac_scan_demo@1461166536:*" }
      }
    }
  ]
}
```

The IAM OIDC provider `token.actions.githubusercontent.com` must already exist in the account. It
does for umatrenddemo (`834797984653`). If it doesn't, create it with
`aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com --thumbprint-list <thumbprint>`.

**c. Create the role and attach a read-only policy.** The role only plans; it cannot change resources:

```bash
AWS_PROFILE=umatrenddemo aws iam create-role \
  --role-name github-terragrunt-plan-readonly \
  --description "Read-only role for Terragrunt plan in terragrunt_iac_scan_demo (GitHub Actions OIDC)" \
  --assume-role-policy-document file://github-trust-policy.json

AWS_PROFILE=umatrenddemo aws iam attach-role-policy \
  --role-name github-terragrunt-plan-readonly \
  --policy-arn arn:aws:iam::aws:policy/ReadOnlyAccess
```

To change the trust of an existing role, use `aws iam update-assume-role-policy` with the same file.

**d. Check the trust policy:**

```bash
AWS_PROFILE=umatrenddemo aws iam get-role --role-name github-terragrunt-plan-readonly \
  --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition.StringLike'
```

The output must show the same `sub` as in the policy file.

**e. Get the role ARN** and set it as the `AWS_ROLE_ARN` variable (section 10.1):

```bash
AWS_PROFILE=umatrenddemo aws iam get-role --role-name github-terragrunt-plan-readonly --query Role.Arn --output text
```

### 10.3 Troubleshooting

- **`Not authorized to perform sts:AssumeRoleWithWebIdentity`:** the `sub` in the trust policy does not
  match the token. Compare the subject from section 10.2 (owner and repo IDs, not names) with the trust
  policy.
- **`AWS_ROLE_ARN ... not set`:** add the repository variable (section 10.1).

## 11. Known limitations

- State is local per run. A real deployment needs a shared S3 backend and lock table (approval needed).
- Apply is not wired yet. The plan role is read-only by design.
- The default VPC and an `ap-southeast-2a` subnet of umatrenddemo are hard-coded in the unit.
- `plan.json` contains the planned values. Do not upload it as an artifact; the workflow uploads only
  the report.
