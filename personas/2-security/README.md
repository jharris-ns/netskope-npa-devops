# Persona 2 — Security

You are the Security team. You own the NPA access rules and the tag taxonomy that
governs what tiers Dev teams are allowed to use. Nothing in this directory should
be touched by Infrastructure or the Dev team.

## What you own and what you don't

| Yours | Not yours |
|---|---|
| `personas/2-security/` — all Terraform here | `personas/1-infrastructure/` |
| `shared/tag-taxonomy.yaml` — you define approved tiers and required tags | `personas/3-dev-team/` |
| NPA policy groups and access rules | Publisher VMs or GCP infrastructure |
| Which IdP groups can access which tiers | Which specific apps exist |

### How `shared/tag-taxonomy.yaml` connects to the rest of the system

This file is the contract between you and the Dev team. It defines which tier values
are valid and which tags every private app must carry:

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

The CI guardrail (`policy/check_guardrails.py`) validates every Dev team plan against
this file before apply runs. If a Dev team uses a tier that is not listed here, the
guardrail rejects their plan — and even if they bypass the guardrail, the app will
fall through to the catch-all `deny-all` rule at runtime because no allow rule
covers an unapproved tier.

**You do not need to update a rule when a Dev team adds a new app.** The rules
filter apps by tag value. When a Dev team creates an app tagged `tier=database-tier`
and you re-apply, the `database-tier-access` rule automatically includes the new
app — no rule config change needed.

---

## Prerequisites

| Tool | Notes |
|---|---|
| Terraform >= 1.5 | `terraform -version` |

**Credentials** — run once per shell session from the repo root:

```bash
source ../../scripts/set-env.sh
```

This reads `~/.env` and exports `TF_VAR_netskope_server_url` and `TF_VAR_netskope_api_key`.

---

## Your first task — apply policy rules

This sets up the tag-driven access model. Rules are not created until Dev teams
create apps (the Netskope API rejects rules with empty `private_apps` lists), but
the structure is ready: when an app tagged `tier=database-tier` appears, the
`database-tier-access` rule is created on your next apply.

### 1. Copy and fill in the example vars

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit the group names to match your IdP exactly:

```hcl
environment = "production"

admin_groups          = ["IT-Administrators"]
web_tier_groups       = ["Engineering"]
database_tier_groups  = ["Database-Admins"]
infrastructure_groups = ["SRE-Team"]
blocked_groups        = []    # e.g. ["Terminated-Users"]
```

> **SCIM provisioning required.** Group names must match groups that are
> SCIM-provisioned into your Netskope tenant. Groups created manually in the
> Netskope console are not recognized by the policy API and will cause apply to
> fail. If your IdP groups are not yet provisioned, leave all group variables as
> empty lists `[]` for the initial demo — rules that require at least one app exist
> but have empty group lists still get created and block no one in the allow path.
>
> If you are running this as a standalone demo without SCIM provisioning, use
> `demo_users` in `terraform.tfvars` to add individual email addresses:
> ```hcl
> demo_users = ["you@example.com"]
> ```
> Note: user emails must also be SCIM-provisioned (synced via the connector) —
> emails for console-only accounts are rejected by the policy API.

### 2. Initialise and apply

```bash
terraform init
terraform plan    # Review: one policy group, catch-all deny rule
terraform apply
```

On first apply with no Dev team apps yet, only the policy group and the catch-all
`deny-all` rule are created. All tier-specific rules will be created on your next
apply after the Dev team onboards their first apps.

### 3. Re-apply after Dev team onboards apps

After the Dev team runs `terraform apply` in `personas/3-dev-team/`, re-apply here:

```bash
terraform apply
# Tier rules are now created and automatically include the new apps
```

This is the key teaching point: you never modify a rule when a Dev team
onboards a new app. The tag-driven model handles it.

```bash
terraform output rules_created    # Shows which rules were created
terraform output apps_by_tier     # Shows which apps are in each tier
```

---

## Understanding the rule structure

Rules are evaluated in this priority order (top = evaluated first):

| Rule | File | Created when |
|---|---|---|
| `deny-blocked-groups` | `rules-deny.tf` | `blocked_groups` non-empty AND apps exist |
| `admin-web-tier` | `rules-admin.tf` | web-tier apps exist |
| `admin-database-tier` | `rules-admin.tf` | database-tier apps exist |
| `admin-infrastructure` | `rules-admin.tf` | infrastructure apps exist |
| `web-tier-access` | `rules-teams.tf` | web-tier apps exist |
| `database-tier-access` | `rules-teams.tf` | database-tier apps exist |
| `infrastructure-access` | `rules-teams.tf` | infrastructure apps exist |
| `deny-all` (catch-all) | `rules-general.tf` | always — created on first apply |

The `count` guard on each tier rule checks only whether apps with that tier tag
exist — it does not check whether the corresponding group variable is non-empty.
This means a rule can be created with an empty `user_groups` list. The rule then
matches all authenticated users for that tier until you populate the group variable.

The catch-all deny rule is the runtime enforcement layer for the tag model. An app
with an unapproved or missing `tier` tag has no matching allow rule and hits this
deny. The CI guardrail (`policy/check_guardrails.py`) catches bad tags before apply;
this rule is the backstop if the guardrail is bypassed.

---

## Managing the tag taxonomy

`shared/tag-taxonomy.yaml` defines which tier values are valid and which tags are
required on every app. You own this file.

**To add a new tier:**

1. Add it to `approved_tiers` in `shared/tag-taxonomy.yaml`
2. Add a corresponding rule block in `rules-teams.tf` (copy the pattern from an existing tier)
3. Add a group variable in `variables.tf` and `terraform.tfvars`
4. Apply

Dev teams can use the new tier immediately after your apply — their apps will be
covered by the new rule automatically on their next apply.

**Do not** add a tier to the taxonomy without also adding the corresponding rule.
Apps using the new tier would pass the guardrail check but fall through to `deny-all`
at runtime until the rule is added.

---

## Publisher cycling

Security has **no direct action** in the publisher cycling sequence.
Your rules reference apps by name (via the data source), not by publisher. When the
Infrastructure team updates `shared/publisher-registry.yaml` and the Dev team
re-applies, app-publisher associations change transparently — your rules are unaffected.

You may want to re-apply after a cycling operation completes to confirm the
`apps_by_tier` output still looks correct, but it is not required.

---

## How to tell it worked

| Signal | Where to look |
|---|---|
| `rules_created` output shows expected rules as `true` | `terraform output rules_created` |
| `apps_by_tier` groups apps correctly by tier | `terraform output apps_by_tier` |
| Policy group visible in Netskope console | Netskope Private Access → NPA Rules |
| Rules appear under the policy group | Netskope console → NPA Rules |
| A user in `web_tier_groups` can reach a `web-tier` app | End-to-end client test |
| A user not in any group is blocked | End-to-end client test (expect block) |
