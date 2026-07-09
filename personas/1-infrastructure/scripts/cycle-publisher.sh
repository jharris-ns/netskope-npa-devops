#!/usr/bin/env bash
# personas/1-infrastructure/scripts/cycle-publisher.sh
#
# Automates the nine-stage publisher cycling procedure from Section 8.6.4 of the
# design doc (self-service-devops-for-netskope-npa.docx).
#
# Usage:
#   bash scripts/cycle-publisher.sh OLD_PUBLISHER_NAME NEW_PUBLISHER_NAME
#
# Arguments:
#   OLD_PUBLISHER_NAME  The publisher being retired (e.g. us-west-dc1-primary)
#   NEW_PUBLISHER_NAME  The replacement publisher, already in Terraform state
#
# Prerequisites:
#   - source ../../scripts/set-env.sh  (TF_VAR_* must be set)
#   - yq >= 4.0  (https://github.com/mikefarah/yq)
#   - jq
#   - terraform
#   - The new publisher must already exist (terraform apply run first in personas/1-infrastructure/)
#
# DEMO SIMPLIFICATION vs PRODUCTION:
#   In the production multi-repo design (Section 8.6.4), stages that notify Dev repos
#   use `repository_dispatch` events sent via GitHub API. In this single-repo demo,
#   those cross-repo triggers become direct sequential local `terraform apply` steps
#   in personas/3-dev-team/. This is the one intentional simplification relative to
#   the production design; see root README.md.

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────

OLD_PUB="${1:-}"
NEW_PUB="${2:-}"

if [[ -z "$OLD_PUB" || -z "$NEW_PUB" ]]; then
  echo "Usage: bash scripts/cycle-publisher.sh OLD_PUBLISHER_NAME NEW_PUBLISHER_NAME" >&2
  exit 1
fi

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$INFRA_DIR/../.." && pwd)"
DEV_DIR="$REPO_ROOT/personas/3-dev-team"
REGISTRY="$REPO_ROOT/shared/publisher-registry.yaml"

# ── Helpers ───────────────────────────────────────────────────────────────────

pause() {
  echo ""
  echo "────────────────────────────────────────────────────────────"
  echo "$1"
  echo "────────────────────────────────────────────────────────────"
  read -rp "Press ENTER to continue (Ctrl-C to abort)... "
  echo ""
}

announce() {
  echo ""
  echo "══════════════════════════════════════════════════════════════"
  echo "  STAGE $1: $2"
  echo "══════════════════════════════════════════════════════════════"
}

check_deps() {
  local missing=()
  for cmd in yq jq terraform; do
    if ! command -v "$cmd" &>/dev/null; then
      missing+=("$cmd")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${missing[*]}" >&2
    echo "Install yq: https://github.com/mikefarah/yq#install" >&2
    exit 1
  fi
}

dev_team_apply() {
  echo "  Running terraform apply in personas/3-dev-team/..."
  cd "$DEV_DIR"
  terraform apply -auto-approve
  cd "$INFRA_DIR"
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────

check_deps

echo ""
echo "Publisher Cycling Script — Section 8.6.4"
echo "  Retiring : $OLD_PUB"
echo "  Replacing: $NEW_PUB"
echo "  Registry : $REGISTRY"
echo ""

if [[ ! -f "$REGISTRY" ]]; then
  echo "ERROR: Registry not found at $REGISTRY" >&2
  exit 1
fi

cd "$INFRA_DIR"

# ── Stage 1: Confirm new publisher exists ─────────────────────────────────────

announce 1 "Confirm new publisher exists in Terraform state"

echo "  Checking Terraform state for '$NEW_PUB'..."
if ! terraform state list | grep -q "netskope_npa_publisher.this\["; then
  echo "ERROR: No Netskope publishers found in Terraform state." >&2
  echo "Run 'terraform apply' in personas/1-infrastructure/ first to create the new publisher." >&2
  exit 1
fi

# Check the new publisher specifically by looking at the state output
if ! terraform output -json publisher_names 2>/dev/null | jq -e --arg name "$NEW_PUB" '[.[] | values] | map(. == $name) | any' &>/dev/null; then
  echo ""
  echo "WARNING: Could not confirm '$NEW_PUB' in terraform output publisher_names."
  echo "Current publishers in state:"
  terraform output -json publisher_names 2>/dev/null | jq '.' || echo "  (could not read output)"
  echo ""
  pause "If '$NEW_PUB' IS in state, continue. Otherwise Ctrl-C and run terraform apply first."
else
  echo "  ✓ '$NEW_PUB' confirmed in Terraform state."
fi

# ── Stage 2: Add new publisher to registry alongside old ──────────────────────

announce 2 "Add '$NEW_PUB' to registry (both publishers active)"

echo "  Current registry state:"
cat "$REGISTRY"
echo ""

# Find which role contains the old publisher and add the new one alongside it
ROLE=$(yq e ".roles | to_entries | .[] | select(.value.active[] == \"$OLD_PUB\") | .key" "$REGISTRY")

if [[ -z "$ROLE" ]]; then
  echo "ERROR: '$OLD_PUB' not found in any role in $REGISTRY" >&2
  echo "Current registry:"
  cat "$REGISTRY"
  exit 1
fi

echo "  '$OLD_PUB' found in role: $ROLE"
echo "  Adding '$NEW_PUB' to role '$ROLE'..."

yq e -i ".roles.$ROLE.active += [\"$NEW_PUB\"]" "$REGISTRY"

echo ""
echo "  Updated registry:"
cat "$REGISTRY"

# ── Stage 3 & 4: Dev team re-applies (both publishers in effect) ───────────────

announce "3-4" "Notify Dev team to re-apply (both publishers active)"

echo "  The registry now lists both publishers for role '$ROLE'."
echo "  Dev-team apps will be associated with both during this transition."
echo ""
dev_team_apply "3-4"

pause "Dev-team apply complete. Inspect the Netskope console to confirm apps are now associated with BOTH publishers."

# ── Stage 5: Remove old publisher from registry ────────────────────────────────

announce 5 "Remove '$OLD_PUB' from registry (new publisher only)"

echo "  Removing '$OLD_PUB' from role '$ROLE'..."
yq e -i ".roles.$ROLE.active = [.roles.$ROLE.active[] | select(. != \"$OLD_PUB\")]" "$REGISTRY"

echo ""
echo "  Updated registry:"
cat "$REGISTRY"

# ── Stage 6 & 7: Dev team re-applies (old publisher removed) ──────────────────

announce "6-7" "Notify Dev team to re-apply (old publisher removed)"

echo "  The registry now lists only '$NEW_PUB' for role '$ROLE'."
echo "  After this apply, apps will be associated with '$NEW_PUB' only."
echo ""
dev_team_apply "6-7"

pause "Dev-team apply complete. Inspect the Netskope console to confirm apps are now associated with '$NEW_PUB' ONLY."

# ── Stage 8: Verify no apps still reference the retiring publisher ─────────────

announce 8 "Verify no apps blocking retirement of '$OLD_PUB'"

echo "  Running: terraform apply -var='retiring_publisher_name=$OLD_PUB'"
terraform apply -var="retiring_publisher_name=$OLD_PUB" -auto-approve

echo ""
BLOCKING=$(terraform output -json apps_blocking_retirement)
echo "  apps_blocking_retirement = $BLOCKING"

if [[ "$BLOCKING" != "[]" ]]; then
  echo ""
  echo "ERROR: Apps are still associated with '$OLD_PUB':" >&2
  echo "$BLOCKING" | jq '.' >&2
  echo "" >&2
  echo "Do NOT destroy '$OLD_PUB'. Investigate why these apps still reference it." >&2
  echo "Possible cause: Dev-team apply did not complete, or a different Dev team" >&2
  echo "is also using this publisher outside the acme-mfg persona." >&2
  exit 1
fi

echo "  ✓ No apps blocking retirement. Safe to destroy '$OLD_PUB'."

# ── Stage 9: Print destroy command (manual step) ──────────────────────────────

announce 9 "Destroy '$OLD_PUB' (manual, reviewed step)"

echo "  The script does NOT run the destroy automatically — this is a manual,"
echo "  reviewed step to prevent accidental destruction."
echo ""
echo "  To destroy '$OLD_PUB', run the following commands:"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────────────"

# Find the terraform key for this publisher name
PUB_KEY=$(terraform output -json publisher_names 2>/dev/null | \
  jq -r --arg name "$OLD_PUB" 'to_entries[] | select(.value == $name) | .key' || echo "KEY")

echo "  │  cd $(pwd)"
echo "  │"
echo "  │  # Four-resource replace — tokens are single-use and must be recycled together"
echo "  │  terraform apply \\"
echo "  │    -replace='netskope_npa_publisher.this[\"$PUB_KEY\"]' \\"
echo "  │    -replace='netskope_npa_publisher_token.this[\"$PUB_KEY\"]' \\"
echo "  │    -replace='google_secret_manager_secret_version.publisher_token[\"$PUB_KEY\"]' \\"
echo "  │    -replace='google_compute_instance.publisher[\"$PUB_KEY\"]'"
echo "  │"
echo "  │  # OR if removing the publisher entirely from var.publishers:"
echo "  │  # 1. Remove the '$PUB_KEY' entry from var.publishers in terraform.tfvars"
echo "  │  # 2. terraform apply  (two-pass destroy may be needed — see README)"
echo "  └─────────────────────────────────────────────────────────────────────"
echo ""
echo "  NOTE (two-pass destroy): If removing the publisher entirely, terraform destroy"
echo "  may exit with an error on the Netskope publisher delete because the VM takes"
echo "  ~90s to fully disconnect. Wait 2 minutes and run destroy again."
echo ""
echo "  ✓ Publisher cycling complete."
echo "    Old: $OLD_PUB (ready to destroy)"
echo "    New: $NEW_PUB (active in role '$ROLE')"
