# Publisher registry lookup — Section 8.6.3 of the design doc.
#
# The Dev team NEVER hardcodes a publisher name or ID. Instead, they specify a
# role (e.g. "us-west-primary") and this file resolves which publishers are
# currently active for that role by reading shared/publisher-registry.yaml.
#
# During a publisher cycling operation, the Infrastructure persona updates the
# registry (adding the new publisher, then removing the old one). The Dev team
# re-applies at each stage — their apps automatically reassociate with whichever
# publishers the registry lists, without any Dev-team config change.
#
# ── Run mode ──────────────────────────────────────────────────────────────────
#
# LOCAL TEST MODE (default, use_remote_registry = false):
#   Reads the registry file directly from the local filesystem.
#   The Terraform http data source does NOT support file:// URLs — use the
#   yamldecode(file(...)) approach shown here instead.
#
# GITHUB DEMO MODE (use_remote_registry = true):
#   Fetches the registry from a raw.githubusercontent.com URL. This simulates
#   the cross-repo registry lookup that would happen in a real multi-repo setup,
#   where the Dev repo fetches the registry from the Infra repo's raw URL.
#   Set var.registry_source_url to the raw GitHub URL for your repo.
#
# The conditional local below chooses between the two sources. The http data
# source has count = 0 in local mode so it is never instantiated.

# ── Data sources ──────────────────────────────────────────────────────────────

# Remote registry fetch — only instantiated when use_remote_registry = true.
# Commented equivalent for documentation purposes:
#   url = "https://raw.githubusercontent.com/ORG/REPO/main/shared/publisher-registry.yaml"
data "http" "publisher_registry" {
  count = var.use_remote_registry ? 1 : 0
  url   = var.registry_source_url
}

# All publishers registered with the Netskope tenant.
# Filtered below to only those listed as active in the registry for this role.
data "netskope_npa_publishers_list" "all" {}

# ── Registry resolution ───────────────────────────────────────────────────────

locals {
  # Read registry from local filesystem or remote URL depending on run mode.
  registry = yamldecode(
    var.use_remote_registry
    ? data.http.publisher_registry[0].response_body
    : file(var.registry_local_path)
  )

  # Names of publishers currently active for our role, e.g. ["us-west-dc1-primary"]
  # During a cycle this may briefly be ["us-west-dc1-primary", "us-west-dc1-new"]
  # so apps are associated with both during the transition window.
  active_publisher_names = local.registry.roles[var.publisher_role].active

  # Publisher objects in the format netskope_npa_private_app.publishers expects:
  #   [{ publisher_id = "123", publisher_name = "us-west-dc1-primary" }]
  #
  # publisher_id MUST be a string — tostring() is required. The guardrail check
  # (policy/check_guardrails.py) fails if a literal numeric publisher_id appears
  # in source — this local is the correct pattern.
  app_publishers = [
    for p in data.netskope_npa_publishers_list.all.data.publishers :
    {
      publisher_id   = tostring(p.publisher_id)
      publisher_name = p.publisher_name
    }
    if contains(local.active_publisher_names, p.publisher_name)
  ]
}
