# Syft image used to generate the SBOM in .github/workflows/ci.yml
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Syft versions (tag and digest), with the cooldown.
# nonroot variant: Syft runs without root privileges and only reads the image archive.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the binary in the image must be the binary of the signed release of the version in the tag.
FROM anchore/syft:v1.56.0-nonroot@sha256:1c455d72a4637f9d38b90e0c55a283886424f54576443a33d909a1be0081ce40
