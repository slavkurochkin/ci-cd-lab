# Rule 2: every taggable resource is tagged with who owns it and what made it.
#
# Checks tags_all, not tags: tags_all is what AWS receives, including
# provider default_tags. A resource relying on default_tags passes; a provider
# block that lost its default_tags fails every resource at once.
package terraform

import rego.v1

required_tags := ["Project", "ManagedBy", "Environment"]

deny contains msg if {
	some r in resources
	"tags_all" in object.keys(r.change.after)
	some tag in required_tags
	not r.change.after.tags_all[tag]
	msg := sprintf("%s: missing tag %q. Without it, nobody can tell from the bill what this is or who to ask.", [r.address, tag])
}
