# Rule 1: no S3 bucket can be made public.
package terraform

import rego.v1

flags := ["block_public_acls", "block_public_policy", "ignore_public_acls", "restrict_public_buckets"]

deny contains msg if {
	some r in resources_of("aws_s3_bucket_public_access_block")
	some flag in flags
	r.change.after[flag] != true
	msg := sprintf("%s: %s must be true. Each of the four flags closes a different route to public.", [r.address, flag])
}

deny contains msg if {
	some r in resources_of("aws_s3_bucket_acl")
	startswith(r.change.after.acl, "public-")
	msg := sprintf("%s: acl %q makes the bucket public.", [r.address, r.change.after.acl])
}

# A bucket without a public access block falls back to the account setting,
# which is a setting someone can change.
deny contains msg if {
	count(resources_of("aws_s3_bucket")) > count(resources_of("aws_s3_bucket_public_access_block"))
	msg := sprintf("%d bucket(s) but only %d public access block(s). Every bucket needs its own.", [
		count(resources_of("aws_s3_bucket")),
		count(resources_of("aws_s3_bucket_public_access_block")),
	])
}
