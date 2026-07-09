# Catch-all deny rule — deny-by-default (Section 6.4 of the design doc).
#
# This rule is the security foundation of the tag-driven model:
#   - Any app that a Dev team deploys with an UNAPPROVED tier tag has no matching
#     allow rule above, so it falls through to this deny.
#   - Any app that a Dev team deploys with a MISSING tier tag falls through here.
#   - Any user NOT in an explicitly allowed group falls through here.
#
# The CI guardrail (policy/check_guardrails.py) catches bad tags BEFORE apply,
# but this rule is the runtime enforcement layer that makes the model safe even
# if the guardrail is bypassed.
#
# Implementation note: This rule lists all known apps from the data source.
# Apps created outside Terraform won't be listed here until the next apply —
# that is acceptable for a demo; production deployments should schedule regular
# applies or use Netskope's native deny-by-default setting if available.

resource "netskope_npa_rules" "deny_all" {
  count = length(local.all_app_names) > 0 ? 1 : 0

  rule_name   = "${var.environment}-deny-all"
  description = "Catch-all deny. Anything not explicitly allowed above is blocked. DO NOT remove."
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

    # No user_groups — matches any user not caught by a prior allow rule.
    user_type = "user"

    access_method = ["Client", "Clientless"]
  }

  rule_order = {
    order = "bottom"
  }

  depends_on = [
    netskope_npa_rules.infrastructure_access,
    netskope_npa_rules.database_tier_access,
    netskope_npa_rules.web_tier_access,
  ]

  lifecycle {
    ignore_changes = [rule_data]
  }
}
