# Cost report: who spent this?

Make spend answerable by tag, and put it where people already look. Project 18, part 2: cost-allocation tags activated and backfilled, a weekly digest in Slack ranked by tag and by service with runner minutes beside it, and budget alerts in the same channel.

| Path | What |
|---|---|
| [`infra/cost-report/`](../infra/cost-report) | the Lambda, its weekly schedule, the budget-alert topic, and their IAM |
| [`infra/cost-report/lambda/cost_report.py`](../infra/cost-report/lambda/cost_report.py) | the digest and the alert forwarder; tests beside it |
| [`infra/account/main.tf`](../infra/account/main.tf) | the budget, now notifying SNS as well as email |
| [`infra/eks/nodes.tf`](../infra/eks/nodes.tf) | a launch template, so the nodes' instances, disks and interfaces carry tags |
| [`.github/workflows/pipeline-health.yml`](../.github/workflows/pipeline-health.yml) | `runner-minutes`: writes last week's runner minutes to S3 for the digest |

```
AWS Budgets ──▶ SNS ──────────────────────────▶ Lambda ──▶ Slack webhook
EventBridge Scheduler, Mondays 08:00 UTC ──────▲
Pipeline health (Mondays 06:17) ──▶ S3 runner-minutes.json ──▲
```

Run November 3–4, 2026, in account 653070064096. The webhook URL is an SSM SecureString read at run time, never a Terraform value.

---

## Evaluation (part 2)

| Roadmap check | Result |
|---|---|
| The Slack digest attributes 100% of the month's spend to a tag, no "untagged" row | **Not met: 36% untagged.** October $0.71 of $1.96, November to date $2.12 of $5.86. Before Project 18 it was 100%: no tag was active. The largest untagged part, the EKS nodes ($1.57 in November), is tagged from November 4 by a launch template; the effect shows in Cost Explorer a day later and has not been measured yet. Cost Explorer's own charge cannot be tagged at all. |

The digest itself, posted on November 4:

```
AWS spend Oct 28 – Nov 03: $7.80 (+$7.80 on the week before), before credits
untagged: $2.82 (36%)
By Lab tag:   Lab 13 $4.97 · untagged $2.82 · Lab capstone-a $0.01 · Lab 07 $0.01
By service:   EKS $4.96 · EC2 compute $2.04 · VPC $0.49 · EC2 - Other $0.22 · Cost Explorer $0.05 · ...
CI runner minutes, last 7 days:  Lab 03 CI 333 · Terraform 238 · Lab 02 CI 91 · Lab 01 CI 79 · total 886 over 827 runs
```

A test alert published to the topic reached Slack through the Lambda, and `describe-subscribers-for-notification` lists `EMAIL` and `SNS` for both budget notifications.

---

## Tags: activated, backfilled, and still not everywhere

**Tag at creation, activate the tag keys for cost allocation, and check which costs the tags never reach.** Every Terraform stack here had `Project` and `Lab` in `default_tags` since Project 6, and Cost Explorer still showed 100% untagged: tag keys count for cost only after someone activates them in Billing, and none had been.

| Step | When | What happened |
|---|---|---|
| `update-cost-allocation-tags-status`: `Lab`, `Project`, `Environment` active | Nov 3, 19:44 UTC | no error; nothing changed in Cost Explorer for hours |
| `start-cost-allocation-tag-backfill` from October 1 | 19:44 | `SUCCEEDED` at 19:49 |
| digest dry run | about 20:00 | still 100% untagged |
| Cost Explorer by `Lab` | Nov 4, 02:57 | October and November both grouped by tag |

The ROADMAP, and a comment in `infra/eks`, said tags do not apply retroactively. Since AWS added the backfill (up to 12 months back, once a day), they do: October, spent before any tag was active, now groups by `Lab`. What a backfill cannot do is add a tag the resource never carried. That part is still true, and it is most of what is left:

| Untagged, November to date | | Why |
|---|---|---|
| EC2 compute | $1.57 | EKS nodes: a managed node group without a launch template does not pass tags to its instances. Fixed November 4; checked on the instances (`Lab=13`). |
| VPC | $0.38 | public IPv4 addresses on the nodes; whether the interface's tag reaches this charge is not yet measured |
| EC2 - Other | $0.16 | the nodes' disks, fixed by the same launch template |
| Cost Explorer | $0.01 | the API's own charge; it has no resource to tag |

October's untagged row also had $0.03 of load balancing: load balancers that Kubernetes creates carry only Kubernetes' tags. Traefik's Service now passes `Project` and `Lab` through `service.beta.kubernetes.io/aws-load-balancer-additional-resource-tags`.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Tags never activated** | `default_tags` on every resource, no activation in Billing | Cost Explorer ignores the keys | 100% "untagged" in an account where everything is tagged |
| **Tags that stop at the parent** | a node group, an autoscaling group or a Kubernetes Service creates the billed resource | the child gets the creator's tags, or none | the biggest line of the bill under "untagged" |
| **Judging a tag change too early** | checking right after activation or a backfill | Cost Explorer updates hours later | "the backfill did nothing", seven hours before it did |

> Further reading: [AWS: cost allocation tags](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html)

---

## The digest and the alert

**Send the weekly audit and the fast alert to the same channel, and make a missing input visible.** One Lambda handles both: an SNS event is a budget alert and is forwarded as it is; anything else is the Monday digest. The digest is last 7 days against the 7 before, by `Lab` and by service, with UnblendedCost excluding credits and refunds. With credits applied every week is $0, and a report of zeros says nothing about what is spending.

Cost Explorer bills $0.01 per request, so the design is two requests a week (one per grouping, both weeks as daily rows): $0.02. Building and checking this one took about 15 requests, about $0.15.

Runner minutes come from GitHub, which the Lambda cannot ask without a stored token. The Monday Pipeline health run writes them to S3 (the CI role may put that one object), and the digest reads the file. GitHub disables scheduled workflows in a repository with no activity for 60 days; if the file is more than eight days old the digest says `stale`, instead of leaving the section out and looking like a quiet week.

| | How it happens | What goes wrong | What you see |
|---|---|---|---|
| **Polling Cost Explorer** | a dashboard refreshing every minute | $0.01 per request | $432 a month to watch a $10 bill |
| **Net cost with credits** | `NetUnblendedCost`, or no record-type filter | credits cancel the usage | a weekly $0.00 while the cluster runs |
| **A silent missing section** | the runner-minutes job stops running | the digest drops what it cannot read | a report that looks complete and is not |
| **SNS without a topic policy** | Budgets publishing to a topic that does not allow it | the notification is dropped | nothing, anywhere: the email still arrives, so nobody notices Slack never did |

> Further reading: [AWS: Cost Explorer API pricing](https://aws.amazon.com/aws-cost-management/aws-cost-explorer/pricing/)

---

## What went wrong while building this

- **The webhook URL was pasted into the chat** that built this, so it exists in that conversation's history. It can only post to one channel; regenerating it on the Slack app's Incoming Webhooks page and storing the new one under the same SSM name revokes the old one.
- **`terraform apply` was blocked** for the agent building this, as in Project 17; the two applies were run by the user.
- **The 30-day pipeline report and the 7-day file disagreed** (777 runs in 30 days, 827 in 7). Not a bug: the runs were an hour apart, in an hour of many pushes, and almost all of this repository's runs are from the last week.
- **Two Cost Explorer requests were wasted** on a Python quoting mistake in an inline print, $0.02.
