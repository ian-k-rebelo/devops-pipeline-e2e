# jq image: the CI and the local setup take the jq binary from this image
# (.github/scripts/install-jq.sh), so that both use exactly the same jq.
# This file is never built: the script reads the image from the FROM line below.
# It exists so that Dependabot can propose new jq versions (tag and digest), with the cooldown.
# The image is attested by the jq release workflow (cosign verify-attestation), and its /jq
# binary was checked against the GPG-signed jq-1.8.2 release binary (same sha256).
FROM ghcr.io/jqlang/jq:1.8.2@sha256:b9c68867e5766576263a222e91db3de422d802069c7af70440e667a95344e486
