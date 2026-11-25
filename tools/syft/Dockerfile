# Syft image used to generate the SBOM in .github/workflows/ci.yml
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Syft versions (tag and digest), with the cooldown.
# nonroot variant: Syft runs without root privileges and only reads the image archive.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the binary in the image must be the binary of the signed release of the version in the tag.
FROM anchore/syft:v1.57.2-nonroot@sha256:00a4400827744854ef77b10679e38f991bf74fd20e3f03ffada8d6ee492520c3
