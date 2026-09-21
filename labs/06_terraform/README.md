# Lab 06 — Terraform Fundamentals

> **Roadmap:** Project 6 of the [CI/CD roadmap](../../ROADMAP.md).

**Goal:** Learn the plan/apply loop on resources that cost nothing, then create your first real AWS resources deliberately.

---

## Before you start

**These files already exist solved on `main`**, and `infra/account` has live Terraform state pointing at real AWS resources. Work on a branch:

```bash
git switch -c lab-06
make reset LAB=06
```

To abandon the attempt:

```bash
git checkout main -- infra/sandbox/main.tf infra/sandbox/outputs.tf infra/account/main.tf
```

**The state files are not part of the starter and must not be deleted.** `infra/account/terraform.tfstate` is the only record that the budget is managed. Resetting the `.tf` files is safe; removing state is how you end up with two budgets and a failed apply.

---

## Concepts

### The plan is the product

`apply` does what you told it. `plan` tells you what you told it, which is rarely the same as what you meant.

Read every plan before running it, and read it for the **verb**, not the resource names:

| Verb | Symbol | Means |
|---|---|---|
| create | `+` | new resource |
| update in place | `~` | attribute changed, resource survives |
| **replace** | `-/+` | **destroyed, then recreated** |
| destroy | `-` | gone |

The third is the dangerous one, and it is the one that looks almost identical to the second in a long plan. On a `random_pet` a replace costs nothing. On an RDS instance it is your data.

Terraform tells you *why* — `# forces replacement` appears beside the attribute responsible. That annotation is the most important text in the output.

---

### The graph comes from references

Terraform derives ordering from the fact that one resource mentions another. Nothing else is needed:

```hcl
resource "random_password" "token" {
  keepers = { pet = random_pet.name.id }   # ← this IS the dependency
}
```

**An explicit `depends_on` is usually a smell.** It means either a reference is missing, or you are working around something the provider should have modelled. There is none anywhere in this lab, and the verifier checks for that.

> Further reading: [Terraform — Resource dependencies](https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on)

---

### Four ways to name a value, and which one surprises people

| | Where the value comes from | Address in state |
|---|---|---|
| `variable` | the caller | no |
| `local` | computed from other values | **no** |
| `output` | exposed to the caller | no |
| `data` | **read from the provider at plan time** | yes |

`data` is the one that surprises. It queries the real world on every plan, so its result can change without your code changing — and anything referencing it moves with it. A `data` source pointing at something mutable is a plan that differs between two runs of the same commit.

`local` surprises differently: it has no address, so changing one never appears in a plan as its own line. Only the resources that reference it move, which can look like they changed for no reason.

---

### State is a secret file

`tls_private_key` writes a private key into `terraform.tfstate` **in plain text**. So does every database password, every generated token, every provider that returns a credential.

Marking an output `sensitive` redacts it from console output. It does not encrypt anything.

That is the argument for remote state with encryption at rest, which is Project 7. Until then, `terraform.tfstate` is gitignored for a reason.

---

### Drift: the gap between the account and the state

A resource that exists in your account but not in Terraform's state is **invisible**. `plan` does not see it. `destroy` does not remove it. And any apply that tries to create it collides with it.

```
# aws_budgets_budget.monthly will be created      ← it is already there
Plan: 6 to add, 0 to change, 0 to destroy.
```

`terraform import` closes the gap. What it does **not** do is make the difference go away:

```
# aws_budgets_budget.monthly will be updated in-place
Plan: 5 to add, 1 to change, 0 to destroy.
```

**Import makes a difference visible rather than removing it.** That is the whole value, and it is Project 7's subject.

---

### Where AWS costs actually come from

| Free, effectively | Bills by the hour | Bills by volume |
|---|---|---|
| IAM, S3 at small size, budgets, ECR under 500MB | EKS, EC2, NAT Gateway, load balancers | data transfer out, ECR above the tier |

Everything in this lab is in the first column. Nothing here costs money, which is deliberate: the first time you run `terraform destroy` against a real account should not also be the first time you find out what you were paying for.

`docs/COST.md` is the authority.

---

## Setup

```bash
git switch -c lab-06
make reset LAB=06
cd infra/sandbox && terraform init
```

The sandbox module needs no credentials. `infra/account` needs your AWS profile and a `terraform.tfvars` with `budget_email`.

---

## Tasks

### Task A — Variables, locals, and a `for` expression (`TODO(lab-06-a1/a2/a3)`)

Covers: typed variables, validation, `locals`, and building a map from a list.

In `infra/sandbox/main.tf`: declare `environment` (validated) and `service_names` (typed list), then a `locals` block computing `prefix` and `service_ports`.

**What to observe:**
- Set `environment = "prd"` and run `plan`. The error arrives at plan time, not at apply time, and not in AWS.

**Questions to reflect on:**
- `service_ports` is a `local`, not an `output`. What changes about the plan if you make it an output instead?

---

### Task B — The graph, and the verb that destroys things (`TODO(lab-06-b)`)

Covers: `keepers`, derived ordering, and replacement.

Add `random_pet` keyed on `environment`, and `random_password` keyed on the pet. Add **no** `depends_on`.

```bash
terraform apply
terraform plan -var environment=staging
```

**What to observe:**
- `Plan: 3 to add, 0 to change, 3 to destroy` — **nothing is updated.** One variable changed and three resources are being destroyed and recreated.
- Find `# forces replacement` in the output. That annotation names the attribute responsible.
- Then run `terraform graph` and look at the edges you never declared.

**Questions to reflect on:**
- If `random_pet` were an RDS instance, what would that plan have cost you? How would you have noticed before typing `yes`?

---

### Task C — What state holds (`TODO(lab-06-c)`)

Covers: sensitive values, and where they actually live.

Add `tls_private_key` and the four outputs. Mark `token` sensitive.

**What to observe:**
```bash
terraform apply
grep -o 'BEGIN [A-Z ]*PRIVATE KEY' terraform.tfstate
```
- The key is there, in plain text, in a file on your laptop.
- `token` is redacted in the console and present in state.

**Questions to reflect on:**
- If this state file were in the repository, what would you have published? Check `.gitignore` and work out what is protecting you.

---

### Task D — An S3 bucket is five resources (`TODO(lab-06-d1/d2)`)

Covers: why "we have a bucket" says nothing about whether it is safe.

In `infra/account/main.tf`: a bucket named using the account ID, plus versioning, encryption, a public access block with **all four** flags, and a lifecycle rule expiring noncurrent versions.

**What to observe:**
- Comment out the public access block and run `plan`. Terraform is perfectly happy. Nothing warns you.
- Verify outside Terraform, because that is the only check that counts:
  ```bash
  aws s3api get-public-access-block --bucket <name>
  ```

**Questions to reflect on:**
- Three of the four flags block a route. Which one blocks a route that is *already* open, and why does that distinction matter on a bucket that has existed for a year?

---

### Task E — Import the budget that already exists (`TODO(lab-06-e)`)

Covers: drift, and what `import` does and does not do.

Declare the budget with both notifications. **Then read the plan before applying it.**

```bash
terraform plan            # "will be created" -- it already exists
terraform import aws_budgets_budget.monthly "<account-id>:ci-cd-lab-monthly"
terraform plan            # read the difference that remains
```

**What to observe:**
- The first plan would have failed on apply.
- After import, the plan is not empty. Whatever remains is real drift between what someone typed into the CLI months ago and what your code says.

**Questions to reflect on:**
- Nothing in this lab detected the drift. You knew because you created it. How would you find one you did not know about, in an account with three hundred resources?

---

## Verify

```bash
make verify LAB=06
```

| Test | What it proves |
|---|---|
| `test_environment_variable_is_constrained` | Task A1: a variable with a validation block |
| `test_service_names_is_a_typed_list` | Task A2 |
| `test_locals_use_a_for_expression` | Task A3 |
| `test_pet_keys_on_the_environment` | Task B: something can force a replacement |
| `test_password_depends_on_the_pet_by_reference` | Task B: the graph exists |
| `test_no_explicit_depends_on_in_the_sandbox` | Task B: and it was not hand-written |
| `test_a_private_key_is_generated` | Task C |
| `test_the_token_output_is_marked_sensitive` | Task C |
| `test_bucket_name_is_globally_unique` | Task D1 |
| `test_bucket_is_configured[×4]` | Task D2: all five resources exist |
| `test_all_four_public_access_flags_are_set` | Task D2 |
| `test_versioning_has_an_expiry` | Task D2 |
| `test_budget_warns_before_the_money_is_spent` | Task E: FORECASTED, not just ACTUAL |
| **`test_budget_is_in_state_not_just_in_the_account`** | **Task E: you imported it** |
| `test_formatting_is_canonical`, `test_configuration_is_valid` | both modules |

The bolded one reads `terraform state list`, not the `.tf` files. Declaring a resource and managing it are different things, and only one of them can be checked by reading code.

---

## Key lesson

Terraform's power is the plan, not the apply. The plan is where you find out what you actually said, as opposed to what you meant.

And the corollary this lab adds: **the plan can only tell you about things Terraform knows exist.** A resource in your account and not in your state is invisible to every safeguard in the tool.
