# Private app definitions for the acme-mfg business unit.
#
# This persona creates CLIENT-BASED apps only. clientless_access is hardcoded
# to false and is NOT a variable — this persona must not be able to create
# browser-based apps. The CI guardrail (policy/check_guardrails.py) also
# checks for clientless_access = true in the plan and fails the build.
#
# App naming convention: {environment}-{team_name}-{app_key}
# e.g. production-acme-mfg-ssh-bastion
#
# Required tags (from shared/tag-taxonomy.yaml required_tags) are applied
# automatically — the Dev team only needs to supply the tier tag value.
# Using an unapproved tier causes the app to fall through to the Security
# persona's catch-all deny rule and also fails the CI guardrail check.

resource "netskope_npa_private_app" "this" {
  for_each = var.client_apps

  private_app_name     = "${var.environment}-${var.team_name}-${each.key}"
  private_app_hostname = each.value.hostname
  private_app_protocol = "tcp"
  real_host            = each.value.real_host != null ? each.value.real_host : each.value.hostname

  # Hardcoded — this persona MUST NOT create browser-based apps.
  # Do not change to a variable. The guardrail will catch clientless_access = true
  # in the plan JSON and fail the CI build.
  clientless_access  = false
  is_user_portal_app = false
  use_publisher_dns  = true

  protocols = [
    {
      # port must be a string — "22" not 22. The guardrail checks for unquoted
      # numeric port values in the source and plan.
      port     = each.value.port
      protocol = "tcp"
    }
  ]

  # Publishers resolved from shared/publisher-registry.yaml via data-registry.tf.
  # Never hardcode a publisher_id here — always use tostring() on a data source
  # or resource attribute. The guardrail fails on literal numeric publisher_ids.
  publishers = local.app_publishers

  # Required tags — applied to every app automatically.
  # The Security persona's tag-driven rules filter apps by tier tag;
  # the guardrail validates that all four required tags are present and
  # that tier is in the approved list.
  tags = [
    { tag_name = "managed-by-terraform" },  # required_tags[0]
    { tag_name = var.environment },          # required_tags[1] — "environment" value
    { tag_name = each.value.tier },          # required_tags[2] — drives Security rule matching
    { tag_name = var.team_name },            # required_tags[3] — "team" value
  ]
}
