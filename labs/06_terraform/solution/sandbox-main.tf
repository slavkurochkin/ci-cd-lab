# A root module that costs nothing and still teaches the whole lifecycle.
#
# Everything here is local. There is no provider to authenticate, no account to
# bill, and no resource that survives `destroy`. That makes it the right place
# to do the thing you must never do first in a real account: break it on
# purpose and read what Terraform says it will do about it.

# ---------------------------------------------------------------------------
# The resource graph
# ---------------------------------------------------------------------------

variable "environment" {
  description = "Changing this forces a replace, which is the point of the exercise."
  type        = string
  default     = "sandbox"

  validation {
    condition     = contains(["sandbox", "staging", "production"], var.environment)
    error_message = "environment must be sandbox, staging or production."
  }
}

variable "service_names" {
  description = "Demonstrates for_each and a for expression over a list."
  type        = list(string)
  default     = ["api", "worker"]
}

locals {
  # A local is computed, not stored. It has no address in state, so changing
  # one never appears in a plan as its own line -- only the resources that
  # reference it move.
  prefix = "ci-cd-lab-${var.environment}"

  # A `for` expression building a map from a list. This is the shape most of
  # the real modules in this repository use.
  service_ports = { for i, name in var.service_names : name => 8000 + i }
}

# `keeper` is the whole lesson about replacement.
#
# random_pet regenerates only when something in `keepers` changes. Because
# `keepers` references var.environment, changing that variable does not update
# this resource -- it DESTROYS and RECREATES it. That is the third plan verb,
# and it is the one that loses data when the resource happens to be a database.
resource "random_pet" "name" {
  length    = 2
  separator = "-"

  keepers = {
    environment = var.environment
  }
}

# Derived from the pet, so Terraform orders this after it without being told.
# There is no depends_on here and there should not be: the reference IS the
# dependency. An explicit depends_on usually means a reference is missing.
resource "random_password" "token" {
  length  = 24
  special = false

  keepers = {
    pet = random_pet.name.id
  }
}

# A private key, generated locally. Nothing is uploaded anywhere.
#
# Note what this teaches about state: the private key material is stored in
# terraform.tfstate in plain text. Terraform state is a secret file whenever a
# resource has a secret attribute, which is one of the arguments for remote
# state with encryption -- Project 7's subject.
resource "tls_private_key" "example" {
  algorithm = "ED25519"
}

# A file on disk, so `apply` and `destroy` have something visible to do.
resource "local_file" "manifest" {
  filename        = "${path.module}/generated/${local.prefix}.json"
  file_permission = "0644"

  content = jsonencode({
    environment   = var.environment
    name          = random_pet.name.id
    service_ports = local.service_ports
    fingerprint   = tls_private_key.example.public_key_fingerprint_sha256
  })
}
