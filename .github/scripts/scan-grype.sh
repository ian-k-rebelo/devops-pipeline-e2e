#!/usr/bin/env bash
# Scans an SBOM (CycloneDX JSON) with the Grype image pinned in .github/grype/Dockerfile.
# Grype also reads compiled binaries listed in the SBOM, such as the Python interpreter,
# which Trivy does not see. Same policy as Trivy: fail on HIGH or CRITICAL vulnerabilities
# that already have a fix, show the others, and read the accepted ones from
# .github/vex/openvex.json. Grype runs as a non-root user, reads the SBOM and the VEX
# through read-only mounts, has no access to the Docker socket and does not check for updates.
# Used by the CI and by the scheduled scan.
# Usage: scan-grype.sh <sbom.cdx.json>
set -euo pipefail

SBOM="$(realpath "${1:?usage: scan-grype.sh <sbom.cdx.json>}")"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

GRYPE_IMAGE="$(sed -n 's/^FROM //p' "${REPO_ROOT}/.github/grype/Dockerfile")"
test -n "${GRYPE_IMAGE}"
echo "Grype image: ${GRYPE_IMAGE}"

# The non-root user in the Grype container must be able to read the SBOM
chmod a+r "${SBOM}"

docker run --rm \
  -e GRYPE_CHECK_FOR_APP_UPDATE=false \
  -v "${SBOM}:/in/sbom.cdx.json:ro" \
  -v "${REPO_ROOT}/.github/vex/openvex.json:/vex/openvex.json:ro" \
  "${GRYPE_IMAGE}" \
  sbom:/in/sbom.cdx.json --vex /vex/openvex.json \
  --fail-on high --only-fixed --show-suppressed
