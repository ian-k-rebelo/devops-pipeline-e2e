# hadolint image: lints the Dockerfiles.
# This file is never built: the scripts read the image from the FROM line below.
# It exists so that Dependabot can propose new hadolint versions (tag and digest), with the cooldown.
# Every pull request that changes it is checked by .github/workflows/verify-tools.yml: the release
# binary must be attested by the hadolint release workflow, and the binary in the image must be
# the release binary.
FROM ghcr.io/hadolint/hadolint:v2.15.1@sha256:32dac94127fd60b7b7e3fbfc65e1383b9b5e25c9bfd7b8536de7a539fe68a12d
