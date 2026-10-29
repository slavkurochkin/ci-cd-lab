# Unit tests for the policies: `conftest verify -p policy/terraform`.
# Each rule gets a plan it must reject and one it must accept.
package terraform_test

import rego.v1

import data.terraform
import data.terraform.prod

change(addr, type, actions, after) := {
	"address": addr, "type": type, "mode": "managed",
	"change": {"actions": actions, "after": after},
}

good_tags := {"Project": "ci-cd-lab", "ManagedBy": "terraform", "Environment": "dev"}

pab(flags) := change("aws_s3_bucket_public_access_block.this", "aws_s3_bucket_public_access_block", ["create"], flags)

bucket := change("aws_s3_bucket.this", "aws_s3_bucket", ["create"], {"tags_all": good_tags})

all_true := {"block_public_acls": true, "block_public_policy": true, "ignore_public_acls": true, "restrict_public_buckets": true}

# --- Rule 1: public S3 ------------------------------------------------------

test_private_bucket_passes if {
	count(terraform.deny) == 0 with input as {"resource_changes": [bucket, pab(all_true)]}
}

test_one_public_flag_is_denied if {
	flags := object.union(all_true, {"restrict_public_buckets": false})
	some msg in terraform.deny with input as {"resource_changes": [bucket, pab(flags)]}
	contains(msg, "restrict_public_buckets must be true")
}

test_bucket_without_access_block_is_denied if {
	some msg in terraform.deny with input as {"resource_changes": [bucket]}
	contains(msg, "1 bucket(s) but only 0")
}

test_public_acl_is_denied if {
	acl := change("aws_s3_bucket_acl.this", "aws_s3_bucket_acl", ["create"], {"acl": "public-read"})
	some msg in terraform.deny with input as {"resource_changes": [bucket, pab(all_true), acl]}
	contains(msg, "public-read")
}

# --- Rule 2: tags -----------------------------------------------------------

test_missing_tag_is_denied if {
	untagged := change("aws_s3_bucket.this", "aws_s3_bucket", ["create"], {"tags_all": {"Project": "ci-cd-lab"}})
	some msg in terraform.deny with input as {"resource_changes": [untagged, pab(all_true)]}
	contains(msg, "missing tag \"ManagedBy\"")
}

test_untaggable_resource_is_ignored if {
	count(terraform.deny) == 0 with input as {"resource_changes": [bucket, pab(all_true)]}
}

# --- Rule 3: IAM wildcards --------------------------------------------------

role_policy(statement) := change("aws_iam_role_policy.x", "aws_iam_role_policy", ["create"], {"policy": json.marshal({"Statement": [statement]})})

test_star_action_is_denied if {
	p := role_policy({"Effect": "Allow", "Action": "*", "Resource": "arn:aws:s3:::b"})
	some msg in terraform.deny with input as {"resource_changes": [p]}
	contains(msg, "is a wildcard")
}

test_service_write_wildcard_is_denied if {
	p := role_policy({"Effect": "Allow", "Action": ["s3:Put*"], "Resource": "arn:aws:s3:::b"})
	some msg in terraform.deny with input as {"resource_changes": [p]}
	contains(msg, "\"s3:Put*\" is a wildcard")
}

test_read_wildcard_is_allowed if {
	p := role_policy({"Effect": "Allow", "Action": ["s3:Get*", "s3:List*"], "Resource": "arn:aws:s3:::b"})
	count(terraform.deny) == 0 with input as {"resource_changes": [p]}
}

test_write_on_star_resource_is_denied if {
	p := role_policy({"Effect": "Allow", "Action": "s3:DeleteBucket", "Resource": "*"})
	some msg in terraform.deny with input as {"resource_changes": [p]}
	contains(msg, "on resource \"*\"")
}

test_account_level_action_on_star_is_allowed if {
	p := role_policy({"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"})
	count(terraform.deny) == 0 with input as {"resource_changes": [p]}
}

test_deny_statements_are_ignored if {
	p := role_policy({"Effect": "Deny", "Action": "*", "Resource": "*"})
	count(terraform.deny) == 0 with input as {"resource_changes": [p]}
}

# --- Rule 4: prod bucket deletion -------------------------------------------

test_prod_bucket_delete_is_denied if {
	gone := change("aws_s3_bucket.this", "aws_s3_bucket", ["delete"], null)
	count(prod.deny) == 1 with input as {"resource_changes": [gone]}
}

test_prod_bucket_replace_is_denied if {
	replaced := change("aws_s3_bucket.this", "aws_s3_bucket", ["delete", "create"], {"tags_all": good_tags})
	count(prod.deny) == 1 with input as {"resource_changes": [replaced]}
}

test_prod_bucket_update_is_allowed if {
	updated := change("aws_s3_bucket.this", "aws_s3_bucket", ["update"], {"tags_all": good_tags})
	count(prod.deny) == 0 with input as {"resource_changes": [updated]}
}

test_read_on_star_resource_is_allowed if {
	p := role_policy({"Effect": "Allow", "Action": "logs:DescribeLogGroups", "Resource": "*"})
	count(terraform.deny) == 0 with input as {"resource_changes": [p]}
}

test_prod_table_replace_is_denied if {
	replaced := change("aws_dynamodb_table.orders", "aws_dynamodb_table", ["delete", "create"], {"tags_all": good_tags})
	some msg in prod.deny with input as {"resource_changes": [replaced]}
	contains(msg, "deletes prod data")
}
