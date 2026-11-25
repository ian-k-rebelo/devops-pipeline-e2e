# Grype image used to scan the SBOM (.github/scripts/scan-grype.sh) in the CI and the scheduled scan
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Grype versions (tag and digest), with the cooldown.
# nonroot variant: Grype runs without root privileges and only reads the SBOM.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the binary in the image must be the binary of the signed release of the version in the tag.
FROM anchore/grype:v0.122.1-nonroot@sha256:35e6adfef62c2d04fa4995a30dd28829963ce62506c343bf3ed4ae9b5db1dadc
