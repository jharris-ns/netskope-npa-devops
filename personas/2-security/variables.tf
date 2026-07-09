# ── Netskope ──────────────────────────────────────────────────────────────────

variable "netskope_server_url" {
  type        = string
  description = "Netskope tenant API base URL including /api/v2 (e.g. https://mytenant.goskope.com/api/v2). Set via TF_VAR_netskope_server_url (see scripts/set-env.sh)."
  sensitive   = true
}

variable "netskope_api_key" {
  type        = string
  description = "Netskope REST API token with NPA Policy Management scope. Set via TF_VAR_netskope_api_key (see scripts/set-env.sh)."
  sensitive   = true
}

# ── Groups ────────────────────────────────────────────────────────────────────
# Group names must exactly match the values from your Identity Provider (IdP).
# Wrong names create rules that silently never match — not validated at plan time.

variable "environment" {
  type        = string
  description = "Environment prefix applied to all rule names."
  default     = "production"
  validation {
    condition     = contains(["production", "staging", "development", "test"], var.environment)
    error_message = "environment must be one of: production, staging, development, test."
  }
}

variable "admin_groups" {
  type        = list(string)
  description = "IdP groups with admin access — permitted to access ALL tiers. Must match IdP values exactly."
  default     = []
}

variable "web_tier_groups" {
  type        = list(string)
  description = "IdP groups permitted to access apps tagged tier=web-tier."
  default     = []
}

variable "database_tier_groups" {
  type        = list(string)
  description = "IdP groups permitted to access apps tagged tier=database-tier."
  default     = []
}

variable "infrastructure_groups" {
  type        = list(string)
  description = "IdP groups permitted to access apps tagged tier=infrastructure."
  default     = []
}

variable "blocked_groups" {
  type        = list(string)
  description = "IdP groups explicitly denied access to all apps (e.g. Terminated-Users). Evaluated first."
  default     = []
}

variable "demo_users" {
  type        = list(string)
  description = "Individual user emails added to every allow rule. Use for demo/testing when IdP groups are not SCIM-provisioned."
  default     = []
}
