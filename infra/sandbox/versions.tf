terraform {
  required_version = ">= 1.6"

  required_providers {
    # Three providers that create nothing in any cloud. The whole plan/apply/
    # destroy lifecycle, with no account, no credentials and no bill -- which
    # makes this the right place to be wrong on purpose.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
