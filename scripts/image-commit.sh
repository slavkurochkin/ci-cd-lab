#!/usr/bin/env bash
# Print the commit an image was built from, given its digest. Capstone C.
#
#   scripts/image-commit.sh sha256:4cfbe4d8...      → e0c89ac611b3...
#
# Reads GIT_SHA from the image's own config on GHCR (public, anonymous), so
# the answer comes from the artifact, not from a commit message or a
# spreadsheet someone keeps.
set -euo pipefail

digest="${1:?digest}"
image="${IMAGE:-slavkurochkin/ci-cd-lab/api}"
token=$(curl -fsS "https://ghcr.io/token?scope=repository:${image}:pull" | jq -r .token)
get() { curl -fsSL -H "Authorization: Bearer ${token}" -H "Accept: $2" "https://ghcr.io/v2/${image}/$1"; }

manifest=$(get "manifests/${digest}" "application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json")
# An index (what CI pushes, with its attestations) points at one manifest per
# platform; the nodes run linux/amd64.
if [ "$(jq -r '.mediaType // empty' <<<"${manifest}")" = "application/vnd.oci.image.index.v1+json" ]; then
  platform=$(jq -r '.manifests[] | select(.platform.os=="linux" and .platform.architecture=="amd64") | .digest' <<<"${manifest}" | head -1)
  manifest=$(get "manifests/${platform}" "application/vnd.oci.image.manifest.v1+json")
fi
config=$(jq -r .config.digest <<<"${manifest}")
get "blobs/${config}" "application/octet-stream" | jq -r '.config.Env[] | select(startswith("GIT_SHA=")) | sub("^GIT_SHA="; "")'
