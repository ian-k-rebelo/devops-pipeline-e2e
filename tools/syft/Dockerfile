# Syft image used to generate the SBOM in .github/workflows/ci.yml
# This file is never built: the CI reads the image from the FROM line below.
# It exists so that Dependabot can propose new Syft versions (tag and digest), with the cooldown.
# nonroot variant: Syft runs without root privileges and only reads the image archive.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml:
# the binary in the image must be the binary of the signed release of the version in the tag.
FROM anchore/syft:v1.55.0-nonroot@sha256:ec5bdbc745485920c6f444239f0c09ed87b3c4c165ff9433f95bc66b3500fbf9
