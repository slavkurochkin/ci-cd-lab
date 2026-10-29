# Rule 3: no wildcard IAM.
#
# Two shapes: an action of "*" or "<service>:*" anywhere, and a write action
# on resource "*". A few actions have no resource to scope to, and are listed.
package terraform

import rego.v1

policy_types := {"aws_iam_policy", "aws_iam_role_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

# Actions AWS defines only at account level. Resource "*" is the only option.
account_level_actions := {"ecr:GetAuthorizationToken", "sts:GetCallerIdentity"}

statements contains [r.address, s] if {
	some r in resources
	r.type in policy_types
	doc := json.unmarshal(r.change.after.policy)
	some s in as_array(doc.Statement)
	s.Effect == "Allow"
}

as_array(x) := x if is_array(x)

as_array(x) := [x] if not is_array(x)

deny contains msg if {
	some [address, s] in statements
	some action in as_array(s.Action)
	endswith(action, "*")
	not contains(action, ":Get")
	not contains(action, ":List")
	not contains(action, ":Describe")
	msg := sprintf("%s: action %q is a wildcard. Name the actions.", [address, action])
}

deny contains msg if {
	some [address, s] in statements
	"*" in as_array(s.Resource)
	some action in as_array(s.Action)
	not action in account_level_actions
	msg := sprintf("%s: %q on resource \"*\". Scope it to ARNs.", [address, action])
}
