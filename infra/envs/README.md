# infra/envs

Two environments, `dev/` and `prod/`, built from the same module (`../modules/s3-bucket`) with separate state. Project 7.

**One directory per environment, each with its own backend key.** The directory you are in is the environment you are changing, and the state for the other one cannot be read, locked or written from here.

**Since Project 9, CI applies both environments.** A pull request plans them and runs the policy checks; a merge applies dev, then waits for approval on prod. See [`docs/TERRAFORM-CI.md`](../../docs/TERRAFORM-CI.md). Locally you can still plan:

```bash
cd dev
terraform init -backend-config=../../backend.hcl
terraform plan
```

| | `dev/` | `prod/` |
|---|---|---|
| State key | `envs/dev/terraform.tfstate` | `envs/prod/terraform.tfstate` |
| Bucket | `ci-cd-lab-dev-<account-id>` | `ci-cd-lab-prod-<account-id>` |
| Old versions kept | 7 days | 90 days |
| `Environment` tag | `dev` | `prod` |

Each costs $0 while empty. Both were applied in October 2026: `Plan: 5 to add` in each, two separate state objects (`envs/dev/terraform.tfstate`, `envs/prod/terraform.tfstate`), and `No changes.` on the next plan. The prod lifecycle rule reads back from AWS as `NoncurrentDays: 90`.

---

## Directories, not workspaces

Terraform workspaces give one directory several states: `terraform workspace select prod`, and the same code now reads and writes `env:/prod/...`. They look like the shorter answer, and they hide the environment in the wrong place.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Wrong workspace selected** | `workspace select dev` yesterday, `apply` today | the selection is stored in `.terraform/environment`, which nobody reads | a plan that looks normal, against the environment you did not mean |
| **Environments can't differ** | prod needs a resource dev does not | the only tool is `count = terraform.workspace == "prod" ? 1 : 0` | conditionals on the workspace name spread through every file |
| **One backend for all** | workspaces share backend settings | prod's state can't be given its own bucket or access policy | anyone who can plan dev can read prod's state |

With directories, the environment is in the path, every difference is in the file for that environment, and each backend block can point somewhere different. The cost is a few lines repeated per environment. The code they share lives in the module, so the repeated part is the small part.

Capstone B builds `dev` and `staging` this way with real workloads. These two roots exist to show the layout with something that costs nothing.

> Further reading: [Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces), in particular *When not to use multiple workspaces*
