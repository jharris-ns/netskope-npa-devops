# Netskope NPA Self-Service

This repository demonstrates the Netskope NPA self-service operating model — a pattern
where three teams manage their own slice of Network Private Access configuration
independently, without coordinating through a central team for every change.

**The problem it solves:** In a traditional model, a Dev team that wants to expose a
new private application must ask Infrastructure which publisher to use, then ask
Security to update access rules. Both are blocking dependencies that create toil and
slow down onboarding.

**How this model works instead:**

- Dev teams declare a *publisher role* (e.g. `us-west-primary`) rather than a publisher
  name or ID. Infrastructure maintains the mapping from role to physical publisher in
  `shared/publisher-registry.yaml`. When a publisher is replaced, Infrastructure updates
  the registry and Dev teams re-apply — no coordination required.

- Security writes access rules that filter apps by *tier tag* (e.g. `tier=database-tier`)
  rather than by app name. When a Dev team creates a new app with the right tag and
  Security re-applies, the app is automatically covered by the correct rule — no
  Security config change per app.

- A CI guardrail script validates Dev team configuration against both shared files before
  apply runs, catching mistakes (missing tags, unapproved tiers, unquoted ports) before
  they reach the tenant.

The result: a Dev team can onboard a new private application by editing their own
Terraform directory and running `terraform apply`, with no tickets to Infrastructure
or Security.

---

## Repository structure

```
netskope-npa-devops/
├── shared/
│   ├── publisher-registry.yaml   # Infra-owned; Dev team reads to resolve publisher names
│   └── tag-taxonomy.yaml         # Security-owned; defines valid tiers and required tags
├── policy/
│   └── check_guardrails.py       # Validates Dev team config before apply
├── personas/
│   ├── 1-infrastructure/         # GCP publisher VMs + Netskope publisher records
│   ├── 2-security/               # NPA policy groups and tag-driven access rules
│   └── 3-dev-team/               # Private app definitions for the acme-mfg team
├── docs/
│   └── operations-guide.md       # End-to-end guide: deploy, onboard apps, cycle publishers, teardown
└── scripts/
    └── set-env.sh                # Maps NETSKOPE_* env vars to TF_VAR_* for Terraform
```

Each directory under `personas/` is a fully independent Terraform root module with its
own state. Read the persona's `README.md` before running any Terraform commands in it.

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5 | All personas |
| gcloud CLI | any | GCP authentication for Infrastructure persona |
| Python 3 + PyYAML | >= 3.9 | Guardrail script (`pip3 install pyyaml`) |

---

## Quick start

### 1. Set credentials

Create `~/.env`:

```bash
NETSKOPE_SERVER_URL=https://your-tenant.goskope.com
NETSKOPE_API_KEY=your-api-token
NETSKOPE_GCP_PROJECT_ID=your-gcp-project-id
```

Source once per shell session from the repo root:

```bash
source scripts/set-env.sh
```

### 2. Authenticate to GCP

```bash
gcloud auth application-default login
```

### 3. Follow the operations guide

`docs/operations-guide.md` covers the full sequence:

- **Part 1** — Initial deployment (Infrastructure → Security → Dev Team → Security re-apply)
- **Part 2** — Dev Team adding a new application
- **Part 3** — Zero-downtime publisher replacement
- **Part 4** — Teardown

---

## The three personas

| Persona | Directory | Owns |
|---|---|---|
| Infrastructure | `personas/1-infrastructure/` | GCP VMs, Netskope publisher records, `shared/publisher-registry.yaml` |
| Security | `personas/2-security/` | NPA policy groups, access rules, `shared/tag-taxonomy.yaml` |
| Dev Team | `personas/3-dev-team/` | Private app definitions for the `acme-mfg` business unit |

One person can play all three roles — just `cd` into each persona directory in order.

---

## API token scopes

Each persona only needs one scope. Using separate tokens enforces least-privilege
boundaries between teams:

| Persona | Required scope |
|---|---|
| Infrastructure | `Infrastructure Management` |
| Security | `NPA Policy Management` |
| Dev Team | `NPA App Management` |

Create tokens in the Netskope console under **Settings → Administration → API Tokens**,
then set `TF_VAR_netskope_api_key` to the appropriate token before running each persona.
Using a single token for all three personas also works for evaluation.
