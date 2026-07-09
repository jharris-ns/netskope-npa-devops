# Admin access rules — all tiers, evaluated after explicit denies.
#
# Admin groups get access to every app tier. Three separate rules (one per tier)
# rather than one rule covering all apps — this makes audit logs tier-specific
# and allows the deny rule in rules-deny.tf to be placed above these with
# correct precedence.

resource "netskope_npa_rules" "admin_web_tier" {
  count = length(local.web_tier_apps) > 0 ? 1 : 0

  rule_name   = "${var.environment}-admin-web-tier"
  description = "Allow admin groups client access to web-tier applications."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "allow"
    }

    private_apps = local.web_tier_apps

    user_groups = var.admin_groups

    access_method = ["Client"]

    user_type = "user"
  }

  rule_order = {
    order = "top"
  }

  depends_on = [netskope_npa_rules.deny_blocked_groups]
}

resource "netskope_npa_rules" "admin_database_tier" {
  count = length(local.database_tier_apps) > 0 ? 1 : 0

  rule_name   = "${var.environment}-admin-database-tier"
  description = "Allow admin groups client access to database-tier applications."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "allow"
    }

    private_apps = local.database_tier_apps

    user_groups = var.admin_groups

    access_method = ["Client"]

    user_type = "user"
  }

  rule_order = {
    order = "top"
  }

  depends_on = [netskope_npa_rules.admin_web_tier]
}

resource "netskope_npa_rules" "admin_infrastructure" {
  count = length(local.infrastructure_apps) > 0 ? 1 : 0

  rule_name   = "${var.environment}-admin-infrastructure"
  description = "Allow admin groups client access to infrastructure applications."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "allow"
    }

    private_apps = local.infrastructure_apps

    user_groups = var.admin_groups

    access_method = ["Client"]

    user_type = "user"
  }

  rule_order = {
    order = "top"
  }

  depends_on = [netskope_npa_rules.admin_database_tier]
}
