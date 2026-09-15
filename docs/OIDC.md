# How OIDC lets CI reach AWS with no password

Written for someone who has never set this up. No AWS account IDs or other
identifiers appear here, so this file is safe to share.

---

## The problem it solves

A pipeline that deploys to AWS needs credentials. The obvious way is to create
an access key and paste it into the repository's secret storage.

That key has three properties you cannot fix:

- **It never expires.** It works until someone remembers to delete it.
- **It works from anywhere.** Your laptop, a stolen backup, a machine in
  another country. AWS cannot tell the difference.
- **You find out late.** A leaked key is usually discovered by its effects.

Rotating it, scoping it, and storing it carefully all reduce the damage. None
of them remove the key.

**OIDC removes the key.**

---

## The idea in one sentence

Instead of your pipeline *holding* a credential, it **proves who it is** and is
handed a temporary one that expires in an hour.

The everyday version of this: a visitor badge at a building. You do not keep a
key to the office. You show ID at reception, they check it against a list, and
you get a badge that stops working at the end of the day.

---

## The three parties

| Who | Role |
|---|---|
| **GitHub** | issues signed statements about what is running |
| **AWS** | decides which statements it trusts |
| **Your workflow** | carries a statement from one to the other |

The important part: **GitHub and AWS never talk to each other.** AWS is not
calling GitHub to ask questions. It verifies a signature using a public key it
fetched from GitHub, the same way your browser verifies a website certificate.

---

## The handshake, step by step

```
   your workflow                GitHub                      AWS
        │                          │                          │
        │  1. who am I?            │                          │
        ├─────────────────────────►│                          │
        │                          │                          │
        │  2. signed statement     │                          │
        │◄─────────────────────────┤                          │
        │     (a JWT, valid        │                          │
        │      a few minutes)      │                          │
        │                                                     │
        │  3. here is my statement, I would like this role     │
        ├────────────────────────────────────────────────────►│
        │                                                     │
        │                          4. AWS checks the signature│
        │                             and reads the claims    │
        │                                                     │
        │  5. temporary credentials, valid 1 hour             │
        │◄────────────────────────────────────────────────────┤
        │                                                     │
```

**Step 1** happens because the workflow has `permissions: id-token: write`.
That permission is badly named: it does not grant write access to your
repository. It grants the right to *ask GitHub for a statement about this run*.
Leave it out and step 1 fails, which is the most common first error.

**Step 2** returns a **JWT** — a blob of JSON with a cryptographic signature.
Anyone can read it; nobody can forge it without GitHub's private key. It is
valid for minutes, and it is specific to this one workflow run.

**Step 3** is `sts:AssumeRoleWithWebIdentity`. The workflow names the role it
wants and attaches the statement.

**Step 4** is where trust is decided, and it is the part worth understanding.

**Step 5** hands back credentials that expire in an hour. Nothing is written to
disk, nothing outlives the job.

---

## What is actually in the statement

The JWT contains **claims** — facts GitHub asserts about the run:

| Claim | Meaning |
|---|---|
| `iss` | who signed it: `https://token.actions.githubusercontent.com` |
| `aud` | who it is *for*. The workflow requests this |
| `sub` | **the subject: what is running.** The one that matters |
| `repository` | `owner/name` |
| `repository_id` | numeric, permanent |
| `ref` | the branch or tag |
| `actor` | who triggered the run |
| `workflow` | the workflow's name |

AWS can match on any of them. In practice you match on `sub` and `aud`.

---

## The trust policy: how AWS decides

The role carries a document saying who may assume it. Read it as three
questions:

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "<the OIDC provider you registered>" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
    },
    "StringLike": {
      "token.actions.githubusercontent.com:sub": "repo:OWNER/NAME:*"
    }
  }
}
```

1. **`Principal`** — was this signed by an issuer I registered? You register
   GitHub once per AWS account, and an account may hold **only one**
   registration per issuer.
2. **`aud`** — was the statement minted *for AWS*? Stops a token intended for
   another service being replayed here.
3. **`sub`** — **is this the repository I mean?**

### The `sub` condition is the entire security boundary

Everything else is plumbing. This one line decides who gets in.

| Written as | Who can assume the role |
|---|---|
| *(omitted)* | **any repository on GitHub** |
| `repo:OWNER/*:*` | every repository you own, including forks you make years from now |
| `repo:OWNER/NAME:*` | one repository, any branch or pull request |
| `repo:OWNER/NAME:ref:refs/heads/main` | one repository, `main` only |

Omitting it is not a small mistake. It means a stranger's workflow can assume
your role.

### `:*` includes `:pull_request`, and that is further than it looks

This is the part people get wrong, and it is worth slowing down for.

When a workflow runs on a pull request, the `sub` claim is:

```
repo:OWNER/NAME:pull_request
```

**It names the repository the pull request is opened against — not whoever
wrote the code.** There is no branch in it, no author, and nothing identifying
which pull request it was.

So a condition ending in `:*`, or in `:pull_request`, is satisfied by **anyone
who can open a pull request against your repository.** Adding a collaborator
therefore hands them the role, without anyone deciding to. They push a branch,
open a pull request, and their workflow runs with a `sub` your policy accepts.

This is not theoretical. [A demonstration against Azure][binsec] shows
credentials pinned to `pull_request` being used exactly this way, and concludes
that such credentials are *"accessible to anyone with collaborator access to the
matching repository."* The same reasoning applies to AWS.

**Forks are a separate question, and GitHub's documentation does not answer
it.** The OIDC reference describes the `id-token: write` permission and the
`sub` formats but says nothing about whether a pull request from a fork can
obtain a token. Treat that silence as a reason to pin the subject rather than a
reason to relax — a control you cannot find documented is not a control you
should depend on.

### The rule

> **A role that grants nothing may use `:*`. A role that can change anything is
> pinned to a branch or an environment.**

A role with no policies attached is safe with a wide subject, because assuming
it achieves nothing. That is how the role in this repository is configured: it
exists to prove the login works.

The moment a role gains real permissions, narrow it:

| Condition | Who gets in | Use for |
|---|---|---|
| `repo:OWNER/NAME:*` | anyone who can open a pull request | roles that grant nothing |
| `repo:OWNER/NAME:ref:refs/heads/main` | only runs on `main` | deploys, infrastructure |
| `repo:OWNER/NAME:environment:production` | only jobs targeting that environment | anything you want a gate on |

The last one pairs with a GitHub **environment** carrying required reviewers.
The subject then encodes "a human approved this," and the credential cannot be
obtained any other way. That is what makes an environment more than paperwork.

[binsec]: https://www.binarysecurity.no/posts/2025/09/securing-gh-actions-part2

---

## The trap: `sub` has two spellings

GitHub is moving from the older form to an **immutable** one that embeds
numeric IDs:

```
old:  repo:OWNER/NAME:pull_request
new:  repo:OWNER@<owner_id>/NAME@<repo_id>:pull_request
```

The IDs exist because **names can be reassigned and IDs cannot.** Rename a
repository, or give it away, and a rule written against the name could end up
pointing at something you no longer control. The numbers cannot be moved.

Find yours with:

```bash
gh api repos/OWNER/NAME --jq '"repo \(.id), owner \(.owner.id)"'
```

A `StringLike` condition accepts a list and matches if **any** entry matches,
so you can allow both:

```json
"token.actions.githubusercontent.com:sub": [
  "repo:OWNER/NAME:*",
  "repo:OWNER@<owner_id>/NAME@<repo_id>:*"
]
```

**Why this one is nasty:** a policy with only the old spelling is valid JSON,
passes `terraform validate`, plans correctly, and matches every published
example on the internet. It fails only when a real token arrives.

---

## When it does not work

The error you get is always the same and explains nothing:

```
Could not assume role with OIDC:
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

**The actual claim is in CloudTrail.** This is the command worth remembering:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 1
```

Look at `userIdentity.principalId`. It contains the exact `sub` GitHub sent.
Compare it to your condition character by character.

Common causes, roughly by frequency:

| Symptom | Cause |
|---|---|
| Fails immediately, before contacting AWS | missing `permissions: id-token: write` |
| `Not authorized`, condition looks right | `sub` format mismatch — check CloudTrail |
| `Not authorized`, works on `main` only | your condition pins a branch |
| `Not authorized` from a fork | correct: forks get a different `sub` |
| `InvalidIdentityToken` | `aud` mismatch between workflow and policy |

---

## Where this repository stands

The role here has **no policies attached at all**, so its wide subject grants
nothing:

```bash
aws iam list-attached-role-policies --role-name <role>   # []
aws iam list-role-policies --role-name <role>            # []
```

That is deliberate and it is the only reason `:*` is acceptable here. The first
role that gains real permissions — the Terraform role in Project 6 — gets
pinned to `main`, and anything that deploys gets an environment with a reviewer
on top.

---

## What OIDC does *not* do

**It proves who you are. It says nothing about what you may do.**

A role can be assumable and still permitted to do nothing at all — that is
exactly how this repository's role is configured, because it exists only to
demonstrate the login. Permissions are a separate document attached to the
role.

The same split appears again inside Kubernetes. An AWS identity can
authenticate to a cluster perfectly and then be refused by the cluster's own
permission system, which produces an `Unauthorized` that reads like a broken
token but is not.

Keep the two questions apart:

- **Authentication:** are you who you say you are?
- **Authorization:** are you allowed to do this?

---

## What it looks like when it works

```
arn:aws:sts::<account-id>:assumed-role/<role-name>/GitHubActions
```

Three things to notice:

- **`sts::`**, not `iam::`. This is a temporary session, not a permanent user.
- **`assumed-role/`** confirms it was assumed rather than logged into.
- **`GitHubActions`** is the session name, which appears in the audit log. Every
  call is traceable to the run that made it.

The credentials behind that expire in **one hour**. There is nothing to rotate,
nothing to revoke, and nothing that can leak from your repository — because
nothing was ever stored in it.

---

## Reading list

- [GitHub — About security hardening with OpenID Connect](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [GitHub — Configuring OpenID Connect in AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [AWS — Create an OpenID Connect identity provider](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html)

The working example in this repository is `infra/ci-oidc/` and
`.github/workflows/aws-identity.yml`.
