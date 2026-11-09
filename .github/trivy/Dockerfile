# Trivy image used by the vulnerability scans (.github/scripts/scan-trivy.sh) in the CI and the scheduled scan
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Trivy versions (tag and digest), with the cooldown.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the image must be signed by the Trivy release workflow of the version in the tag.
FROM aquasec/trivy:0.76.1@sha256:790fd66d1697395d8693d1acaa1ea702406a20f109b6fc7bac8db623eca6c06c
