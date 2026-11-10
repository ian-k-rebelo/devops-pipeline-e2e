#!/usr/bin/env bash
# Scans a container image with the Trivy image pinned in tools/trivy/Dockerfile.
# Policy: fail on HIGH or CRITICAL vulnerabilities that already have a fix, and show the
# accepted ones (read from .github/vex/openvex.json) as suppressed. Trivy also looks for
# secrets in the image files. With --skip-version-check and --disable-telemetry together,
# Trivy does not call its update service (no version check and no anonymous usage data);
# it still downloads its vulnerability database. Used by the CI and by the scheduled scan.
# Usage: scan-trivy.sh local <image>   image in the local Docker, read through the Docker socket
#        scan-trivy.sh remote <image>  image in a registry, pinned by digest (no Docker socket)
set -euo pipefail

USAGE="usage: scan-trivy.sh local|remote <image>"
MODE="${1:?${USAGE}}"
IMAGE="${2:?${USAGE}}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

DOCKER_ARGS=(--rm -v "${REPO_ROOT}/.github/vex/openvex.json:/vex/openvex.json:ro")
case "${MODE}" in
  local)
    DOCKER_ARGS+=(-v /var/run/docker.sock:/var/run/docker.sock:ro)
    IMAGE_SRC=docker
    ;;
  remote)
    if [[ ! "${IMAGE}" =~ @sha256:[0-9a-f]{64}$ ]]; then
      echo "A remote image must be pinned by digest, found: '${IMAGE}'" >&2
      exit 1
    fi
    IMAGE_SRC=remote
    ;;
  *)
    echo "${USAGE}" >&2
    exit 1
    ;;
esac

TRIVY_IMAGE="$(sed -n 's/^FROM //p' "${REPO_ROOT}/tools/trivy/Dockerfile")"
test -n "${TRIVY_IMAGE}"
echo "Trivy image: ${TRIVY_IMAGE}"

docker run "${DOCKER_ARGS[@]}" "${TRIVY_IMAGE}" \
  image --image-src "${IMAGE_SRC}" \
  --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1 \
  --no-progress --skip-version-check --disable-telemetry \
  --vex /vex/openvex.json --show-suppressed \
  "${IMAGE}"
