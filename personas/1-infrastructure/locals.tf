locals {
  # ── Publisher map ────────────────────────────────────────────────────────────
  # Enriches var.publishers with a stable numeric index used for zone distribution.
  # Keys are sorted lexicographically (Terraform map behaviour) so "primary" is always
  # index 0 and "secondary" index 1 with the default two-publisher config.
  #
  # Using for_each (not count) so that removing one publisher affects only that
  # specific resource — not all higher-indexed ones.
  publishers = {
    for k, v in var.publishers : k => {
      index = index(tolist(keys(var.publishers)), k)
      name  = v.name
    }
  }

  # ── Zone distribution ────────────────────────────────────────────────────────
  # If explicit zones are provided, use them. Otherwise auto-select from available
  # zones in the region, capped at the number of publishers.
  zones = (
    length(var.zones) > 0
    ? var.zones
    : slice(
        data.google_compute_zones.available.names,
        0,
        min(length(var.publishers), length(data.google_compute_zones.available.names))
      )
  )

  # ── Network references ───────────────────────────────────────────────────────
  network_self_link = (
    var.create_vpc
    ? google_compute_network.vpc[0].self_link
    : var.existing_network_self_link
  )

  subnet_self_links = (
    var.create_vpc
    ? [google_compute_subnetwork.publisher[0].self_link]
    : var.existing_subnet_self_links
  )

  # ── Publisher image ──────────────────────────────────────────────────────────
  publisher_image = (
    var.publisher_image_self_link != ""
    ? var.publisher_image_self_link
    : data.google_compute_image.ubuntu[0].self_link
  )

  # ── Common GCP labels ────────────────────────────────────────────────────────
  # GCP does not support provider-level default_labels in the same way AWS does
  # default_tags. Merge common labels here and pass local.common_labels to every
  # resource explicitly.
  common_labels = merge(
    {
      project     = lower(replace(var.project_label, " ", "-"))
      environment = lower(var.environment)
      cost_center = lower(replace(var.cost_center, " ", "-"))
      managed_by  = "terraform"
    },
    var.additional_labels
  )
}
