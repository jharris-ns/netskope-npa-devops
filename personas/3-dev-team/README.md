# Persona 3 — Dev Team (acme-mfg)

You are the acme-mfg development team. You own your private app definitions. You
resolve which publishers to use through a shared registry — you never hardcode a
publisher name or ID. Nothing in this directory should be touched by Infrastructure
or Security.

## What you own and what you don't

| Yours | Not yours |
|---|---|
| `personas/3-dev-team/` — all Terraform here | `personas/1-infrastructure/` |
| Your private app definitions (`apps.tf`, `terraform.tfvars`) | `personas/2-security/` |
| Choosing which publisher role to use | `shared/publisher-registry.yaml` (read-only for you) |
| Tagging your apps correctly | `shared/tag-taxonomy.yaml` (read-only for you) |

**You do not control:**
- Which physical publishers exist or where they run (that is Infrastructure)
- Which groups can access your apps (that is Security, driven by the tier tag you set)
- What counts as a valid tier (that is Security, via `shared/tag-taxonomy.yaml`)

---

## Prerequisites

| Tool | Notes |
|---|---|
| Terraform >= 1.5 | `terraform -version` |
| Python 3 + PyYAML | `pip install pyyaml` (for the guardrail check) |

**Credentials** — run once per shell session from the repo root:

```bash
source ../../scripts/set-env.sh
```

This reads `~/.env` and exports `TF_VAR_netskope_server_url` and `TF_VAR_netskope_api_key`.

---

## Your first task — onboard two apps

This is the demo scenario: onboard an SSH bastion and a PostgreSQL database for
the acme-mfg business unit.

### 1. Copy and review the example vars

```bash
cp terraform.tfvars.example terraform.tfvars
```

The example is ready to apply as-is for the demo. For a real onboarding, update
the hostnames and ports:

```hcl
environment    = "production"
team_name      = "acme-mfg"
publisher_role = "us-west-primary"   # Must exist in shared/publisher-registry.yaml

client_apps = {
  ssh-bastion = {
    hostname = "bastion.acme.internal"   # FQDN or IP the Netskope client connects to
    port     = "22"                      # Must be a quoted string
    tier     = "infrastructure"          # Must be in shared/tag-taxonomy.yaml approved_tiers
  }
  postgres-orders = {
    hostname = "orders-db.acme.internal"
    port     = "5432"
    tier     = "database-tier"
  }
}
```

Before choosing a `publisher_role` or `tier`, verify the values exist in the
shared files:

```bash
# Check which publisher roles are available
cat ../../shared/publisher-registry.yaml

# Check which tiers are approved
cat ../../shared/tag-taxonomy.yaml
```

**Rules for app config:**
- `port` must be a quoted string (`"22"` not `22`) — the CI guardrail checks this
- `tier` must be in `shared/tag-taxonomy.yaml` → `approved_tiers` — the guardrail checks this
- `publisher_role` must match a role key in `shared/publisher-registry.yaml`
- `clientless_access` is not a variable — it is hardcoded to `false` in `apps.tf`
- Never put a literal `publisher_id` number anywhere — always use the registry lookup

### 2. Run the guardrail check

Always run the guardrail before applying. It validates your config against both
shared files before any changes reach the tenant.

```bash
# Source-only check (fast — no plan needed; catches port and publisher_id issues)
python3 ../../policy/check_guardrails.py .

# Full check with plan (catches tag, tier, and clientless_access issues)
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json
```

### 3. Initialise and apply

```bash
terraform init
terraform apply
```

Terraform reads `shared/publisher-registry.yaml` at plan time, looks up which
publishers are active for your role, and associates your apps with them. You
never touch a publisher name or ID directly.

> **Tag race condition:** If you create multiple apps in the same apply and see an
> error about a duplicate tag key, re-run `terraform apply`. This is a known
> Netskope API behaviour when parallel requests insert the same tag name for the
> first time; the second apply succeeds because the tag row already exists.

### 4. Confirm the apps exist

```bash
terraform output app_names           # Netskope app names
terraform output active_publishers   # Which publishers your apps are on
```

In the Netskope console: **Netskope Private Access → Private Apps** — your apps
should appear with the correct tags.

After you apply, notify the Security team to re-apply their configuration. Their
tag-driven rules will then automatically include your apps — no Security config
change required.

---

## How the publisher registry lookup works

`data-registry.tf` reads `shared/publisher-registry.yaml` and resolves your
`publisher_role` setting to a list of active publisher names. Here is the full
chain:

**Step 1 — You declare a role in `terraform.tfvars`:**
```hcl
publisher_role = "us-west-primary"
```

**Step 2 — Terraform reads the registry file at plan time:**
```yaml
# shared/publisher-registry.yaml (Infrastructure-owned — read-only for you)
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary-v2    # ← resolved to this publisher name
  us-west-secondary:
    active:
      - us-west-dc1-secondary
```

**Step 3 — Terraform looks up the publisher ID by name from the Netskope API
and associates your apps with it.**

You never see a publisher ID. When Infrastructure changes the active publisher
under your role (for example, during a cycling operation), you just re-apply —
the registry update flows through automatically.

**During publisher cycling**, the registry briefly lists two publishers:
```yaml
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary       # Retiring
      - us-west-dc1-primary-v2    # Replacement
```
Your apps are associated with both for the duration of the transition. Sessions
on the old publisher continue uninterrupted while new sessions start on the new one.

---

## Adding a new application

You can add apps at any time without coordinating with Infrastructure or Security,
as long as the tier and publisher role already exist.

### 1. Add the app to `terraform.tfvars`

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

Check `shared/tag-taxonomy.yaml` to confirm the tier is approved before using it:

```bash
cat ../../shared/tag-taxonomy.yaml
```

If the tier you need is not listed, open a PR to add it and ask Security to add
the corresponding rule in their `rules-teams.tf`.

### 2. Run the guardrail and apply

```bash
python3 ../../policy/check_guardrails.py .

terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
python3 ../../policy/check_guardrails.py . --plan-file plan.json

terraform apply plan.tfplan
```

### 3. Notify Security to re-apply

Security runs `terraform apply` in `personas/2-security/`. Their tier rule
automatically picks up the new app — no Security config change needed.

---

## Publisher cycling — your role

During a publisher cycling operation the Infrastructure team will notify you to
re-apply **twice**:

| Stage | What happened | Your action |
|---|---|---|
| **Stage 3** | Infrastructure added the new publisher to the registry. Both publishers are now listed for your role. | `terraform apply` — your apps are now on both publishers |
| **Stage 6** | Infrastructure removed the old publisher from the registry. Only the new publisher remains. | `terraform apply` — your apps are now on the new publisher only |

You do not need to change any configuration. Just re-apply when notified.

```bash
# Stage 3 re-apply (apps on both publishers)
terraform apply

# Verify
terraform output active_publisher_names
# ["us-west-dc1-primary", "us-west-dc1-primary-v2"]

# Stage 6 re-apply (apps on new publisher only)
terraform apply

# Verify
terraform output active_publisher_names
# ["us-west-dc1-primary-v2"]
```

---

## Proving the guardrail works

The `terraform.tfvars.badexample` file is deliberately broken. Use it to confirm the
guardrail catches each type of mistake before you trust it on real config:

```bash
# Generate a plan from the bad example
terraform plan -var-file=terraform.tfvars.badexample -out=bad.tfplan
terraform show -json bad.tfplan > bad.json

# Run the guardrail — expect FAIL on checks 2, 3, and 4
python3 ../../policy/check_guardrails.py . --plan-file bad.json

# Now confirm the good example passes
python3 ../../policy/check_guardrails.py . --plan-file plan.json
```

---

## How to tell it worked

| Signal | Where to look |
|---|---|
| `terraform output app_names` shows your apps | Local terminal |
| Apps appear in Netskope console | Netskope Private Access → Private Apps |
| Apps have all four required tags | Netskope console → app detail view |
| Apps are associated with the correct publisher | `terraform output active_publishers` |
| All guardrail checks pass | `python3 ../../policy/check_guardrails.py . --plan-file plan.json` |
| A user in the right IdP group can reach the app | End-to-end client test |
