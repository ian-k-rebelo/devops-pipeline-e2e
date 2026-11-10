# Go toolchain image: builds the Go tools pinned in .github/tools/go.mod (actionlint, kubeconform
# and kustomize). This file is never built: the scripts read the image from the FROM line below.
# It exists so that Dependabot can propose new Go versions (tag and digest), with the cooldown.
# Docker Official Image, pinned by digest like the base image of the application; the Go
# toolchain checks every module against .github/tools/go.sum and the public Go checksum database.
FROM golang:1.27.3-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80
