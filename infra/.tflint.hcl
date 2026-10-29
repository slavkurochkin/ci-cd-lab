# tflint for every root and module under infra/. Project 8.
#
#   tflint --chdir=infra/modules/ecr-repository --config=$PWD/infra/.tflint.hcl
#
# The bundled terraform ruleset only, at its strictest preset. It checks the
# code, not AWS: unused declarations, undocumented variables and outputs,
# missing types, and version constraints.

plugin "terraform" {
  enabled = true
  preset  = "all"
}
