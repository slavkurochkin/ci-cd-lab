#!/usr/bin/env bash
# Install a pinned conftest and check it against a pinned SHA-256.
#
# The checksum is in the workflow, not fetched from the release. A checksum
# downloaded from the same place as the binary only proves the download was
# not truncated.
set -euo pipefail

: "${CONFTEST_VERSION:?set CONFTEST_VERSION}"
: "${CONFTEST_SHA256:?set CONFTEST_SHA256}"

tarball="conftest_${CONFTEST_VERSION}_Linux_x86_64.tar.gz"
tmp=$(mktemp -d)
curl -fsSL -o "$tmp/$tarball" \
  "https://github.com/open-policy-agent/conftest/releases/download/v${CONFTEST_VERSION}/${tarball}"
echo "${CONFTEST_SHA256}  $tmp/$tarball" | sha256sum --check --strict
tar -xzf "$tmp/$tarball" -C "$tmp" conftest
sudo install -m 0755 "$tmp/conftest" /usr/local/bin/conftest
conftest --version
