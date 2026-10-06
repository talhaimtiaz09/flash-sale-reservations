# terraform

```
terraform/
├── bootstrap/        # once, locally: state bucket + KMS, CI roles, budget
├── modules/
│   ├── table/        # DynamoDB: on-demand cap, stream, TTL, PITR, sparse live-holds index
│   ├── functions/    # 5 Lambdas, one role each, stream mapping + DLQ, sweeper schedule
│   ├── api/          # HTTP API, stage throttling, access logs
│   └── alarms/       # SNS email, alarms, dashboard
├── envs/
│   └── lab/          # wires the modules
└── .tflint.hcl
```

AWS provider `~> 5.70`, region `us-east-1`. Every resource is tagged
`Project`, `Owner`, `Environment` and `ManagedBy` through provider `default_tags`.

## 1. Bootstrap (once, admin credentials, local state)

The account already has the GitHub OIDC provider; `immutable-ec2-web-tier`'s
bootstrap created it. This bootstrap looks it up by URL and does not manage it.

```bash
cd terraform/bootstrap
aws iam list-open-id-connect-providers         # must list token.actions.githubusercontent.com
cp bootstrap.tfvars.example bootstrap.tfvars   # budget email
terraform init
terraform apply -var-file=bootstrap.tfvars
terraform output
```

This creates the following:

- **State bucket:** versioned, SSE-KMS with a dedicated key, public access
  blocked, non-TLS requests denied. Locking uses S3's native lock file, so
  there's no DynamoDB table.
- **`<project>-gha-plan`:** trusts `repo:talhaimtiaz09/flash-sale-reservations:pull_request`.
  It has `ReadOnlyAccess`, state read, and put/delete on `*.tflock` only.
- **`<project>-gha-apply`:** trusts `repo:...:environment:lab`. It has
  read-only access plus write access to what the lab uses: the one table,
  `flash-sale-reservations-lab-*` functions, roles, queues, rules, alarms, log
  groups and topics, and HTTP APIs in the region. `iam:PassRole` only to Lambda.
- **Monthly cost budget:** $10 by default, emails at 80% actual and 100%
  forecast.

Bootstrap keeps its own state in a local `terraform.tfstate` (gitignored).
Back it up, or migrate it into the bucket afterwards. It stays up between
sessions.

## 2. GitHub setup

- **Repository variables:** `AWS_PLAN_ROLE_ARN`, `AWS_APPLY_ROLE_ARN`,
  `TF_STATE_BUCKET` (from `terraform output`) and `ALARM_EMAIL`.
- **Environment `lab`:** add a required reviewer, and limit deployment branches
  to `main`.

## 3. Apply the lab

```bash
cd terraform/envs/lab
terraform init -backend-config="bucket=<state_bucket>"
TF_VAR_alarm_email=you@example.com terraform plan
```

CI plans and applies with the defaults in `variables.tf`. For a local run with
different settings (short holds for the TTL test, say), copy
`lab.tfvars.example` to `lab.tfvars` (gitignored) or pass `-var`.

Outside of a first local test, changes go through CI. Confirm the SNS
subscription email after the first apply. **Destroy at the end of every
session:**

```bash
TF_VAR_alarm_email=you@example.com terraform destroy
```

## How CI works (`.github/workflows/terraform.yml`)

**Pull request touching `terraform/` or `lambdas/`:**

1. Run `fmt -check`, then `init -backend=false` and `validate` on both roots.
2. Run `tflint --recursive` (AWS ruleset) and `trivy config`.
3. Assume the plan role through OIDC and run `terraform plan`. The Lambda zips
   are built here, so a code change shows up as a function update.
4. Post the plan as a single PR comment that later runs update.

**Push to `main`:** the apply job runs in the `lab` environment. It waits for
the reviewer, assumes the apply role, plans the merged commit and applies that
saved plan.

There are no AWS keys anywhere. Actions are pinned to commit SHAs.

Deliberate lab trade-offs flagged by trivy are suppressed inline with a reason,
as `#trivy:ignore:<ID> <reason>`. They are:

- the AWS-managed key on the table instead of a CMK
- no CMK on SNS or the log groups
- no X-Ray tracing on the functions
- no access logging on the state bucket
- `iam:PassRole` on the apply role (workload roles, Lambda only)

## Validate locally without AWS credentials

```bash
docker run --rm -v "$PWD":/w -w /w/terraform hashicorp/terraform:1.16.5 fmt -check -recursive
docker run --rm -v "$PWD":/w -w /w/terraform/envs/lab hashicorp/terraform:1.16.5 init -backend=false
docker run --rm -v "$PWD":/w -w /w/terraform/envs/lab hashicorp/terraform:1.16.5 validate
```
