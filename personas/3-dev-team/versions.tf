terraform {
  required_version = ">= 1.5"

  required_providers {
    netskope = {
      source  = "netskopeoss/netskope"
      version = ">= 0.4.2"
    }
    # http provider used in GitHub demo mode (use_remote_registry = true)
    # to fetch publisher-registry.yaml from raw.githubusercontent.com.
    http = {
      source  = "hashicorp/http"
      version = ">= 3.0"
    }
  }
}
