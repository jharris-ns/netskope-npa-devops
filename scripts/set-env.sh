#!/usr/bin/env bash
# scripts/set-env.sh — maps NETSKOPE_* variables from ~/.env into the
# TF_VAR_* names that Terraform expects.
#
# Usage:
#   source scripts/set-env.sh
#
# Prerequisites:
#   ~/.env must contain at minimum:
#     NETSKOPE_SERVER_URL=https://your-tenant.goskope.com
#     NETSKOPE_API_KEY=your-api-token
#     NETSKOPE_GCP_PROJECT_ID=your-gcp-project-id
#
# After sourcing this script, run terraform commands normally:
#   cd personas/1-infrastructure
#   terraform init && terraform plan

set -euo pipefail

ENV_FILE="${HOME}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: ~/.env not found. Create it with NETSKOPE_* variables." >&2
  exit 1
fi

# Load the env file (ignore blank lines and comments)
# shellcheck disable=SC1090
set -o allexport
source "$ENV_FILE"
set +o allexport

# Map to TF_VAR_* names
# The Netskope Terraform provider requires the full URL including /api/v2
export TF_VAR_netskope_server_url="${NETSKOPE_SERVER_URL:?NETSKOPE_SERVER_URL must be set in ~/.env}"

export TF_VAR_netskope_api_key="${NETSKOPE_API_KEY:?NETSKOPE_API_KEY must be set in ~/.env}"

# GCP project: prefer NETSKOPE_GCP_PROJECT_ID in ~/.env, fall back to active gcloud project
if [[ -n "${NETSKOPE_GCP_PROJECT_ID:-}" ]]; then
  export TF_VAR_gcp_project_id="$NETSKOPE_GCP_PROJECT_ID"
else
  _gcloud_project="$(gcloud config get-value project 2>/dev/null)" || true
  if [[ -z "$_gcloud_project" ]]; then
    echo "ERROR: NETSKOPE_GCP_PROJECT_ID not set in ~/.env and no active gcloud project found." >&2
    exit 1
  fi
  export TF_VAR_gcp_project_id="$_gcloud_project"
  echo "  (NETSKOPE_GCP_PROJECT_ID not in ~/.env — using active gcloud project: $_gcloud_project)"
  unset _gcloud_project
fi

echo "✓ TF_VAR_netskope_server_url  → ${TF_VAR_netskope_server_url}"
echo "✓ TF_VAR_netskope_api_key     → (set, not shown)"
echo "✓ TF_VAR_gcp_project_id       → ${TF_VAR_gcp_project_id}"
echo ""
echo "Environment ready. Run terraform commands in any persona directory."

# Restore shell options — when sourced, set -euo pipefail above would otherwise
# remain active in the calling shell and kill it on any non-zero exit code.
set +euo pipefail
