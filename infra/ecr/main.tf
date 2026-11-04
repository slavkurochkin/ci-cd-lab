# Container registry for the images the pipeline builds.
#
# This exists rather than GHCR alone because Track C pulls from it. EKS pulling
# from GHCR needs an image pull secret -- a stored credential, which is exactly
# what Project 4 spent its time removing. ECR plus IAM needs no secret.
#
# Cost: about $0.015/month per retained version pair, and the first 500 MB of
# private storage is free for twelve months. The lifecycle policy in the module
# is what keeps it there.
#
# Since Project 8 each repository comes from ../modules/ecr-repository, which
# owns the settings and the reasons for them: immutable tags, scan on push, and
# a lifecycle policy that expires untagged images first.

module "repository" {
  source = "../modules/ecr-repository"

  # for_each over a map, not count over a list. Each repository's address is
  # its service name -- module.repository["api"] -- so adding, removing or
  # reordering services never changes which address belongs to which
  # repository.
  for_each = var.services

  name            = "ci-cd-lab/${each.key}"
  retained_images = coalesce(each.value.retained_images, var.retained_images)

  # Capstone B: the api runs on Lambda in every environment.
  lambda_pull_source_arns = each.value.lambda_pull ? ["arn:aws:lambda:${var.region}:${data.aws_caller_identity.current.account_id}:function:ci-cd-lab-*"] : []
}
