#!/usr/bin/env bash
# Checks the go.sum of a Go module of the repository against the public Go checksum database
# (sum.golang.org), which makes sure that every user gets the same code for a version.
# The Go toolchain only asks the database when it adds a line to go.sum: a build trusts the lines
# that are already there. Dependabot security updates for Go write go.sum without the database
# (GONOSUMDB=* in their job), so a pull request can bring lines that nobody checked.
# The check copies go.mod (only) to an empty folder, lets `go mod tidy` write a new go.sum with
# the database on and an empty module cache, and compares it with the go.sum of the repository:
# both files must be equal. A module whose code differs from the database stops `go mod tidy`
# with "SECURITY ERROR".
# It runs in the Go toolchain image (tools/golang/Dockerfile), as the current user, with a
# read-only file system and no Linux capabilities. It needs network: the Go module proxy and the
# checksum database.
# Usage: check-go-sum.sh <module folder>   (for example: tools/go, tools/helm)
# Needs: docker. No sudo.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${1:?usage: check-go-sum.sh <module folder, for example tools/go>}"
if [[ ! -f "${REPO_ROOT}/${MODULE}/go.mod" || ! -f "${REPO_ROOT}/${MODULE}/go.sum" ]]; then
  echo "${MODULE}: go.mod and go.sum not found" >&2
  exit 1
fi
GOLANG_IMAGE="$(sed -n 's/^FROM //p' "${REPO_ROOT}/tools/golang/Dockerfile")"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/module" "${WORK}/cache/tmp"
cp "${REPO_ROOT}/${MODULE}/go.mod" "${WORK}/module/go.mod"

echo "${MODULE}: writing a new go.sum with the checksum database (${GOLANG_IMAGE})"
# GOSUMDB on and no module left out of it (GONOSUMDB, GOPRIVATE and GOINSECURE empty); GOPROXY
# without "direct": modules only come from the Go module proxy; GOTOOLCHAIN=local: never download
# another Go toolchain; -modcacherw: the module cache can be deleted at the end. Everything the
# Go toolchain writes (GOPATH, with the state of the database, and the caches) is in /cache
docker run --rm --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp -e HOME=/tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "${WORK}/module:/src" -v "${WORK}/cache:/cache" -w /src \
  -e GOPATH=/cache/go -e GOMODCACHE=/cache/mod -e GOCACHE=/cache/build -e GOTMPDIR=/cache/tmp \
  -e GOTOOLCHAIN=local -e GOPROXY=https://proxy.golang.org -e GOSUMDB=sum.golang.org \
  -e GONOSUMDB= -e GOPRIVATE= -e GOINSECURE= -e GOFLAGS=-modcacherw \
  "${GOLANG_IMAGE}" go mod tidy

# go.mod must not change either: a change means that go.mod was not tidy
if diff -u "${REPO_ROOT}/${MODULE}/go.mod" "${WORK}/module/go.mod" \
  && diff -u "${REPO_ROOT}/${MODULE}/go.sum" "${WORK}/module/go.sum"; then
  echo "${MODULE}: go.sum matches the Go checksum database"
else
  echo "${MODULE}: go.mod or go.sum differs from what the Go checksum database gives (above)" >&2
  exit 1
fi
