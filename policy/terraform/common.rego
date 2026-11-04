# Helpers shared by every rule. Input is `terraform show -json <planfile>`.
package terraform

# Every resource that will exist after this plan: created, updated, replaced,
# or unchanged. Unchanged ("no-op") resources are included on purpose, so a
# rule added today also checks what was applied before it existed.
resources contains r if {
	some r in input.resource_changes
	not "delete" in r.change.actions
	r.mode == "managed"
}

resources_of(type) := {r | some r in resources; r.type == type}
