#!/usr/bin/env bash
# Lints the pipeline and infrastructure code with the tools pinned in tools/, the same way on a
# laptop and in the CI (.github/workflows/lint.yml):
#   - actionlint: the workflows, and the shell of their run steps (with ShellCheck)
#   - ShellCheck: the shell scripts (*.sh)
#   - hadolint: the Dockerfiles
# Two phases:
#   1. Prepare, with network: build actionlint from tools/go/go.mod in the Go toolchain image
#      (tools/golang/Dockerfile), every module checked against tools/go/go.sum; copy the hadolint
#      and ShellCheck binaries out of their pinned images (the images Tool images verifies).
#   2. Lint, in a sandbox: each tool runs in a container with no network, a read-only file system
#      and no Linux capabilities, as the current user, with the repository mounted read-only.
#      A compromised tool can neither send anything out nor change the code.
# Only the files tracked by git are linted (git add a new file to lint it). Every tool runs, even
# after a failure, so one run shows every problem.
# Usage: lint.sh
# Needs: docker, git. No sudo.
# LINT_CACHE replaces the folder of the Go module and build cache
# (default: ~/.cache/devops-pipeline-e2e/lint), kept between runs so that the next ones are faster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CACHE="${LINT_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/devops-pipeline-e2e/lint}"

case "$(uname -m)" in
  x86_64)  PLATFORM=linux/amd64 ;;
  aarch64) PLATFORM=linux/arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${CACHE}/mod" "${CACHE}/build" "${CACHE}/tmp"

# Prints the image in the FROM line of tools/<tool>/Dockerfile; it must be name:tag@sha256:digest
pinned_image() {
  local from
  from="$(sed -n 's/^FROM //p' "${REPO_ROOT}/tools/$1/Dockerfile")"
  if [[ ! "${from}" =~ ^[^:@]+:[^@]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "tools/$1/Dockerfile: the image must be name:tag@sha256:digest, found: '${from}'" >&2
    return 1
  fi
  echo "${from}"
}

# Copies a binary ($3) out of an image ($2) into the work folder as $1, without running the
# image: the container is created, never started
copy_binary() {
  local cid
  echo "$1: $2"
  cid="$(docker create --platform "${PLATFORM}" "$2")"
  docker cp "${cid}:$3" "${WORK}/bin/$1" > /dev/null
  docker rm "${cid}" > /dev/null
}

# Every image is checked before anything runs
GOLANG_IMAGE="$(pinned_image golang)"
SHELLCHECK_IMAGE="$(pinned_image shellcheck)"
HADOLINT_IMAGE="$(pinned_image hadolint)"

# Options of every container: removed at the end, as the current user (not root), read-only file
# system with an empty /tmp in memory, no Linux capabilities, no privilege escalation
SANDBOX=(
  --rm --platform "${PLATFORM}"
  --user "$(id -u):$(id -g)"
  --read-only --tmpfs /tmp -e HOME=/tmp
  --cap-drop ALL --security-opt no-new-privileges
)

echo "==> Prepare (with network)"
echo "golang: ${GOLANG_IMAGE}"
# Only tools/go is mounted, read-only. GOTOOLCHAIN=local: never download another Go toolchain;
# GOPROXY without "direct": modules only come from the Go module proxy; -mod=readonly: go.mod and
# go.sum are never changed, and a module that is not in go.sum is an error
docker run "${SANDBOX[@]}" \
  -v "${REPO_ROOT}/tools/go:/src:ro" -v "${CACHE}:/cache" -v "${WORK}/bin:/out" -w /src \
  -e GOMODCACHE=/cache/mod -e GOCACHE=/cache/build -e GOTMPDIR=/cache/tmp \
  -e GOTOOLCHAIN=local -e GOPROXY=https://proxy.golang.org -e GOFLAGS=-mod=readonly \
  -e CGO_ENABLED=0 \
  "${GOLANG_IMAGE}" go build -trimpath -o /out/ github.com/rhysd/actionlint/cmd/actionlint
copy_binary shellcheck "${SHELLCHECK_IMAGE}" /bin/shellcheck
copy_binary hadolint "${HADOLINT_IMAGE}" /bin/hadolint

# Runs a lint command in the sandbox, with no network; the repository is /src (read-only) and the
# binaries are in /tools (read-only). A failure is recorded and the next tool still runs
FAILED=""
lint() {
  local name="$1"
  shift
  echo "==> ${name}"
  if docker run "${SANDBOX[@]}" --network none \
    -v "${REPO_ROOT}:/src:ro" -v "${WORK}/bin:/tools:ro" -w /src \
    "${GOLANG_IMAGE}" "$@"; then
    echo "${name}: no problems found"
  else
    FAILED="${FAILED} ${name}"
  fi
}

# The files to lint: only the files tracked by git
mapfile -t WORKFLOWS < <(git -C "${REPO_ROOT}" ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml')
mapfile -t SCRIPTS < <(git -C "${REPO_ROOT}" ls-files -- '*.sh')
mapfile -t DOCKERFILES < <(git -C "${REPO_ROOT}" ls-files -- '*Dockerfile')
if [[ ${#WORKFLOWS[@]} -eq 0 || ${#SCRIPTS[@]} -eq 0 || ${#DOCKERFILES[@]} -eq 0 ]]; then
  echo "No workflows, shell scripts or Dockerfiles found: is ${REPO_ROOT} a git repository?" >&2
  exit 1
fi

echo "==> Lint (no network, read-only)"
lint actionlint /tools/actionlint -shellcheck /tools/shellcheck -pyflakes= "${WORKFLOWS[@]}"
lint shellcheck /tools/shellcheck "${SCRIPTS[@]}"
lint hadolint /tools/hadolint --no-color "${DOCKERFILES[@]}"

if [[ -n "${FAILED}" ]]; then
  echo "Lint failed:${FAILED}" >&2
  exit 1
fi
echo "Lint passed: actionlint, shellcheck, hadolint"
