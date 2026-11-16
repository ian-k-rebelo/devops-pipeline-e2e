# Trivy image used by the vulnerability scans (.github/scripts/scan-trivy.sh) in the CI and the scheduled scan
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Trivy versions (tag and digest), with the cooldown.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the image must be signed by the Trivy release workflow of the version in the tag.
FROM aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb
