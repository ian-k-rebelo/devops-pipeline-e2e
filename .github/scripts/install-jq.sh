#!/usr/bin/env bash
# Installs jq from the image pinned in tools/jq/Dockerfile, so that the CI and the
# local setup use exactly the same jq binary, and Dependabot keeps it up to date.
# The image is FROM scratch (it only has /jq), so the binary is copied out of a
# container that is created but never started.
# Usage: install-jq.sh <destination directory>
# JQ_DOCKERFILE replaces the path of the Dockerfile, only to test this script.
set -euo pipefail

DEST="${1:?usage: install-jq.sh <destination directory>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${JQ_DOCKERFILE:-${REPO_ROOT}/tools/jq/Dockerfile}"

JQ_IMAGE="$(sed -n 's/^FROM //p' "${DOCKERFILE}")"
if [[ ! "${JQ_IMAGE}" =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "The jq image must be pinned by digest, found: '${JQ_IMAGE}'" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64)  PLATFORM=linux/amd64 ;;
  aarch64) PLATFORM=linux/arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p "${DEST}"
CID="$(docker create --platform "${PLATFORM}" "${JQ_IMAGE}")"
trap 'docker rm "${CID}" > /dev/null' EXIT
docker cp "${CID}:/jq" "${DEST}/jq.tmp"
chmod 0755 "${DEST}/jq.tmp"
mv "${DEST}/jq.tmp" "${DEST}/jq"

echo "Installed $("${DEST}/jq" --version) from ${JQ_IMAGE} (${PLATFORM})"
sha256sum "${DEST}/jq"
