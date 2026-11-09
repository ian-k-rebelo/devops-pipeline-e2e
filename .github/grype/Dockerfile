# Grype image used to scan the SBOM (.github/scripts/scan-grype.sh) in the CI and the scheduled scan
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Grype versions (tag and digest), with the cooldown.
# nonroot variant: Grype runs without root privileges and only reads the SBOM.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the binary in the image must be the binary of the signed release of the version in the tag.
FROM anchore/grype:v0.121.0-nonroot@sha256:f9b9a8edd0cbf3a120a150d92d9e98b2d93db297c94766dc60173afc096e714d
