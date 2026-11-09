#!/usr/bin/env bash
# Verifies that the tool image pinned in .github/<tool>/Dockerfile is the official image of the
# version in its tag:
#   - who built it: a signature or attestation made by the tool's own release workflow, from the
#     commit of that version's tag (cosign, keyless, recorded in the Rekor transparency log);
#   - for the images that are not signed themselves (Syft, Grype) and for jq, that the binary in
#     the image (linux/amd64, the platform of the CI) is byte for byte the binary of that release.
# Used by .github/workflows/verify-tools.yml on pull requests that change a tool image, and by hand
# to audit all of them.
# Usage: verify-tool-image.sh trivy|syft|grype|jq
# Needs: docker, cosign, git, curl, sha256sum. Adds a row to $GITHUB_STEP_SUMMARY when it is set.
# TOOL_DOCKERFILE replaces the path of the Dockerfile, only to test this script.
set -euo pipefail

USAGE="usage: verify-tool-image.sh trivy|syft|grype|jq"
TOOL="${1:?${USAGE}}"
case "${TOOL}" in
  trivy | syft | grype | jq) ;;
  *) echo "${USAGE}" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${TOOL_DOCKERFILE:-${REPO_ROOT}/.github/${TOOL}/Dockerfile}"
ISSUER=https://token.actions.githubusercontent.com
WORK="$(mktemp -d)"
# On exit: delete the work folder and, if the check failed, add a failed row to the summary
finish() {
  local code=$?
  rm -rf "${WORK}"
  if [[ "${code}" -ne 0 && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "| ${TOOL} | ${TAG:-?} | \`${DIGEST:-?}\` | verification failed, see the job log | ❌ |" >> "${GITHUB_STEP_SUMMARY}"
  fi
}
trap finish EXIT

# ---------- shared helpers ----------

# Reads the FROM line into IMAGE, TAG and DIGEST; the image must be name:tag@sha256:digest
read_image() {
  local from
  from="$(sed -n 's/^FROM //p' "${DOCKERFILE}")"
  if [[ ! "${from}" =~ ^([^:@]+):([^@]+)@(sha256:[0-9a-f]{64})$ ]]; then
    echo "The image must be name:tag@sha256:digest, found: '${from}'" >&2
    return 1
  fi
  IMAGE="${BASH_REMATCH[1]}"
  TAG="${BASH_REMATCH[2]}"
  DIGEST="${BASH_REMATCH[3]}"
  echo "Image: ${IMAGE}:${TAG}@${DIGEST}"
}

# Prints the commit of a release tag ($2) in a GitHub repository ($1): the signature must have
# been made by the release workflow running on that commit
tag_commit() {
  local refs sha
  refs="$(git ls-remote --tags "https://github.com/$1.git" "refs/tags/$2" "refs/tags/$2^{}")"
  # An annotated tag is listed twice; the "^{}" line is the commit it points to
  sha="$(awk -v ref="refs/tags/$2^{}" '$2 == ref { print $1 }' <<< "${refs}")"
  if [[ -z "${sha}" ]]; then
    sha="$(awk -v ref="refs/tags/$2" '$2 == ref { print $1 }' <<< "${refs}")"
  fi
  if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Tag $2 not found in $1" >&2
    return 1
  fi
  echo "Tag $2 of $1 -> commit ${sha}" >&2
  echo "${sha}"
}

# Downloads a file ($3) of the GitHub release with tag $2 of repository $1 into the work folder
download() {
  curl -fsSL --retry 3 -o "${WORK}/$3" "https://github.com/$1/releases/download/$2/$3"
}

# Copies a file ($1) out of the image (linux/amd64) into the work folder, as image-binary;
# the container is created but never started
extract_binary() {
  local cid
  cid="$(docker create --platform linux/amd64 "${IMAGE}@${DIGEST}")"
  docker cp "${cid}:$1" "${WORK}/image-binary" > /dev/null
  docker rm "${cid}" > /dev/null
}

# Fails unless the two files ($1 and $2) are byte for byte the same
same_file() {
  local a b
  a="$(sha256sum "$1" | cut -d ' ' -f 1)"
  b="$(sha256sum "$2" | cut -d ' ' -f 1)"
  echo "sha256 of the binary in the image:   ${a}"
  echo "sha256 of the binary of the release: ${b}"
  if [[ "${a}" != "${b}" ]]; then
    echo "The binary in the image is not the binary of the release" >&2
    return 1
  fi
}

# ---------- one function per tool ----------

# Trivy: the image itself is signed by the release workflow of the version tag
verify_trivy() {
  read_image
  local version="${TAG#v}"
  local repo=aquasecurity/trivy
  local ref="refs/tags/v${version}"
  local sha
  sha="$(tag_commit "${repo}" "v${version}")"
  cosign verify "${IMAGE}@${DIGEST}" \
    --certificate-identity-regexp "^https://github\.com/${repo//./\\.}/\.github/workflows/.+@${ref//./\\.}$" \
    --certificate-oidc-issuer "${ISSUER}" \
    --certificate-github-workflow-repository "${repo}" \
    --certificate-github-workflow-ref "${ref}" \
    --certificate-github-workflow-sha "${sha}" > /dev/null
  METHOD="image signed by the Trivy release workflow at v${version}"
}

# Syft and Grype: the images are not signed, but the release checksums are. The release workflow
# runs on main and tags that commit, so the signature must come from the commit of the version tag
verify_anchore() {
  local tool="$1"
  read_image
  local version="${TAG#v}"
  version="${version%%-*}"
  local repo="anchore/${tool}"
  local tag="v${version}"
  local checksums="${tool}_${version}_checksums.txt"
  local archive="${tool}_${version}_linux_amd64.tar.gz"
  local sha
  sha="$(tag_commit "${repo}" "${tag}")"
  download "${repo}" "${tag}" "${checksums}"
  download "${repo}" "${tag}" "${checksums}.sigstore.json"
  download "${repo}" "${tag}" "${archive}"
  cosign verify-blob "${WORK}/${checksums}" \
    --bundle "${WORK}/${checksums}.sigstore.json" \
    --certificate-identity "https://github.com/${repo}/.github/workflows/release.yaml@refs/heads/main" \
    --certificate-oidc-issuer "${ISSUER}" \
    --certificate-github-workflow-repository "${repo}" \
    --certificate-github-workflow-sha "${sha}"
  (cd "${WORK}" && grep " ${archive}\$" "${checksums}" | sha256sum -c -)
  tar -xzf "${WORK}/${archive}" -C "${WORK}" "${tool}"
  extract_binary "/${tool}"
  same_file "${WORK}/image-binary" "${WORK}/${tool}"
  METHOD="signed release checksums (${tag}), and the binary in the image is the release binary"
}

# jq: the image has a provenance attestation, and so does the release binary; both from the jq
# release workflow at the version tag, and the binary in the image must be the release binary
verify_jq() {
  read_image
  local repo=jqlang/jq
  local tag="jq-${TAG}"
  local identity="https://github.com/${repo}/.github/workflows/ci.yml@refs/tags/${tag}"
  local sha
  sha="$(tag_commit "${repo}" "${tag}")"
  cosign verify-attestation "${IMAGE}@${DIGEST}" \
    --type https://slsa.dev/provenance/v1 \
    --certificate-identity "${identity}" \
    --certificate-oidc-issuer "${ISSUER}" \
    --certificate-github-workflow-sha "${sha}" > /dev/null
  download "${repo}" "${tag}" jq-linux-amd64
  download "${repo}" "${tag}" jq-attestation.json
  cosign verify-blob-attestation "${WORK}/jq-linux-amd64" \
    --bundle "${WORK}/jq-attestation.json" \
    --type https://slsa.dev/provenance/v1 \
    --certificate-identity "${identity}" \
    --certificate-oidc-issuer "${ISSUER}" \
    --certificate-github-workflow-sha "${sha}"
  extract_binary /jq
  same_file "${WORK}/image-binary" "${WORK}/jq-linux-amd64"
  METHOD="image and release binary attested by the jq release workflow at ${tag}, and the binary in the image is the release binary"
}

# ---------- entry point ----------

case "${TOOL}" in
  trivy) verify_trivy ;;
  syft | grype) verify_anchore "${TOOL}" ;;
  jq) verify_jq ;;
esac

echo "VERIFIED ${TOOL} ${TAG} ${DIGEST}: ${METHOD}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "| ${TOOL} | ${TAG} | \`${DIGEST}\` | ${METHOD} | ✅ |" >> "${GITHUB_STEP_SUMMARY}"
fi
