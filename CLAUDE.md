# CLAUDE.md — Netskope NPA Self-Service Demo

This file is the primary guide for Claude Code sessions in this repo. Read this before making any changes or answering questions about how the demo works.

---

## What this project demonstrates

This repo models the **Netskope NPA self-service operating model** — a pattern where three teams (Infrastructure, Security, Dev) independently manage their slice of Netskope Network Private Access configuration using Terraform, without stepping on each other.

**The core idea:** Dev teams onboard new private apps by editing their own Terraform directory and running `terraform apply`. They never need to ask Infrastructure which publisher to use (they look it up from a shared registry) and they never need to ask Security to update access rules (the rules are tag-driven and automatically include new apps matching the right tier tag).

The design rationale is documented in `npa-self-service-devops.docx` at the repo root.

---

## Repository structure

```
netskope-npa-devops/
├── shared/
│   ├── publisher-registry.yaml   # Infra writes; Dev reads. Maps role → publisher names.
│   └── tag-taxonomy.yaml         # Security writes. Defines valid tier values and required tags.
├── policy/
│   └── check_guardrails.py       # CI guardrail — run before every dev-team plan.
├── personas/
│   ├── 1-infrastructure/         # GCP publisher VMs + Netskope publisher records
│   ├── 2-security/               # NPA policy groups and tag-driven access rules
│   └── 3-dev-team/               # Private app definitions for the acme-mfg business unit
├── scripts/
│   ├── set-env.sh                # Maps NETSKOPE_* env vars → TF_VAR_* for Terraform
│   └── walkthrough.sh            # Guided end-to-end demo script
└── docs/
    └── scaffolding-notes.md      # Build decisions recorded during scaffolding
```

Each persona directory (`personas/1-*`, `personas/2-*`, `personas/3-*`) is a fully independent Terraform root module. Run `terraform init` separately in each one.

---

## The three-persona model

| Persona | Directory | Owns | Does NOT touch |
|---|---|---|---|
| Infrastructure | `personas/1-infrastructure/` | GCP VMs, Netskope publisher records, `shared/publisher-registry.yaml` | Security rules, private apps |
| Security | `personas/2-security/` | NPA policy groups, access rules, `shared/tag-taxonomy.yaml` | Publishers, private apps |
| Dev Team | `personas/3-dev-team/` | Private app definitions for `acme-mfg` business unit | Publishers, access rules |

**One person can play all three roles** — just `cd` into each persona directory and follow its README.

---

## Key concepts to understand before helping a user

### Publisher registry lookup
Dev teams never hardcode a publisher name or ID. Instead they declare a `publisher_role` (e.g. `"us-west-primary"`) and the Terraform code reads `shared/publisher-registry.yaml` to find the active publisher names for that role. Infrastructure updates the registry; Dev teams just re-apply.

### Tag-driven access model
Security creates access rules that filter apps by tag value (e.g. `tier=database-tier`). When a Dev team creates a new app with the right tier tag and Security re-applies, the app is automatically included in the correct rule — no Security config change needed per app.

### Required tags on every app
Every private app must have exactly four tags: `managed-by-terraform`, the environment name, the tier, and the team name. The CI guardrail checks this before plan.

### The CI guardrail
`policy/check_guardrails.py` runs five checks:
1. No app has `clientless_access = true` (plan JSON)
2. All required tags are present on every app (plan JSON)
3. Every app's tier tag is in `approved_tiers` from `shared/tag-taxonomy.yaml` (plan JSON)
4. All `port` values are quoted strings, not bare integers (raw source files)
5. No literal numeric `publisher_id` anywhere in `.tf` source (raw source files)

Checks 1–3 require a plan file. Checks 4–5 run on source files without a plan.

### `tostring()` requirement
The Netskope provider's `publisher_id` field expects a string. Always use `tostring(p.publisher_id)` when assigning from a data source.

### `enabled = "1"` on NPA rules
The NPA rule resource takes `enabled` as a string `"1"` (enabled) or `"0"` (disabled), not a boolean.

### Count guard on NPA rules
Rules are created with `count = length(local.X_apps) > 0 ? 1 : 0`. The Netskope API rejects creating a rule with an empty `private_apps` list. Rules simply don't exist until there are apps to put in them.

---

## Credential setup (required before any terraform command)

Create `~/.env` with:
```bash
NETSKOPE_SERVER_URL=https://your-tenant.goskope.com/api/v2
NETSKOPE_API_KEY=your-api-token
NETSKOPE_GCP_PROJECT_ID=your-gcp-project-id
```

Then, once per shell session from the repo root:
```bash
source scripts/set-env.sh
```

This maps `NETSKOPE_SERVER_URL` → `TF_VAR_netskope_server_url`, etc. For GCP, also run:
```bash
gcloud auth application-default login
```

---

## Running the demo

### Option A — Guided walkthrough (recommended for first run)

```bash
source scripts/set-env.sh
bash scripts/walkthrough.sh          # Act 1: Infrastructure → Security → Dev onboarding
bash scripts/walkthrough.sh --full   # Act 1 + Act 2: publisher cycling
```

### Option B — Manual step-by-step

**Step 1: Infrastructure (deploy publishers)**
```bash
cd personas/1-infrastructure
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform plan
terraform apply
```

**Step 2: Security (deploy access rules)**
```bash
cd personas/2-security
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars to match your IdP group names
terraform init
terraform plan
terraform apply
```

**Step 3: Dev Team (onboard private apps)**
```bash
cd personas/3-dev-team
cp terraform.tfvars.example terraform.tfvars
# Run the guardrail first
python3 ../../policy/check_guardrails.py .
terraform init
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json
terraform apply
```

**Step 4: Security re-apply (picks up new apps automatically)**
```bash
cd personas/2-security
terraform apply
```

---

## Publisher cycling demo (Act 2)

Publisher cycling replaces a publisher VM with zero app downtime. The 9-stage procedure is automated:

```bash
# First: add the new publisher to var.publishers in personas/1-infrastructure/terraform.tfvars and apply
cd personas/1-infrastructure
terraform apply

# Then run the cycling script
bash scripts/cycle-publisher.sh us-west-dc1-primary us-west-dc1-primary-v2
```

The script updates `shared/publisher-registry.yaml`, triggers Dev-team re-applies at stages 4 and 7, verifies no apps are blocking retirement at stage 8, and prints (but does not run) the destroy command at stage 9.

---

## Proving the guardrail works

```bash
cd personas/3-dev-team

# Generate a plan from the deliberately broken example
terraform plan -var-file=terraform.tfvars.badexample -out=bad.tfplan
terraform show -json bad.tfplan > bad.json
python3 ../../policy/check_guardrails.py . --plan-file bad.json
# Expected: FAIL on checks 2, 3, and 4

# Confirm the good example passes
python3 ../../policy/check_guardrails.py . --plan-file plan.json
# Expected: ALL CHECKS PASSED
```

---

## Common issues and constraints

| Issue | Cause | Fix |
|---|---|---|
| `terraform validate` fails on resource type | `netskope_npa_policy_group` may differ in actual provider schema | Check provider docs or run `terraform providers schema` |
| Publisher delete fails on `terraform destroy` | GCE VMs take 60–90s to disconnect from Netskope | Wait 2 minutes and run `terraform destroy` again (two-pass destroy) |
| Dev-team plan shows 0 resources | Wrong working directory for `terraform plan` | Run from inside `personas/3-dev-team/` |
| Guardrail check 4 flags a port | Port value is `9090` (integer) instead of `"9090"` (string) | Quote all port values in tfvars |
| App not covered by a Security rule | `tier` tag not in `shared/tag-taxonomy.yaml` | Either use an approved tier or ask Security to add a new one |

---

## What NOT to change without understanding the design

- `clientless_access = false` in `personas/3-dev-team/apps.tf` — this is hardcoded by design; it is not a variable
- `shared/tag-taxonomy.yaml` — owned by Security; changes here require adding a matching rule in `personas/2-security/rules-teams.tf`
- `shared/publisher-registry.yaml` — owned by Infrastructure; the cycling script manages edits during publisher transitions
- The `tostring()` wrapper on `publisher_id` — the provider requires a string type
- The `count` guard on NPA rules — removing it will cause apply errors when no apps exist yet
