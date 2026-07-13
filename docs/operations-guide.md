# Netskope NPA Self-Service — Operations Guide

This guide covers everything needed to run the NPA self-service operating model
end-to-end: initial deployment, onboarding a new application, replacing a publisher
with zero app downtime, and tearing everything down.

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
    └── check_guardrails.py       ← Validation script (Dev Team runs before apply)
```

### How the shared files connect the three personas

**`shared/publisher-registry.yaml`** is the contract between Infrastructure and
the Dev Team. Infrastructure registers publishers with Netskope and writes their
names here, keyed by role. The Dev Team declares a role name — Terraform looks up
the active publishers for that role at plan time. No publisher name or ID ever
appears in Dev Team config.

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

Create `~/.env`:

```bash
NETSKOPE_SERVER_URL=https://your-tenant.goskope.com/api/v2
NETSKOPE_API_KEY=your-api-token
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

Run these steps in order. Each persona is an independent Terraform root module —
`cd` into the directory before running any Terraform commands in it.

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
> `-refresh=false` to avoid a known provider issue:
> `terraform apply -refresh=false`

### Step 2: Security — deploy access rules

```bash
cd personas/2-security
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` to set your IdP group names. **Group names must exactly
match your identity provider** — wrong names create rules that silently never match.
Groups must be SCIM-provisioned into the Netskope tenant; groups created manually
in the console are not recognized by the policy API.

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

On first apply with no Dev Team apps yet, only the policy group and the catch-all
deny rule are created. The tier-specific allow rules are created later in Step 4,
once apps exist to put in them.

**Verify:**

```bash
terraform output rules_created    # deny_all = true; tier rules = false (expected at this stage)
terraform output approved_tiers   # Tiers read from shared/tag-taxonomy.yaml
```

### Step 3: Dev Team — onboard private apps

```bash
cd personas/3-dev-team
cp terraform.tfvars.example terraform.tfvars
```

Before editing, understand the two values that connect your config to the shared files:

- **`publisher_role`** is a logical name, not a publisher name or ID. Terraform reads
  `shared/publisher-registry.yaml` at plan time and resolves the role to the active
  publisher list maintained by Infrastructure. You never need to know a publisher name
  or ID — when Infrastructure replaces a publisher, they update the registry and you
  re-apply with no config change.

- **`tier`** on each app must match a value in `approved_tiers` in
  `shared/tag-taxonomy.yaml`. Security's access rules filter by this tag — setting
  the right tier is how your app gets picked up by the correct rule automatically.

Edit `terraform.tfvars`:

```hcl
environment    = "production"
team_name      = "acme-mfg"
publisher_role = "us-west-primary"   # Must exist in shared/publisher-registry.yaml

client_apps = {
  ssh-bastion = {
    hostname = "bastion.acme.internal"
    port     = "22"             # Must be a quoted string — guardrail checks this
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

# Source-only check (no plan needed — catches port and publisher_id issues)
python3 ../../policy/check_guardrails.py .

# Full check with plan (catches tag and tier issues)
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json

# Apply
terraform apply plan.tfplan
```

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

Security's Terraform re-reads all private apps from the tenant, finds the new apps
and their tier tags, and creates the tier-specific allow rules automatically. **No
Security config change is required** — this is the tag-driven self-service model in
action.

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
Security. The only requirement is that the tier and publisher role already exist in
the shared files.

### 1. Add the app to terraform.tfvars

Check `shared/tag-taxonomy.yaml` to confirm the tier is approved:

```bash
cat ../../shared/tag-taxonomy.yaml
```

Then add the app:

```hcl
client_apps = {
  # ... existing apps ...

  web-portal = {
    hostname = "portal.acme.internal"
    port     = "443"
    tier     = "web-tier"   # Must be in shared/tag-taxonomy.yaml approved_tiers
  }
}
```

If the tier you need is not listed in `tag-taxonomy.yaml`, open a PR to add it and
ask Security to add the corresponding rule in `rules-teams.tf`. See the Appendix for
the full procedure.

### 2. Run the guardrail and apply

```bash
python3 ../../policy/check_guardrails.py .

terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json

terraform apply plan.tfplan
```

### 3. Notify Security to re-apply

Security runs `terraform apply` in `personas/2-security/`. The tier rule for your
app's tier automatically picks up the new app — no Security config change needed.

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

Apply:

```bash
cd personas/1-infrastructure
terraform apply -refresh=false
```

The new VM bootstraps and registers with Netskope (~5–10 minutes). Verify the new
publisher shows **Connected** in the Netskope console before proceeding.

```bash
terraform output netskope_publisher_ids   # Confirms ID assigned to primary-v2
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

Terraform reads the updated registry and associates each app with both publishers.
Existing sessions on the old publisher continue uninterrupted.

```bash
terraform output active_publisher_names
# ["us-west-dc1-primary", "us-west-dc1-primary-v2"]
```

### Stage 4 — Verify the new publisher is serving traffic

Confirm the new publisher shows **Connected** and is actively handling requests in
the Netskope console. Allow time for existing sessions to migrate naturally before
proceeding.

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

```bash
cd personas/1-infrastructure
terraform apply -refresh=false -var="retiring_publisher_name=us-west-dc1-primary"
terraform output apps_blocking_retirement
# Must be [] before proceeding
```

If the list is non-empty, the Dev Team apply did not complete successfully. Return
to Stage 5 and ensure it completed without errors.

### Stage 8 — Destroy the old publisher

Remove the retiring entry from `terraform.tfvars`:

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
Netskope publisher record. If the publisher delete fails because the VM is still
showing Connected, wait 2 minutes and apply again.

---

## Part 4 — Teardown

Destroying all three personas requires running them in a specific order. The Netskope
API enforces referential integrity: it will not delete a private app that is still
referenced by a policy rule, and it will not delete a publisher that still has apps
associated with it. Attempting to destroy in the wrong order fails with an explicit
API error.

### Correct destroy order

```
Security → Dev Team → Infrastructure
```

| Step | Persona | Why |
|---|---|---|
| 1 | Security | Removes NPA rules that reference apps. Until these are gone, the API rejects app deletion. |
| 2 | Dev Team | Removes private apps. Publishers are still running so the API accepts the delete. |
| 3 | Infrastructure | Removes Netskope publisher records and GCP VMs. Apps are already gone so publishers have no associations blocking deletion. |

### What happens if you destroy in the wrong order

If you run `terraform destroy` in the Dev Team persona before the Security persona,
the Netskope API rejects the operation:

```
API error: Found reference of private app in policy:production-admin-database-tier,
production-database-tier-access ; Cannot delete private app
```

No changes are made — Terraform exits and the state is unchanged. Destroy the
Security persona first, then retry Dev Team.

### Running the teardown

```bash
# Step 1 — Security
cd personas/2-security
terraform destroy -auto-approve

# Step 2 — Dev Team
cd ../3-dev-team
terraform destroy -auto-approve

# Step 3 — Infrastructure
cd ../1-infrastructure
terraform destroy -refresh=false -auto-approve
```

The `-refresh=false` flag on the Infrastructure destroy avoids a known provider bug
where refreshing existing publisher records returns an unmarshal error. If the
publisher delete fails because a VM is still showing Connected, wait 2 minutes and
run `terraform destroy -refresh=false` again.

---

## Appendix — Reference

### `shared/publisher-registry.yaml`

**Owner:** Infrastructure (write). Dev Team (read-only).

Maps logical publisher roles to physical publisher names registered in the Netskope
tenant. The Dev Team references a role name in their `terraform.tfvars`; Terraform
resolves it to the active publisher list at plan time. During publisher cycling, a
role briefly lists two publishers so Dev Team apps stay continuously associated
throughout the transition.

### `shared/tag-taxonomy.yaml`

**Owner:** Security (write). Dev Team (read-only).

Defines which tier values are valid (`approved_tiers`) and which tags every private
app must carry (`required_tags`). The guardrail script validates Dev Team apps
against this file before apply. Security must add a corresponding rule in
`rules-teams.tf` whenever a new tier is added here.

### Adding a new tier

1. Security adds the tier to `approved_tiers` in `shared/tag-taxonomy.yaml`
2. Security adds a rule block in `personas/2-security/rules-teams.tf`
3. Security adds a group variable in `variables.tf` and `terraform.tfvars`
4. Security applies
5. Dev Team can immediately use the new tier tag — their next apply creates the
   app and Security's next apply automatically covers it with the new rule

### Guardrail checks

`policy/check_guardrails.py` runs five checks before any Dev Team apply:

| Check | What it validates | Requires plan file |
|---|---|---|
| 1 | No app has `clientless_access = true` | Yes |
| 2 | All required tags present on every app | Yes |
| 3 | All tier tags are in `approved_tiers` | Yes |
| 4 | Port values are quoted strings, not integers | No |
| 5 | No literal numeric `publisher_id` in `.tf` source | No |

Checks 4 and 5 run directly on source files. Checks 1–3 require a plan JSON:

```bash
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json
```
