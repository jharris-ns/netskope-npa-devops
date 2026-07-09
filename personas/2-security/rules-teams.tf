# Team access rules — one rule per tier from shared/tag-taxonomy.yaml.
#
# Each rule is created only when both conditions are true:
#   1. The relevant group variable is non-empty (someone to grant access to)
#   2. At least one app with that tier tag exists (count guard — empty private_apps
#      is rejected by the Netskope API)
#
# The key design principle: Security never needs to know which specific apps
# exist. Dev teams add apps with the correct tier tag; these rules automatically
# cover them on the next terraform apply with no Security-side change required.
# This is the tag-driven self-service model from Section 3.1 of the design doc.
#
# Adding a new tier:
#   1. Add it to shared/tag-taxonomy.yaml (Security-owned, PR required)
#   2. Add a new rule block here
#   3. Add a corresponding var.X_groups variable in variables.tf
#   Dev teams can then use that tier tag immediately — the new rule covers them.

# ── web-tier ──────────────────────────────────────────────────────────────────

resource "netskope_npa_rules" "web_tier_access" {
  count = length(local.web_tier_apps) > 0 ? 1 : 0

  rule_name   = "${var.environment}-web-tier-access"
  description = "Allow web-tier groups client access to apps tagged tier=web-tier."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "allow"
    }

    private_apps = local.web_tier_apps

    user_groups = var.web_tier_groups

    access_method = ["Client"]

    user_type = "user"
  }

  rule_order = {
    order = "bottom"
  }

  depends_on = [netskope_npa_rules.admin_infrastructure]
}

# ── database-tier ─────────────────────────────────────────────────────────────

resource "netskope_npa_rules" "database_tier_access" {
  count = length(local.database_tier_apps) > 0 ? 1 : 0

  rule_name   = "${var.environment}-database-tier-access"
  description = "Allow database-tier groups client access to apps tagged tier=database-tier."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "allow"
    }

    private_apps = local.database_tier_apps

    user_groups = var.database_tier_groups

    access_method = ["Client"]

    user_type = "user"
  }

  rule_order = {
    order = "bottom"
  }

  depends_on = [netskope_npa_rules.web_tier_access]
}

# ── infrastructure ────────────────────────────────────────────────────────────

resource "netskope_npa_rules" "infrastructure_access" {
  count = length(local.infrastructure_apps) > 0 ? 1 : 0

  rule_name   = "${var.environment}-infrastructure-access"
  description = "Allow infrastructure groups client access to apps tagged tier=infrastructure."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "allow"
    }

    private_apps = local.infrastructure_apps

    user_groups = var.infrastructure_groups

    access_method = ["Client"]

    user_type = "user"
  }

  rule_order = {
    order = "bottom"
  }

  depends_on = [netskope_npa_rules.database_tier_access]
}
