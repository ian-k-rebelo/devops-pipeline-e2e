#!/usr/bin/env bash
# Install the cluster platform components: CRDs first, then controllers, with fixed versions.
# Safe to run more than once: installs what is missing and updates what already exists.
set -euo pipefail

# Versions (CRDs and controller must always match)
ENVOY_GATEWAY_VERSION="v1.9.2"
EXPECTED_CONTEXT="kind-devops-pipeline-e2e"

# Safety check: refuse to run against any cluster other than the expected one
CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "Error: current kubectl context is '${CURRENT_CONTEXT}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

# Run from the repository root, wherever the script is called from
cd "$(dirname "$0")/.."

echo "==> Envoy Gateway ${ENVOY_GATEWAY_VERSION}: CRDs (Gateway API standard channel + Envoy Gateway)"
helm template eg oci://docker.io/envoyproxy/gateway-crds-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -

echo "==> Envoy Gateway ${ENVOY_GATEWAY_VERSION}: controller"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system \
  --create-namespace \
  --values platform/envoy-gateway/values.yaml

kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available

echo "==> Platform installed"
