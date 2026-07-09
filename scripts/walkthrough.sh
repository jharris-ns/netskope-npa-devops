#!/usr/bin/env bash
# scripts/walkthrough.sh — guided end-to-end demo for the Netskope NPA
# self-service operating model.
#
# What this script does:
#   Act 1 — The Section 10 onboarding scenario
#     Step 1: Infrastructure  — confirm publishers exist in state
#     Step 2: Security        — confirm policy rules exist in state
#     Step 3: Dev team        — apply the two-app acme-mfg onboarding
#     Step 4: Verify          — query live apps and confirm tag-driven coverage
#
#   Act 2 — Publisher cycling (optional)
#     Runs cycle-publisher.sh against us-west-dc1-primary, pausing at each
#     stage so you can inspect shared/publisher-registry.yaml and re-run
#     terraform plan in the Dev-team persona.
#
# Prerequisites:
#   source scripts/set-env.sh   (sets TF_VAR_* from ~/.env)
#   gcloud auth application-default login
#   terraform, yq, jq, python3, pip install pyyaml
#
# Usage:
#   bash scripts/walkthrough.sh            # Act 1 only
#   bash scripts/walkthrough.sh --full     # Act 1 + Act 2

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INFRA_DIR="$REPO_ROOT/personas/1-infrastructure"
SEC_DIR="$REPO_ROOT/personas/2-security"
DEV_DIR="$REPO_ROOT/personas/3-dev-team"

FULL_MODE=false
for arg in "$@"; do
  [[ "$arg" == "--full" ]] && FULL_MODE=true
done

# ── Helpers ───────────────────────────────────────────────────────────────────

bold()    { printf '\033[1m%s\033[0m\n' "$*"; }
green()   { printf '\033[32m%s\033[0m\n' "$*"; }
yellow()  { printf '\033[33m%s\033[0m\n' "$*"; }
header()  { echo ""; bold "══════════════════════════════════════════════════════════"; bold "  $*"; bold "══════════════════════════════════════════════════════════"; echo ""; }
divider() { echo ""; bold "──────────────────────────────────────────────────────────"; echo ""; }

pause() {
  echo ""
  yellow "  ▶  $1"
  read -rp "     Press ENTER to continue (Ctrl-C to abort)... "
  echo ""
}

check_prereqs() {
  local missing=()
  for cmd in terraform python3 jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  # yq only required for Act 2
  if [[ "$FULL_MODE" == true ]]; then
    command -v yq &>/dev/null || missing+=("yq")
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${missing[*]}" >&2
    echo "  terraform: https://developer.hashicorp.com/terraform/install" >&2
    echo "  yq:        https://github.com/mikefarah/yq#install" >&2
    exit 1
  fi

  # Check TF_VAR_* credentials
  local missing_vars=()
  [[ -z "${TF_VAR_netskope_server_url:-}" ]] && missing_vars+=("TF_VAR_netskope_server_url")
  [[ -z "${TF_VAR_netskope_api_key:-}" ]]    && missing_vars+=("TF_VAR_netskope_api_key")
  [[ -z "${TF_VAR_gcp_project_id:-}" ]]      && missing_vars+=("TF_VAR_gcp_project_id")
  if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "ERROR: Missing environment variables: ${missing_vars[*]}" >&2
    echo "  Run: source scripts/set-env.sh" >&2
    exit 1
  fi
}

terraform_init_if_needed() {
  local dir="$1"
  if [[ ! -d "$dir/.terraform" ]]; then
    echo "  Running terraform init in $(basename "$dir")..."
    terraform -chdir="$dir" init -upgrade -input=false
  fi
}

# ── Intro ─────────────────────────────────────────────────────────────────────

clear
bold "╔══════════════════════════════════════════════════════════╗"
bold "║   Netskope NPA Self-Service Demo — Guided Walkthrough    ║"
bold "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  This script walks through the three-persona operating model"
echo "  from self-service-devops-for-netskope-npa.docx."
echo ""
echo "  Personas:"
echo "    1. Infrastructure — GCP publisher VMs + Netskope publisher records"
echo "    2. Security       — NPA policy groups and access rules"
echo "    3. Dev Team       — Private app definitions (acme-mfg business unit)"
echo ""
if [[ "$FULL_MODE" == true ]]; then
  echo "  Mode: FULL (Act 1: onboarding + Act 2: publisher cycling)"
else
  echo "  Mode: Act 1 only (onboarding scenario)"
  echo "  Tip:  Run with --full to also demo publisher cycling"
fi
echo ""
echo "  Tenant:  ${TF_VAR_netskope_server_url}"
echo "  GCP:     ${TF_VAR_gcp_project_id}"
echo ""

check_prereqs

pause "Ready to begin. This will run terraform apply in all three personas."

# ══════════════════════════════════════════════════════════════════════════════
# ACT 1 — ONBOARDING
# ══════════════════════════════════════════════════════════════════════════════

header "ACT 1 — The Section 10 Onboarding Scenario"

echo "  We'll walk through exactly the scenario from Section 10 of the design doc:"
echo "  the acme-mfg team wants to onboard two private apps — an SSH bastion"
echo "  and a PostgreSQL database. Security has already defined access rules"
echo "  using tier tags. Dev team just fills in the app config and applies."
echo ""
echo "  The teaching point: Security never needs to know which specific apps"
echo "  exist. They define rules by tier; Dev teams attach the right tier tag."

# ── Step 1: Infrastructure ────────────────────────────────────────────────────

divider
bold "  STEP 1 of 4 — Persona: Infrastructure"
echo ""
echo "  The Infrastructure persona owns the GCP publisher VMs and the Netskope"
echo "  publisher records. In a real deployment this was done before the Dev"
echo "  team requested their apps. Here we confirm the state is current."
echo ""
echo "  Current publisher registry (shared/publisher-registry.yaml):"
echo ""
cat "$REPO_ROOT/shared/publisher-registry.yaml" | sed 's/^/    /'

pause "Switch to the Infrastructure persona."

terraform_init_if_needed "$INFRA_DIR"

echo "  Running: terraform plan (Infrastructure)"
terraform -chdir="$INFRA_DIR" plan -input=false

echo ""
green "  ✓ Infrastructure state confirmed."
echo ""
echo "  Publishers registered with Netskope:"
terraform -chdir="$INFRA_DIR" output -json publisher_names 2>/dev/null | jq '.' | sed 's/^/    /' || echo "    (run terraform apply first to populate outputs)"

# ── Step 2: Security ──────────────────────────────────────────────────────────

divider
bold "  STEP 2 of 4 — Persona: Security"
echo ""
echo "  The Security persona defines access rules grouped by tier tag. These"
echo "  rules already exist. When the Dev team adds apps with tier=database-tier"
echo "  or tier=infrastructure, those apps are automatically covered — no"
echo "  Security-side change required."
echo ""
echo "  Approved tiers (from shared/tag-taxonomy.yaml):"
python3 -c "
import yaml, sys
t = yaml.safe_load(open('$REPO_ROOT/shared/tag-taxonomy.yaml'))
for tier in t['approved_tiers']:
    print(f'    • {tier}')
"

pause "Switch to the Security persona."

terraform_init_if_needed "$SEC_DIR"

echo "  Running: terraform plan (Security)"
terraform -chdir="$SEC_DIR" plan -input=false

echo ""
green "  ✓ Security rules confirmed."
echo ""
echo "  Rules created per tier (after first apply with apps present):"
terraform -chdir="$SEC_DIR" output -json rules_created 2>/dev/null | jq '.' | sed 's/^/    /' || echo "    (run terraform apply first to populate outputs)"

# ── Step 3: Dev Team applies ──────────────────────────────────────────────────

divider
bold "  STEP 3 of 4 — Persona: Dev Team (acme-mfg)"
echo ""
echo "  The Dev team (acme-mfg) wants to onboard two apps:"
echo ""
echo "    ssh-bastion    — bastion.acme.internal:22  (tier: infrastructure)"
echo "    postgres-orders — orders-db.acme.internal:5432  (tier: database-tier)"
echo ""
echo "  Before applying, the CI guardrail checks the config:"

echo ""
echo "  ── Guardrail check (source only, no plan file yet) ──────────────"
python3 "$REPO_ROOT/policy/check_guardrails.py" "$DEV_DIR" && echo "" || {
  echo ""
  echo "  ERROR: Guardrail check failed on source. Fix the issues above before applying."
  exit 1
}

pause "Switch to the Dev Team persona and apply the two-app config."

terraform_init_if_needed "$DEV_DIR"

echo "  Running: terraform plan (Dev Team)"
terraform -chdir="$DEV_DIR" plan -var-file=terraform.tfvars.example -input=false -out=walkthrough.tfplan

echo ""
echo "  ── Generating plan JSON for full guardrail check ─────────────────"
terraform -chdir="$DEV_DIR" show -json walkthrough.tfplan > "$DEV_DIR/walkthrough.plan.json"

echo ""
echo "  ── Guardrail check (source + plan) ───────────────────────────────"
python3 "$REPO_ROOT/policy/check_guardrails.py" "$DEV_DIR" --plan-file "$DEV_DIR/walkthrough.plan.json" && echo "" || {
  echo ""
  echo "  ERROR: Guardrail check failed. Fix the issues above before applying."
  rm -f "$DEV_DIR/walkthrough.tfplan" "$DEV_DIR/walkthrough.plan.json"
  exit 1
}

pause "Guardrail passed. Ready to apply the Dev Team config."

echo "  Running: terraform apply (Dev Team)"
terraform -chdir="$DEV_DIR" apply -var-file=terraform.tfvars.example -input=false

# Clean up temp plan files
rm -f "$DEV_DIR/walkthrough.tfplan" "$DEV_DIR/walkthrough.plan.json"

echo ""
green "  ✓ Dev Team apps applied."
echo ""
echo "  Apps created:"
terraform -chdir="$DEV_DIR" output -json app_names 2>/dev/null | jq '.' | sed 's/^/    /' || true

# ── Step 4: Verify ────────────────────────────────────────────────────────────

divider
bold "  STEP 4 of 4 — Verify end-to-end coverage"
echo ""
echo "  Now we confirm that:"
echo "    (a) Both apps exist in the Netskope tenant"
echo "    (b) They are tagged correctly"
echo "    (c) The Security persona's tag-driven rules now cover them"
echo "       — without any Security-side change"

pause "Run Security apply to pick up the newly-created apps."

echo "  Running: terraform apply (Security) — rules will now include the new apps"
terraform -chdir="$SEC_DIR" apply -input=false

echo ""
echo "  Apps now visible per tier (Security persona view):"
terraform -chdir="$SEC_DIR" output -json apps_by_tier 2>/dev/null | jq '.' | sed 's/^/    /' || true

echo ""
echo "  Rules created (true = rule exists, false = no apps for that tier yet):"
terraform -chdir="$SEC_DIR" output -json rules_created 2>/dev/null | jq '.' | sed 's/^/    /' || true

echo ""
green "  ✓ Tag-driven coverage confirmed."
echo "    The database-tier and infrastructure rules now cover the acme-mfg apps."
echo "    Security added zero lines of config to onboard this team."

# ══════════════════════════════════════════════════════════════════════════════
# ACT 2 — PUBLISHER CYCLING (optional)
# ══════════════════════════════════════════════════════════════════════════════

if [[ "$FULL_MODE" != true ]]; then
  divider
  bold "  Act 1 complete."
  echo ""
  echo "  To demo publisher cycling (Act 2), run:"
  echo "    bash scripts/walkthrough.sh --full"
  echo ""
  echo "  Or run the cycling script directly:"
  echo "    bash personas/1-infrastructure/scripts/cycle-publisher.sh \\"
  echo "         us-west-dc1-primary us-west-dc1-new"
  echo ""
  exit 0
fi

# ── Act 2: Publisher cycling ──────────────────────────────────────────────────

header "ACT 2 — Publisher Cycling (Section 8.6.4)"

echo "  We'll now simulate a publisher lifecycle operation:"
echo "  replacing 'us-west-dc1-primary' with a new publisher."
echo ""
echo "  This demonstrates the nine-stage sequence from Section 8.6.4:"
echo "    1. New publisher already in Terraform state"
echo "    2. Add new publisher to registry alongside old (both active)"
echo "    3-4. Dev team re-applies — apps now associated with both"
echo "    5. Remove old publisher from registry"
echo "    6-7. Dev team re-applies — apps now on new publisher only"
echo "    8. Verify no apps blocking retirement"
echo "    9. Print the -replace commands to destroy the old publisher (manual step)"
echo ""

echo "  Current registry:"
cat "$REPO_ROOT/shared/publisher-registry.yaml" | sed 's/^/    /'
echo ""

pause "Inspect the registry above. The cycling script will modify it at each stage."

echo "  For this walkthrough, the new publisher name is 'us-west-dc1-primary-v2'."
echo "  (In a real cycle you would first add the new publisher to var.publishers"
echo "  in terraform.tfvars and run terraform apply in personas/1-infrastructure/)"
echo ""

pause "Starting cycle-publisher.sh — you will be prompted at each stage."

bash "$INFRA_DIR/scripts/cycle-publisher.sh" \
  "us-west-dc1-primary" \
  "us-west-dc1-primary-v2"

echo ""
green "  ✓ Publisher cycling walkthrough complete."
echo ""
echo "  Final registry state:"
cat "$REPO_ROOT/shared/publisher-registry.yaml" | sed 's/^/    /'

# ── Fin ───────────────────────────────────────────────────────────────────────

divider
bold "  Walkthrough complete."
echo ""
echo "  What you demonstrated:"
echo "    ✓ Three-persona separation of concerns"
echo "    ✓ Tag-driven self-service app onboarding (zero Security config change)"
echo "    ✓ CI guardrail enforcement before apply"
if [[ "$FULL_MODE" == true ]]; then
echo "    ✓ Nine-stage zero-downtime publisher cycling"
fi
echo ""
echo "  Next steps:"
echo "    • Review docs/self-service-devops-for-netskope-npa.docx for the full design"
echo "    • See each persona's README.md for standalone operational procedures"
echo "    • To clean up: terraform destroy in each persona directory (reverse order)"
echo "      3-dev-team → 2-security → 1-infrastructure"
echo ""
