# ── Netskope ──────────────────────────────────────────────────────────────────

variable "netskope_server_url" {
  type        = string
  description = "Netskope tenant API base URL including /api/v2 (e.g. https://mytenant.goskope.com/api/v2). Set via TF_VAR_netskope_server_url (see scripts/set-env.sh)."
  sensitive   = true
}

variable "netskope_api_key" {
  type        = string
  description = "Netskope REST API token with NPA App Management scope. Set via TF_VAR_netskope_api_key (see scripts/set-env.sh)."
  sensitive   = true
}

# ── Team identity ─────────────────────────────────────────────────────────────

variable "environment" {
  type        = string
  description = "Environment name. Applied as a tag on all apps and as a prefix on app names."
  default     = "production"
  validation {
    condition     = contains(["production", "staging", "development", "test"], var.environment)
    error_message = "environment must be one of: production, staging, development, test."
  }
}

variable "team_name" {
  type        = string
  description = "Business unit / team name. Applied as a tag on all apps and used in app name prefix."
  default     = "acme-mfg"
}

# ── Publisher registry ────────────────────────────────────────────────────────

variable "publisher_role" {
  type        = string
  description = "Role key from shared/publisher-registry.yaml (e.g. 'us-west-primary'). The active publishers for this role are looked up at plan time."
}

variable "use_remote_registry" {
  type        = bool
  description = <<-EOT
    false (default) — local test mode: reads shared/publisher-registry.yaml from the
    local filesystem via var.registry_local_path. No GitHub required.

    true — GitHub demo mode: fetches the registry from var.registry_source_url
    (a raw.githubusercontent.com URL). Requires the repo to be pushed to GitHub
    and the URL to be accessible.
  EOT
  default     = false
}

variable "registry_local_path" {
  type        = string
  description = "Relative path to shared/publisher-registry.yaml from this persona directory. Only used when use_remote_registry = false."
  default     = "../../shared/publisher-registry.yaml"
}

variable "registry_source_url" {
  type        = string
  description = "Raw GitHub URL for shared/publisher-registry.yaml. Only used when use_remote_registry = true. Example: https://raw.githubusercontent.com/ORG/REPO/main/shared/publisher-registry.yaml"
  default     = ""
}

# ── Apps ──────────────────────────────────────────────────────────────────────

variable "client_apps" {
  type = map(object({
    hostname  = string        # FQDN or IP the Netskope client connects to
    port      = string        # Must be a quoted string e.g. "22", "5432" — guardrail checks this
    tier      = string        # Must be in shared/tag-taxonomy.yaml approved_tiers
    real_host = optional(string, null)  # Actual backend host if different from hostname; defaults to hostname
  }))
  description = <<-EOT
    Map of client-based NPA apps to create. Key is the app identifier (used in
    the Netskope app name); value is the app configuration.

    All apps in this map:
      - Are client-based (clientless_access = false is hardcoded — not overridable)
      - Must have a tier that exists in shared/tag-taxonomy.yaml approved_tiers
      - Have required tags applied automatically: managed-by-terraform, environment, tier, team

    The CI guardrail (policy/check_guardrails.py) validates these constraints
    before terraform plan runs in the GitHub Actions workflow.
  EOT
  default = {}
}
