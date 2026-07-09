terraform {
  required_version = ">= 1.5"

  required_providers {
    netskope = {
      source  = "netskopeoss/netskope"
      version = ">= 0.4.2"
    }
  }
}
