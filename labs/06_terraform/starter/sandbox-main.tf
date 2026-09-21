# Lab 06 -- the plan/apply loop, where it costs nothing (starter)
#
# Nothing in this file touches a cloud. random, local and tls generate values
# and write files, so you can be wrong on purpose with no account and no bill.
#
#   make verify LAB=06

# TODO(lab-06-a1): Declare an `environment` variable, type string, defaulting
# to "sandbox".
#
# Give it a `validation` block accepting only sandbox, staging or production.
# A variable with no constraint is a variable someone will eventually set to
# "prd" at 6pm.

# TODO(lab-06-a2): Declare a `service_names` variable, a list of strings,
# defaulting to ["api", "worker"].

# TODO(lab-06-a3): Add a `locals` block with two entries:
#
#   prefix        -- "ci-cd-lab-<environment>"
#   service_ports -- a map from each service name to a port, built with a
#                    `for` expression over service_names, starting at 8000
#
# A local has no address in state. Changing one never appears in a plan as its
# own line; only the resources that reference it move.

resource "random_pet" "name" {
  length    = 2
  separator = "-"

  # TODO(lab-06-b): Add a `keepers` map keyed on the environment variable.
  #
  # This is the whole lesson. random_pet regenerates only when something in
  # keepers changes -- and regenerating is not an update. Terraform DESTROYS
  # and RECREATES it.
  #
  # After you apply, run:
  #
  #   terraform plan -var environment=staging
  #
  # and read the verbs carefully. That third one is the dangerous plan
  # operation, and here it costs nothing.
}

# TODO(lab-06-b): Add a `random_password` resource named `token`, 24 characters,
# no special characters, keyed on random_pet.name.id.
#
# Note what you are NOT adding: a depends_on. The reference to
# random_pet.name.id IS the dependency -- Terraform derives ordering from the
# graph. An explicit depends_on usually means a reference is missing.

# TODO(lab-06-c): Add a `tls_private_key` resource named `example`, algorithm
# ED25519.
#
# Then, after applying, look for the private key in terraform.tfstate. It is
# there, in plain text. That is what "state is a secret file" means, and it is
# one of the arguments for the remote state in Project 7.

# TODO(lab-06-a3): Add a `local_file` resource named `manifest` that writes
# JSON to "${path.module}/generated/<prefix>.json", containing the environment,
# the pet name, the service ports map, and the key's
# public_key_fingerprint_sha256.
#
# This gives apply and destroy something visible to do.
