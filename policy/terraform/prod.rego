# Rule 4: prod never deletes data from CI: not a bucket, not the orders table.
#
# Run only for prod: `conftest test --namespace terraform --namespace
# terraform.prod`. Deleting a prod bucket is a decision a person makes from a
# laptop, after reading what is in it. An approval click on a plan with forty
# lines is not that decision.
package terraform.prod

import rego.v1

data_types := {"aws_s3_bucket", "aws_dynamodb_table"}

deny contains msg if {
	some r in input.resource_changes
	r.type in data_types
	"delete" in r.change.actions
	msg := sprintf("%s: this plan deletes prod data (%s). Not from CI.", [r.address, concat("/", r.change.actions)])
}
