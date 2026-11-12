#!/usr/bin/env bash
# Verifies that the tool image pinned in tools/<tool>/Dockerfile is the official image of the
# version in its tag:
#   - who built it: a signature or attestation made by the tool's own release workflow, from the
#     commit of that version's tag (cosign, keyless, recorded in the Rekor transparency log);
#   - for the images that are not signed themselves (Syft, Grype, hadolint) and for jq, that the
#     binary in the image (linux/amd64, the platform of the CI) is byte for byte the binary of that
#     release.
# ShellCheck publishes no signatures: its binary is only compared with the binary of the release.
# Every tool: the GitHub release of that version must be at least 7 days old (a compromised
# release is usually found and withdrawn within days), unless tools/release-age-exceptions.json
# has a valid exception for that tag.
# Used by .github/workflows/verify-tools.yml on pull requests that change a tool image, and by hand
# to audit all of them.
# Usage: verify-tool-image.sh trivy|syft|grype|jq|hadolint|shellcheck
# Needs: docker, cosign, git, curl, jq, sha256sum. Adds a row to $GITHUB_STEP_SUMMARY when it is set.
# GITHUB_TOKEN, when set, authenticates the requests to the GitHub API (higher rate limit).
# TOOL_DOCKERFILE, TOOL_EXCEPTIONS and TOOL_TODAY (YYYY-MM-DD) replace the Dockerfile, the exceptions
# file and today's date, only to test this script.
set -euo pipefail

USAGE="usage: verify-tool-image.sh trivy|syft|grype|jq|hadolint|shellcheck"
TOOL="${1:?${USAGE}}"
case "${TOOL}" in
  trivy | syft | grype | jq | hadolint | shellcheck) ;;
  *) echo "${USAGE}" >&2; exit 1 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DOCKERFILE="${TOOL_DOCKERFILE:-${REPO_ROOT}/tools/${TOOL}/Dockerfile}"
ISSUER=https://token.actions.githubusercontent.com
MIN_RELEASE_AGE_DAYS=7
EXCEPTIONS="${TOOL_EXCEPTIONS:-${REPO_ROOT}/tools/release-age-exceptions.json}"
TODAY="${TOOL_TODAY:-$(date -u +%F)}"
if [[ ! "${TODAY}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "TOOL_TODAY must be YYYY-MM-DD, found: '${TODAY}'" >&2
  exit 1
fi
RESULT="✅"
AGE_NOTE=""
WORK="$(mktemp -d)"
# On exit: delete the work folder and, if the check failed, add a failed row to the summary
finish() {
  local code=$?
  rm -rf "${WORK}"
  if [[ "${code}" -ne 0 && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "| ${TOOL} | ${TAG:-?} | ${RELEASED:-?} | \`${DIGEST:-?}\` | verification failed, see the job log | ❌ |" >> "${GITHUB_STEP_SUMMARY}"
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

# Prints the answer of the GitHub API to a GET request for a path ($1); authenticated when
# GITHUB_TOKEN is set (higher rate limit)
github_api() {
  local auth=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    auth=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  fi
  curl -fsSL --retry 3 "${auth[@]}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/$1"
}

# Fails unless the GitHub release with tag $2 of repository $1 was published at least
# MIN_RELEASE_AGE_DAYS days ago (whole days, UTC), or tools/release-age-exceptions.json has a valid
# exception for this tool and TAG. Sets RELEASED (the publication date) for the summary
check_release_age() {
  local published days latest expired matches expires reason
  published="$(github_api "repos/$1/releases/tags/$2" | jq -r '.published_at // empty')"
  if [[ ! "${published}" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T ]]; then
    echo "Release $2 of $1 has no publication date" >&2
    return 1
  fi
  RELEASED="${BASH_REMATCH[1]}"
  days=$(( ($(date -u -d "${TODAY}" +%s) - $(date -u -d "${RELEASED}" +%s)) / 86400 ))
  echo "Release $2 of $1 published on ${RELEASED}: ${days} days before ${TODAY}"

  # The exceptions: an object with an "exceptions" list; each one names a tool, its exact image
  # tag, the reason (one line, no "|") and the last day it is valid
  if ! jq -e '(.exceptions | type == "array") and all(.exceptions[];
      (.tool | type == "string") and (.tag | type == "string")
      and (.reason | type == "string" and length > 0 and (test("[|\n]") | not))
      and (.expires | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")))' \
      "${EXCEPTIONS}" > /dev/null; then
    echo "Malformed exceptions file: ${EXCEPTIONS}" >&2
    return 1
  fi
  # An expired exception must be removed, even when this tag does not need it any more
  expired="$(jq -r --arg tool "${TOOL}" --arg today "${TODAY}" \
    '.exceptions[] | select(.tool == $tool and .expires < $today) | "\(.tag) (expired on \(.expires))"' \
    "${EXCEPTIONS}")"
  if [[ -n "${expired}" ]]; then
    echo "Remove the expired release age exceptions for ${TOOL}: ${expired}" >&2
    return 1
  fi
  matches="$(jq -r --arg tool "${TOOL}" --arg tag "${TAG}" \
    '[.exceptions[] | select(.tool == $tool and .tag == $tag)] | length' "${EXCEPTIONS}")"
  if [[ "${matches}" -gt 1 ]]; then
    echo "More than one release age exception for ${TOOL} ${TAG}" >&2
    return 1
  fi
  if [[ "${days}" -ge "${MIN_RELEASE_AGE_DAYS}" ]]; then
    return 0
  fi
  if [[ "${matches}" -eq 0 ]]; then
    echo "The release is ${days} days old, and the minimum is ${MIN_RELEASE_AGE_DAYS}: wait, or add an exception to tools/release-age-exceptions.json (docs/ci-security.md, section 3)" >&2
    return 1
  fi
  expires="$(jq -r --arg tool "${TOOL}" --arg tag "${TAG}" \
    '.exceptions[] | select(.tool == $tool and .tag == $tag) | .expires' "${EXCEPTIONS}")"
  reason="$(jq -r --arg tool "${TOOL}" --arg tag "${TAG}" \
    '.exceptions[] | select(.tool == $tool and .tag == $tag) | .reason' "${EXCEPTIONS}")"
  # An exception only covers the days before the release is old enough
  latest="$(date -u -d "${RELEASED} + ${MIN_RELEASE_AGE_DAYS} days" +%F)"
  if [[ "${expires}" > "${latest}" ]]; then
    echo "The exception for ${TOOL} ${TAG} expires on ${expires}, after ${latest}, the day the release is ${MIN_RELEASE_AGE_DAYS} days old" >&2
    return 1
  fi
  echo "Release age exception for ${TOOL} ${TAG}, until ${expires}: ${reason}"
  AGE_NOTE="; release only ${days} days old, accepted by an exception until ${expires}: ${reason}"
  RESULT="⚠️"
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
  check_release_age "${repo}" "v${version}"
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
  check_release_age "${repo}" "${tag}"
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
  check_release_age "${repo}" "${tag}"
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

# hadolint: the release binaries are attested by the release workflow, which runs on master and
# tags that commit. The attestation is read from the GitHub API, and the binary in the image must
# be the attested release binary
verify_hadolint() {
  read_image
  local repo=hadolint/hadolint
  local tag="${TAG}"
  local binary=hadolint-linux-x86_64
  local sha digest
  sha="$(tag_commit "${repo}" "${tag}")"
  check_release_age "${repo}" "${tag}"
  download "${repo}" "${tag}" "${binary}"
  digest="$(sha256sum "${WORK}/${binary}" | cut -d ' ' -f 1)"
  github_api "repos/${repo}/attestations/sha256:${digest}" > "${WORK}/attestations.json"
  jq -e '.attestations[0].bundle' "${WORK}/attestations.json" > "${WORK}/bundle.json"
  cosign verify-blob-attestation "${WORK}/${binary}" \
    --bundle "${WORK}/bundle.json" \
    --type https://slsa.dev/provenance/v1 \
    --certificate-identity "https://github.com/${repo}/.github/workflows/release.yml@refs/heads/master" \
    --certificate-oidc-issuer "${ISSUER}" \
    --certificate-github-workflow-sha "${sha}"
  extract_binary /bin/hadolint
  same_file "${WORK}/image-binary" "${WORK}/${binary}"
  METHOD="release binary attested by the hadolint release workflow at the ${tag} commit, and the binary in the image is the release binary"
}

# ShellCheck publishes no signatures or checksums: the only check is that the binary in the image
# (Docker Hub) is the binary of the GitHub release, two distribution channels that must agree
verify_shellcheck() {
  read_image
  local repo=koalaman/shellcheck
  local tag="${TAG}"
  local archive="shellcheck-${tag}.linux.x86_64.tar.xz"
  tag_commit "${repo}" "${tag}" > /dev/null
  check_release_age "${repo}" "${tag}"
  download "${repo}" "${tag}" "${archive}"
  tar -xJf "${WORK}/${archive}" -C "${WORK}" "shellcheck-${tag}/shellcheck"
  extract_binary /bin/shellcheck
  same_file "${WORK}/image-binary" "${WORK}/shellcheck-${tag}/shellcheck"
  METHOD="no signature published: the binary in the image is the binary of the GitHub release ${tag}"
  RESULT="⚠️"
}

# ---------- entry point ----------

case "${TOOL}" in
  trivy) verify_trivy ;;
  syft | grype) verify_anchore "${TOOL}" ;;
  jq) verify_jq ;;
  hadolint) verify_hadolint ;;
  shellcheck) verify_shellcheck ;;
esac

METHOD="${METHOD}${AGE_NOTE}"
echo "VERIFIED ${TOOL} ${TAG} (released ${RELEASED}) ${DIGEST}: ${METHOD}"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "| ${TOOL} | ${TAG} | ${RELEASED} | \`${DIGEST}\` | ${METHOD} | ${RESULT} |" >> "${GITHUB_STEP_SUMMARY}"
fi
