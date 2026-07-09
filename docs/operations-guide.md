# Netskope NPA Self-Service — Operations Guide

This guide covers everything needed to run the NPA self-service operating model
end-to-end: initial deployment, onboarding a new application, and replacing a
publisher with zero app downtime.

---

## Overview

The self-service model separates Netskope NPA configuration across three teams,
each working in their own Terraform root module with no shared state.

```
netskope-npa-devops/
├── shared/
│   ├── publisher-registry.yaml   ← Infrastructure writes; Dev Team reads
│   └── tag-taxonomy.yaml         ← Security writes; Dev Team reads
├── personas/
│   ├── 1-infrastructure/         ← GCP VMs + Netskope publisher records
│   ├── 2-security/               ← Policy groups + tag-driven access rules
│   └── 3-dev-team/               ← Private app definitions
└── policy/
    └── check_guardrails.py       ← CI validation script (Dev Team runs before apply)
```

### How the shared files connect the three personas

**`shared/publisher-registry.yaml`** is the contract between Infrastructure and
the Dev Team. Infrastructure registers physical publishers with Netskope and writes
their names here, keyed by role. The Dev Team never touches a publisher name or ID
directly — they declare a role, and Terraform looks up the current active publishers
at plan time.

```yaml
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary-v2   # ← Infrastructure updates this
  us-west-secondary:
    active:
      - us-west-dc1-secondary
```

**`shared/tag-taxonomy.yaml`** is the contract between Security and the Dev Team.
Security defines which tier values are valid and which tags every app must carry.
The guardrail script validates Dev Team apps against this file before apply runs.

```yaml
approved_tiers:
  - web-tier
  - database-tier
  - infrastructure

required_tags:
  - managed-by-terraform
  - environment
  - tier
  - team
```

---

## Prerequisites

### Tools

| Tool | Purpose |
|---|---|
| Terraform >= 1.5 | All three personas |
| gcloud CLI | Infrastructure persona (GCP auth, VM access) |
| Python 3 + PyYAML | Guardrail script (`pip3 install pyyaml`) |

### Credentials

Create `~/.env` with:

```bash
export NETSKOPE_SERVER_URL=https://your-tenant.goskope.com/api/v2
export NETSKOPE_API_KEY=your-api-token
```

Run once per shell session from the repo root:

```bash
source scripts/set-env.sh
```

This exports `TF_VAR_netskope_server_url`, `TF_VAR_netskope_api_key`, and
`TF_VAR_gcp_project_id` (falls back to `gcloud config get-value project` if not
set in `~/.env`).

For GCP, also authenticate once:

```bash
gcloud auth application-default login
```

---

## Part 1 — Initial Deployment

Run these steps in order. Each persona is an independent Terraform root module;
`cd` into the directory before running any Terraform commands.

### Step 1: Infrastructure — deploy publishers

```bash
cd personas/1-infrastructure
cp terraform.tfvars.example terraform.tfvars
```

Review `terraform.tfvars`. The key settings:

```hcl
publishers = {
  primary = {
    name = "us-west-dc1-primary"    # Must match shared/publisher-registry.yaml
  }
  secondary = {
    name = "us-west-dc1-secondary"
  }
}
publisher_machine_type = "e2-standard-2"
zones = ["us-west1-b", "us-west1-c"]
```

Apply:

```bash
terraform init
terraform apply
```

Terraform creates Netskope publisher records, writes registration tokens to Secret
Manager, then deploys GCP VMs. The VMs bootstrap automatically and register with
the tenant (~5–10 minutes after apply completes).

**Verify:** In the Netskope console → Netskope Private Access → Publishers, both
publishers should show status **Connected** within 10 minutes.

```bash
terraform output publisher_names          # Names registered with Netskope
terraform output netskope_publisher_ids   # IDs assigned by the tenant
```

> **Note:** If you need to re-run apply after the initial deployment, add
> `-refresh=false` to skip a known provider issue where refreshing existing
> publisher records returns an unmarshal error:
> `terraform apply -refresh=false`

### Step 2: Security — deploy access rules

```bash
cd personas/2-security
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to set your IdP group names. **Group names must exactly
match your identity provider** — wrong names create rules that silently never match.
Groups must be SCIM-provisioned; groups created manually in the Netskope console
are not recognized by the policy API.

```hcl
environment           = "production"
admin_groups          = ["IT-Administrators", "SRE-Team"]
web_tier_groups       = ["Engineering", "Developers"]
database_tier_groups  = ["Database-Admins", "Analytics-Team"]
infrastructure_groups = ["Platform-Engineering", "SRE-Team"]
blocked_groups        = []    # e.g. ["Terminated-Users"]
```

Apply:

```bash
terraform init
terraform apply
```

On first apply with no Dev Team apps, the tier-specific rules are not created (the
count guard prevents empty `private_apps` lists, which the API rejects). The policy
group and deny-all catch-all rule are created immediately.

**Verify:**

```bash
terraform output rules_created    # deny_all = true; all tier rules = false (expected)
terraform output approved_tiers   # Tiers read from shared/tag-taxonomy.yaml
```

### Step 3: Dev Team — onboard private apps

```bash
cd personas/3-dev-team
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
environment    = "production"
team_name      = "acme-mfg"
publisher_role = "us-west-primary"   # Must exist in shared/publisher-registry.yaml

client_apps = {
  ssh-bastion = {
    hostname = "bastion.acme.internal"
    port     = "22"            # Must be a quoted string — guardrail checks this
    tier     = "infrastructure" # Must be in shared/tag-taxonomy.yaml approved_tiers
  }
  postgres-orders = {
    hostname = "orders-db.acme.internal"
    port     = "5432"
    tier     = "database-tier"
  }
}
```

Run the guardrail, then apply:

```bash
terraform init

# Source-only check (no plan needed — catches port/publisher_id issues)
python3 ../../policy/check_guardrails.py .

# Full check with plan (catches tag and clientless_access issues)
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json

# Apply
terraform apply plan.tfplan
```

Terraform reads `shared/publisher-registry.yaml` at plan time, resolves
`publisher_role = "us-west-primary"` to the active publisher list, and associates
your apps with those publishers. You never see or touch a publisher ID.

**Verify:**

```bash
terraform output app_names           # Full app names created in the tenant
terraform output active_publishers   # Which publishers your apps are on
```

### Step 4: Security — re-apply to activate tier rules

```bash
cd personas/2-security
terraform apply
```

The data source re-reads all private apps from the tenant, finds the new apps and
their tier tags, and creates the tier-specific allow rules automatically. **No
Security config change is required** — this is the tag-driven self-service model.

**Verify:**

```bash
terraform output rules_created
# admin_database_tier   = true
# admin_infrastructure  = true
# database_tier_access  = true
# infrastructure_access = true
# deny_all              = true

terraform output apps_by_tier
# database_tier  = ["production-acme-mfg-postgres-orders"]
# infrastructure = ["production-acme-mfg-ssh-bastion"]
```

---

## Part 2 — Dev Team: Adding a New Application

The Dev Team can add apps at any time without coordinating with Infrastructure or
Security. The only requirement is that the tier and publisher role already exist.

### 1. Add the app to terraform.tfvars

```hcl
client_apps = {
  # ... existing apps ...

  web-portal = {
    hostname = "portal.acme.internal"
    port     = "443"
    tier     = "web-tier"    # Must be in shared/tag-taxonomy.yaml approved_tiers
  }
}
```

Check `shared/tag-taxonomy.yaml` to confirm the tier is approved before using it:

```bash
cat ../../shared/tag-taxonomy.yaml
```

If the tier you need is not listed, open a PR to add it to `tag-taxonomy.yaml` and
request Security to add the corresponding rule in `rules-teams.tf`.

### 2. Run the guardrail and apply

```bash
python3 ../../policy/check_guardrails.py .

terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json

terraform apply plan.tfplan
```

### 3. Notify Security to re-apply

Security runs `terraform apply` in `personas/2-security/`. Their `web-tier-access`
rule (if configured) automatically picks up the new app — no Security config change
needed.

### How the publisher lookup works

`data-registry.tf` in the Dev Team persona reads `shared/publisher-registry.yaml`
using a `local_file` data source (or `http` data source in GitHub mode) and parses
the YAML to find active publishers for your role:

```hcl
# terraform.tfvars
publisher_role = "us-west-primary"

# data-registry.tf resolves this to:
# → reads shared/publisher-registry.yaml
# → finds roles.us-west-primary.active
# → returns ["us-west-dc1-primary-v2"]
# → associates apps with that publisher
```

During a publisher cycling operation this list briefly contains two publishers.
Your apps remain continuously reachable throughout the transition.

---

## Part 3 — Publisher Replacement (Zero-Downtime Cycling)

Publisher cycling replaces a publisher VM without interrupting running app sessions.
The procedure has eight stages, all driven by the Infrastructure team.

### When to cycle

- Planned VM maintenance or image update
- GCP zone retirement
- Machine type or region change

### Stage 1 — Deploy the replacement publisher

Add the new publisher to `personas/1-infrastructure/terraform.tfvars` alongside
the existing one:

```hcl
publishers = {
  primary = {
    name = "us-west-dc1-primary"      # Retiring — stays until stage 8
  }
  secondary = {
    name = "us-west-dc1-secondary"
  }
  primary-v2 = {
    name = "us-west-dc1-primary-v2"   # Replacement
  }
}
```

Apply (use `-refresh=false` to avoid the provider refresh bug):

```bash
cd personas/1-infrastructure
terraform apply -refresh=false
```

The new VM bootstraps and registers with Netskope (~5–10 minutes). Verify the new
publisher shows **Connected** in the Netskope console before proceeding.

```bash
terraform output netskope_publisher_ids   # Shows ID for primary-v2
```

### Stage 2 — Dual-list both publishers in the registry

Edit `shared/publisher-registry.yaml` to list both publishers under the role:

```yaml
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary      # Retiring (still active)
      - us-west-dc1-primary-v2   # Replacement (now live)
```

### Stage 3 — Dev Team re-applies (apps on both publishers)

```bash
cd personas/3-dev-team
terraform apply
```

Terraform reads the updated registry and updates each app to be associated with
both publishers. Existing sessions on the old publisher continue uninterrupted.

```bash
terraform output active_publisher_names
# ["us-west-dc1-primary", "us-west-dc1-primary-v2"]
```

### Stage 4 — Verify the new publisher is serving traffic

Confirm the new publisher shows **Connected** and is actively handling requests in
the Netskope console. Allow time for existing sessions to migrate naturally.

### Stage 5 — Remove the old publisher from the registry

Edit `shared/publisher-registry.yaml` to remove the retiring publisher:

```yaml
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary-v2   # Only the new publisher remains
```

### Stage 6 — Dev Team re-applies (apps on new publisher only)

```bash
cd personas/3-dev-team
terraform apply
```

```bash
terraform output active_publisher_names
# ["us-west-dc1-primary-v2"]
```

### Stage 7 — Verify no apps are blocking retirement

Run the retirement check against the old publisher:

```bash
cd personas/1-infrastructure
terraform apply -refresh=false -var="retiring_publisher_name=us-west-dc1-primary"
terraform output apps_blocking_retirement
# Must be [] before proceeding
```

If the list is non-empty, some apps are still associated with the old publisher.
Return to Stage 5 and ensure the Dev Team apply completed successfully.

### Stage 8 — Destroy the old publisher

Remove the old publisher from `terraform.tfvars`:

```hcl
publishers = {
  secondary = {
    name = "us-west-dc1-secondary"
  }
  primary-v2 = {
    name = "us-west-dc1-primary-v2"
  }
  # primary entry removed
}
```

Apply:

```bash
terraform apply -refresh=false
```

This destroys the GCP VM, deletes the Secret Manager secret, and removes the
Netskope publisher record. If the publisher delete fails (still shows Connected),
wait 2 minutes and apply again.

---

## Appendix — Shared File Reference

### `shared/publisher-registry.yaml`

**Owner:** Infrastructure (write). Dev Team (read-only).

Maps logical publisher roles to physical publisher names registered in the Netskope
tenant. During publisher cycling, a role briefly lists two publishers; the Dev Team
re-applies twice to keep apps continuously associated.

```yaml
roles:
  <role-name>:
    active:
      - <publisher-name>      # Exact name from Netskope publisher record
```

### `shared/tag-taxonomy.yaml`

**Owner:** Security (write). Dev Team (read-only).

Defines which tier values are valid and which tags every app must carry. The
guardrail script (`policy/check_guardrails.py`) validates apps against this file
before apply. Security must add a corresponding rule in `rules-teams.tf` whenever
a new tier is added here.

```yaml
approved_tiers:
  - web-tier
  - database-tier
  - infrastructure

required_tags:
  - managed-by-terraform
  - environment
  - tier
  - team
```

### Adding a new tier

1. Security adds the tier to `approved_tiers` in `shared/tag-taxonomy.yaml`
2. Security adds a rule block in `personas/2-security/rules-teams.tf`
3. Security adds a group variable in `variables.tf` and `terraform.tfvars`
4. Security applies
5. Dev Team can immediately use the new tier tag — their next apply creates the
   app and Security's next apply automatically covers it with the new rule

### CI guardrail checks

`policy/check_guardrails.py` runs five checks before any Dev Team apply:

| Check | What it validates | Requires plan file |
|---|---|---|
| 1 | No app has `clientless_access = true` | Yes |
| 2 | All required tags present on every app | Yes |
| 3 | All tier tags are in `approved_tiers` | Yes |
| 4 | Port values are quoted strings (not integers) | No |
| 5 | No literal numeric `publisher_id` in `.tf` source | No |

Checks 4 and 5 run on source files. Checks 1–3 require a plan JSON file:

```bash
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json
```
