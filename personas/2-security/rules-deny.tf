# Explicit deny rules — evaluated before any allow rule.
#
# These rules block specific groups from all Terraform-managed apps regardless
# of any other rule that might otherwise permit them. Use this for terminated
# users, quarantined accounts, or groups that must be explicitly excluded.
#
# Rule order: "top" — Netskope evaluates most-specific-match; placing these
# at the top of the Terraform-Managed group ensures they are checked first
# within this group's rule set.

resource "netskope_npa_rules" "deny_blocked_groups" {
  # Only created when blocked_groups is non-empty AND at least one app exists.
  count = length(var.blocked_groups) > 0 && length(local.all_app_names) > 0 ? 1 : 0

  rule_name   = "${var.environment}-deny-blocked-groups"
  description = "Block explicitly denied groups from all Terraform-managed apps."
  enabled     = "1"
  group_id    = netskope_npa_policy_groups.terraform_managed.id

  rule_data = {
    policy_type  = "private-app"
    json_version = 3

    match_criteria_action = {
      action_name = "block"
      template    = "Default Template"
    }

    private_apps = local.all_app_names

    user_groups = var.blocked_groups

    access_method = ["Client", "Clientless"]

    user_type = "user"
  }

  rule_order = {
    order = "top"
  }

  lifecycle {
    ignore_changes = [rule_data]
  }
}
