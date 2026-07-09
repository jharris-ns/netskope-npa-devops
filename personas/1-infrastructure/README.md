# Persona 1 — Infrastructure

You are the Infrastructure team. You own the GCP compute layer and the Netskope
publisher records. Nothing in this directory should be touched by Security or
the Dev team.

## What you own and what you don't

| Yours | Not yours |
|---|---|
| `personas/1-infrastructure/` — all Terraform here | `personas/2-security/` |
| `shared/publisher-registry.yaml` — you write it; others read it | `personas/3-dev-team/` |
| GCP VMs, VPC, IAM, Secret Manager secrets | NPA policy rules or access groups |
| Netskope publisher records and tokens | Private app definitions |

### How `shared/publisher-registry.yaml` connects to the rest of the system

This file is the contract between you and the Dev team. When you register a
publisher with Netskope, you write its name here under a logical role:

```yaml
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary-v2
  us-west-secondary:
    active:
      - us-west-dc1-secondary
```

The Dev team reads this file at plan time to resolve their `publisher_role` setting
to actual publisher names. They never see a publisher ID or touch a publisher name
directly. When you cycle a publisher, updating this file is how you signal the
change to the Dev team.

---

## Prerequisites

| Tool | Notes |
|---|---|
| Terraform >= 1.5 | `terraform -version` |
| gcloud CLI | `gcloud auth application-default login` |

**Credentials** — run once per shell session from the repo root:

```bash
source ../../scripts/set-env.sh
```

This reads `~/.env` and exports `TF_VAR_netskope_server_url`, `TF_VAR_netskope_api_key`,
and `TF_VAR_gcp_project_id`. Do not put credentials in `terraform.tfvars`.

---

## Your first task — deploy publishers

This is the starting state: two publishers in `us-west1`, one per role,
matching the seed content in `shared/publisher-registry.yaml`.

### 1. Copy and review the example vars

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit if needed — region, machine type, publisher names
```

The default publisher names (`us-west-dc1-primary`, `us-west-dc1-secondary`) match
the registry exactly. If you use different names, update both `terraform.tfvars`
and `shared/publisher-registry.yaml` so they stay in sync.

### 2. Initialise and apply

```bash
terraform init
terraform plan    # Review: 2 VMs, 2 publisher records, VPC, IAM, secrets
terraform apply
```

Terraform creates the Netskope publisher records first, then writes the registration
tokens to Secret Manager, then creates the GCP VMs. The VMs boot, fetch their tokens,
and register with the tenant automatically (~5–10 minutes after apply completes).

> **Re-applying after initial deployment:** If you need to re-run apply against
> existing publisher records, add `-refresh=false` to avoid a known provider bug
> where refreshing existing publisher records returns an unmarshal error:
> `terraform apply -refresh=false`

### 3. Confirm registration

```bash
terraform output publisher_names          # Names registered with Netskope
terraform output netskope_publisher_ids   # IDs assigned by the tenant
```

In the Netskope console: **Netskope Private Access → Publishers** — both publishers
should show status **Connected** within 10 minutes.

---

## Important: two-pass destroy

Terraform destroys GCP resources before Netskope publisher records. GCE VM termination
takes 60–90 seconds; the Netskope API rejects deleting a publisher still marked
**Connected**. If `terraform destroy` exits with an error on the Netskope publisher
delete, wait ~2 minutes and run it again.

```bash
terraform destroy   # Pass 1 — removes all GCP resources; may error on publisher delete
# wait ~2 minutes
terraform destroy   # Pass 2 — removes the remaining publisher records
```

**Before destroying:** confirm no apps are still associated with the publisher by
running the retirement check (see Publisher cycling Stage 7 below).

---

## Publisher cycling — zero-downtime replacement

Publisher cycling replaces a publisher VM without interrupting running app sessions.
You drive all eight stages. The Dev team re-applies at stages 3 and 6 when you
notify them.

### When to cycle

- Planned maintenance or image update on the underlying VM
- GCP zone retirement
- Machine type or region change

### Stage 1 — Deploy the replacement publisher

Add the new publisher to `terraform.tfvars` alongside the existing one:

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
terraform apply -refresh=false
```

The new VM bootstraps and registers (~5–10 minutes). Verify the new publisher
shows **Connected** in the Netskope console before proceeding.

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

### Stage 3 — Notify the Dev team to re-apply

The Dev team runs `terraform apply` in `personas/3-dev-team/`. Their apps are
now associated with both publishers. Existing sessions on the old publisher
continue uninterrupted.

### Stage 4 — Verify the new publisher is serving traffic

Confirm the new publisher shows **Connected** and is actively handling traffic in
the Netskope console. Allow time for existing sessions to migrate naturally.

### Stage 5 — Remove the old publisher from the registry

Edit `shared/publisher-registry.yaml` to remove the retiring publisher:

```yaml
roles:
  us-west-primary:
    active:
      - us-west-dc1-primary-v2   # Only the new publisher remains
```

### Stage 6 — Notify the Dev team to re-apply again

The Dev team runs `terraform apply` again. Their apps now point only to the new
publisher.

### Stage 7 — Verify no apps are blocking retirement

```bash
terraform apply -refresh=false -var="retiring_publisher_name=us-west-dc1-primary"
terraform output apps_blocking_retirement
# Must be [] before proceeding
```

If the list is non-empty, the Dev team apply did not complete successfully.
Return to Stage 6.

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

This destroys the GCP VM, removes the Secret Manager secret, and deletes the
Netskope publisher record. If the publisher delete fails (still shows Connected),
wait 2 minutes and apply again.

---

## Intentional single-VM replacement

When you need to replace a single publisher VM (new image, re-registration, etc.)
use explicit `-replace` flags — **never** taint or destroy manually:

```bash
# Replace the primary publisher completely (tokens are single-use — all four must go together)
terraform apply \
  -replace='netskope_npa_publisher.this["primary"]' \
  -replace='netskope_npa_publisher_token.this["primary"]' \
  -replace='google_secret_manager_secret_version.publisher_token["primary"]' \
  -replace='google_compute_instance.publisher["primary"]'
```

---

## How to tell it worked

| Signal | Where to look |
|---|---|
| Publishers show **Connected** | Netskope console → Netskope Private Access → Publishers |
| `terraform output publisher_names` returns both names | Local terminal |
| `terraform output netskope_publisher_ids` has IDs | Local terminal |
| `apps_blocking_retirement = []` | After cycling Stage 7 |
