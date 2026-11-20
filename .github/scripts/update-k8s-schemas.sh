#!/usr/bin/env bash
# Generates the JSON schemas of tools/kubeconform/schemas, which kubeconform uses in the Lint to
# validate the Kubernetes manifests, from the sources pinned in tools/kubeconform/versions:
#   - core kinds: the schemas of yannh/kubernetes-json-schema, at a pinned commit
#   - Gateway API kinds: the CRDs of the Envoy Gateway gateway-crds-helm chart, pinned by digest,
#     rendered with the values of scripts/install-platform.sh and the helm of tools/helm/go.mod
#   - cert-manager kinds: the CRDs of the cert-manager release, pinned by checksum
# Two phases, like lint.sh:
#   1. Prepare, with network: build helm (every module checked against tools/helm/go.sum), pull the
#      chart, download the CRDs and the core schemas, install PyYAML (tools/python, by hash).
#   2. Generate, in a sandbox with no network: helm renders the chart, and
#      .github/scripts/crd-to-jsonschema.py converts the CRDs.
# The same versions always give the same files. Run it after changing tools/kubeconform/versions,
# then review the diff and commit the schemas with the versions.
# Usage: update-k8s-schemas.sh
# Needs: docker, git, curl. No sudo.
# LINT_CACHE replaces the folder of the Go module and build cache, shared with lint.sh
# (default: ~/.cache/devops-pipeline-e2e/lint).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSIONS="${REPO_ROOT}/tools/kubeconform/versions"
SCHEMAS="${REPO_ROOT}/tools/kubeconform/schemas"
CACHE="${LINT_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}/devops-pipeline-e2e/lint}"

case "$(uname -m)" in
  x86_64)  PLATFORM=linux/amd64 ;;
  aarch64) PLATFORM=linux/arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/chart" "${WORK}/crds" "${WORK}/py" "${WORK}/schemas" \
  "${CACHE}/mod" "${CACHE}/build" "${CACHE}/tmp"

# Prints the value of a KEY=value line of tools/kubeconform/versions; it must not be empty
value() {
  local v
  v="$(sed -n "s/^$1=//p" "${VERSIONS}")"
  if [[ -z "${v}" ]]; then
    echo "tools/kubeconform/versions: $1 is missing" >&2
    return 1
  fi
  echo "${v}"
}

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

# Fails if a version of tools/kubeconform/versions is not the one the cluster uses ($1: name,
# $2: version in versions, $3: version in the file $4)
same_version() {
  if [[ "$2" != "$3" ]]; then
    echo "$1: tools/kubeconform/versions has '$2', $4 has '$3'" >&2
    return 1
  fi
}

K8S_VERSION="$(value KUBERNETES_VERSION)"
K8S_COMMIT="$(value KUBERNETES_SCHEMAS_COMMIT)"
EG_VERSION="$(value ENVOY_GATEWAY_VERSION)"
EG_DIGEST="$(value ENVOY_GATEWAY_CRDS_CHART_DIGEST)"
CM_VERSION="$(value CERT_MANAGER_VERSION)"
CM_SHA256="$(value CERT_MANAGER_CRDS_SHA256)"
read -r -a CORE_SCHEMAS <<< "$(value CORE_SCHEMAS)"
CRD_KINDS="$(value CRD_KINDS)"

# The versions must be the ones the cluster uses
CLUSTER="${REPO_ROOT}/kind/cluster.yaml"
PLATFORM_SCRIPT="${REPO_ROOT}/scripts/install-platform.sh"
same_version Kubernetes "${K8S_VERSION}" \
  "$(sed -n 's/^ *image: kindest\/node:\(v[^@]*\)@.*/\1/p' "${CLUSTER}" | sort -u)" \
  kind/cluster.yaml
same_version "Envoy Gateway" "${EG_VERSION}" \
  "$(sed -n 's/^ENVOY_GATEWAY_VERSION="\(.*\)"$/\1/p' "${PLATFORM_SCRIPT}")" \
  scripts/install-platform.sh
same_version cert-manager "${CM_VERSION}" \
  "$(sed -n 's/^CERT_MANAGER_VERSION="\(.*\)"$/\1/p' "${PLATFORM_SCRIPT}")" \
  scripts/install-platform.sh

GOLANG_IMAGE="$(pinned_image golang)"
PYTHON_IMAGE="$(pinned_image python)"

# Options of every container: removed at the end, as the current user (not root), read-only file
# system with an empty /tmp in memory, no Linux capabilities, no privilege escalation
SANDBOX=(
  --rm --platform "${PLATFORM}"
  --user "$(id -u):$(id -g)"
  --read-only --tmpfs /tmp -e HOME=/tmp
  --cap-drop ALL --security-opt no-new-privileges
)

echo "==> Prepare (with network)"
echo "helm: tools/helm/go.mod, built with ${GOLANG_IMAGE}"
# The same Go settings as lint.sh: no other toolchain, modules only from the Go module proxy,
# go.mod and go.sum never changed
docker run "${SANDBOX[@]}" \
  -v "${REPO_ROOT}/tools/helm:/src:ro" -v "${CACHE}:/cache" -v "${WORK}/bin:/out" -w /src \
  -e GOMODCACHE=/cache/mod -e GOCACHE=/cache/build -e GOTMPDIR=/cache/tmp \
  -e GOTOOLCHAIN=local -e GOPROXY=https://proxy.golang.org -e GOFLAGS=-mod=readonly \
  -e CGO_ENABLED=0 \
  "${GOLANG_IMAGE}" go build -trimpath -o /out/ helm.sh/helm/v4/cmd/helm

echo "chart: envoyproxy/gateway-crds-helm:${EG_VERSION}@${EG_DIGEST}"
# helm checks that the chart it downloads has this digest
docker run "${SANDBOX[@]}" -v "${WORK}/bin:/tools:ro" -v "${WORK}/chart:/chart" \
  "${GOLANG_IMAGE}" /tools/helm pull \
  "oci://docker.io/envoyproxy/gateway-crds-helm:${EG_VERSION}@${EG_DIGEST}" \
  --untar --untardir /chart

echo "cert-manager CRDs: ${CM_VERSION}"
CM_RELEASES=https://github.com/cert-manager/cert-manager/releases/download
curl -sSfL -o "${WORK}/crds/cert-manager.yaml" "${CM_RELEASES}/${CM_VERSION}/cert-manager.crds.yaml"
if [[ "$(sha256sum "${WORK}/crds/cert-manager.yaml" | cut -d ' ' -f 1)" != "${CM_SHA256}" ]]; then
  echo "cert-manager.crds.yaml ${CM_VERSION}: the checksum is not CERT_MANAGER_CRDS_SHA256" >&2
  exit 1
fi

echo "core schemas: Kubernetes ${K8S_VERSION}, yannh/kubernetes-json-schema@${K8S_COMMIT}"
K8S_SCHEMAS="https://raw.githubusercontent.com/yannh/kubernetes-json-schema/${K8S_COMMIT}"
for name in "${CORE_SCHEMAS[@]}"; do
  curl -sSfL -o "${WORK}/schemas/${name}.json" \
    "${K8S_SCHEMAS}/${K8S_VERSION}-standalone-strict/${name}.json"
done

echo "PyYAML: tools/python/requirements.txt, with ${PYTHON_IMAGE}"
docker run "${SANDBOX[@]}" -v "${REPO_ROOT}/tools/python:/req:ro" -v "${WORK}/py:/out" \
  "${PYTHON_IMAGE}" pip install --quiet --disable-pip-version-check --no-cache-dir \
  --require-hashes --only-binary=:all: --no-deps --target /out -r /req/requirements.txt

echo "==> Generate (no network, read-only)"
# The same chart values as scripts/install-platform.sh
docker run "${SANDBOX[@]}" --network none -v "${WORK}/bin:/tools:ro" -v "${WORK}/chart:/chart:ro" \
  "${GOLANG_IMAGE}" /tools/helm template eg /chart/gateway-crds-helm \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true \
  > "${WORK}/crds/gateway-crds.yaml"

docker run "${SANDBOX[@]}" --network none -v "${WORK}/py:/py:ro" -e PYTHONPATH=/py \
  -v "${REPO_ROOT}/.github/scripts/crd-to-jsonschema.py:/convert.py:ro" \
  -v "${WORK}/crds:/crds:ro" -v "${WORK}/schemas:/out" \
  "${PYTHON_IMAGE}" python /convert.py /out "${CRD_KINDS}" \
  /crds/gateway-crds.yaml /crds/cert-manager.yaml

# Replace the schemas: a kind that is no longer used disappears
rm -rf "${SCHEMAS}"
mkdir -p "${SCHEMAS}"
cp "${WORK}/schemas/"*.json "${SCHEMAS}/"
echo "==> Schemas in tools/kubeconform/schemas (review with git diff, commit with the versions):"
git -C "${REPO_ROOT}" status --short --untracked-files=all -- tools/kubeconform
