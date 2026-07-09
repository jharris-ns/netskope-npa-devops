# netskope-npa-devops

A demo repository for the Netskope NPA self-service operating model. One person can
role-play all three personas — **Infrastructure**, **Security**, and **Dev Team** — and walk
through the full self-service flow end to end, including the publisher-cycling procedure.

See `docs/operations-guide.md` for the end-to-end operating guide covering initial deployment,
adding a new application, and zero-downtime publisher replacement.

---

## Deliberate deviations from the production design

> Read these before using this repo as a reference for a real deployment.

| This demo | Production recommendation |
|---|---|
| **One repo**, three personas under `personas/` | **Three separate repos** for true state and access isolation (design doc §4) |
| Publisher cycling is a **sequential shell script** (`cycle-publisher.sh`) | **`repository_dispatch`** fan-out from Infra repo to Dev repos (design doc §8.6.4) |
| **Local Terraform state** per persona (`terraform.tfstate`, gitignored) | **Remote state** (GCS bucket with versioning and locking — see `STATE_MANAGEMENT.md` in the GCP reference repo) |
| **One Netskope API token** for all personas | **Three scoped tokens**, one per persona (design doc §7.3) — see [Multi-token setup](#multi-token-setup) below |

---

## Repository structure

```
netskope-npa-devops/
├── shared/
│   ├── publisher-registry.yaml   # Infra-owned; Dev-team reads to resolve publisher names
│   └── tag-taxonomy.yaml         # Security-owned; guardrail checks and rules derive from this
├── policy/
│   └── check_guardrails.py       # CI guardrail checks run before every dev-team plan
├── personas/
│   ├── 1-infrastructure/         # GCP publisher VMs, Netskope publisher resources
│   ├── 2-security/               # NPA policy groups and access rules
│   └── 3-dev-team/               # Private app definitions for acme-mfg business unit
├── docs/
│   └── operations-guide.md       # End-to-end guide: deploy, onboard apps, cycle publishers
└── scripts/
    ├── set-env.sh                # Maps NETSKOPE_* env vars → TF_VAR_* for Terraform
    └── walkthrough.sh            # Guided end-to-end demo, all three personas
```

---

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5 | All personas |
| gcloud CLI | any | GCP auth for Infrastructure persona |
| Python 3 | >= 3.9 | Guardrail checks |
| yq | >= 4.0 | Publisher registry edits in `cycle-publisher.sh` |
| jq | any | JSON parsing in scripts |

---

## Quick start

### 1. Set credentials

Create `~/.env` with your credentials:

```bash
# ~/.env
NETSKOPE_SERVER_URL=https://your-tenant.goskope.com
NETSKOPE_API_KEY=your-api-token
NETSKOPE_GCP_PROJECT_ID=your-gcp-project-id
```

Then source the helper script in any shell where you run terraform:

```bash
source scripts/set-env.sh
```

### 2. Authenticate to GCP

```bash
gcloud auth application-default login
```

### 3. Run the guided walkthrough (local test mode)

```bash
bash scripts/walkthrough.sh
```

Or step through each persona manually — see each persona's `README.md`.

---

## Personas

Each persona directory is a fully independent Terraform root module. Read the persona's own
README first — they are written to be self-contained.

| Persona | Directory | Owns |
|---|---|---|
| Infrastructure | `personas/1-infrastructure/` | GCP publisher VMs, Netskope publisher records, `shared/publisher-registry.yaml` |
| Security | `personas/2-security/` | NPA policy groups, access rules, `shared/tag-taxonomy.yaml` |
| Dev Team | `personas/3-dev-team/` | Private app definitions for the `acme-mfg` business unit |

---

## How to run

Run `terraform apply` directly from each persona directory, or use the guided walkthrough:

```bash
bash scripts/walkthrough.sh        # Act 1: onboarding scenario
bash scripts/walkthrough.sh --full # Act 1 + Act 2: publisher cycling
```

The `cycle-publisher.sh` script steps through the nine-stage publisher cycling
procedure, applying directly in each persona directory. See
`personas/1-infrastructure/README.md` for the full procedure.

---

## Multi-token setup

The design doc (§7.3) describes creating three scoped Netskope API tokens — one per persona —
to enforce least-privilege boundaries. This demo uses one token for simplicity. To test the
boundary:

1. In the Netskope console, go to **Settings → Administration → API Tokens**
2. Create three tokens with these scopes:
   - **Infra token**: `Infrastructure Management` (publishers)
   - **Security token**: `NPA Policy Management` (rules, groups)
   - **Dev token**: `NPA App Management` (private apps)
3. Set `TF_VAR_netskope_api_key` to the appropriate token before running each persona

---

## Publisher cycling

The eight-stage zero-downtime publisher cycling procedure is documented in
`docs/operations-guide.md` (Part 3) and `personas/1-infrastructure/README.md`.
A helper script is available at `personas/1-infrastructure/scripts/cycle-publisher.sh`
for automating the registry edits and Dev team re-applies.

---

## Acceptance checklist

- [ ] `terraform validate` passes in all three persona directories independently
- [ ] `python policy/check_guardrails.py personas/3-dev-team` fails on `terraform.tfvars.badexample`, passes on `terraform.tfvars.example`
- [ ] `bash scripts/walkthrough.sh` reproduces the §10 scenario in local test mode without manual edits beyond setting credentials
- [ ] Publisher cycling completes all eight stages, ending with `apps_blocking_retirement = []`
- [ ] Each persona README is self-contained (readable without the others)
- [ ] `.gitignore` prevents any real `terraform.tfvars`, state file, or credential from being committed
