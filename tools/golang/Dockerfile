# Go toolchain image: builds the Go tools pinned in tools/go/go.mod (actionlint, kubeconform
# and kustomize) and tools/helm/go.mod (helm). This file is never built: the scripts read the
# image from the FROM line below.
# It exists so that Dependabot can propose new Go versions (tag and digest), with the cooldown.
# Docker Official Image, pinned by digest like the base image of the application; the Go
# toolchain checks every module against the go.sum files and the public Go checksum database.
FROM golang:1.27.4-trixie@sha256:f18c3d73a184fb0582828510722e723b63a93f7188d11dd223d9be6f6880e65d
