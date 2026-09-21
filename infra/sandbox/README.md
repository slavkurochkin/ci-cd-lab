# infra/sandbox

A root module that creates nothing in any cloud. **$0**, no credentials, no
account.

```bash
terraform init && terraform apply
terraform plan -var environment=staging    # read this one carefully
terraform destroy
```

## Why a module that does nothing

The plan is the part of Terraform worth learning, and the plan is most useful
when it says something alarming. You should meet that for the first time
somewhere it cannot cost anything.

Everything here is `random`, `local` and `tls` — three providers that generate
values and write files. `terraform destroy` leaves nothing behind.

## The three plan verbs

`apply` this, then run `plan -var environment=staging` and read what comes back:

```
Plan: 3 to add, 0 to change, 3 to destroy.
```

**Nothing is updated.** One variable changed and three resources are being
destroyed and recreated — because `random_pet` keys on `var.environment`,
`random_password` keys on the pet, and `local_file` names itself after both.
The reference *is* the dependency, which is why there is no `depends_on`
anywhere in this module.

| Verb | Looks like | Means |
|---|---|---|
| create | `+` | new resource |
| update in place | `~` | attribute changed, resource survives |
| **replace** | `-/+` | **destroyed and recreated** |

The third is the one to read carefully. On a `random_pet` it is free. On a
database, an EBS volume, or anything holding data, a replace is data loss
triggered by a one-word edit — and it looks almost identical in the output.

## What state holds

`tls_private_key` generates a private key, and that key is written to
`terraform.tfstate` **in plain text**.

The `token` output is marked `sensitive`, which redacts it from plan and apply
output. It does not encrypt anything. Sensitivity is about display; the state
file still has the value.

That is one of the arguments for remote state with encryption at rest, which is
Project 7.
