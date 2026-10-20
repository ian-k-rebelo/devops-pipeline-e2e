#!/usr/bin/env bash
# Build the application image and deploy the platform resources and the application to the local kind cluster.
# Prerequisites: the kind cluster exists and scripts/install-platform.sh has been run.
# Safe to run more than once: kubectl apply only changes what differs.
set -euo pipefail

# Names used below (the image tag must match the one set in k8s/overlays/local)
EXPECTED_CONTEXT="kind-devops-pipeline-e2e"
CLUSTER_NAME="devops-pipeline-e2e"
IMAGE="devops-pipeline-e2e:local"

# Safety check: refuse to run against any cluster other than the expected one
CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "Error: current kubectl context is '${CURRENT_CONTEXT}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

# Run from the repository root, wherever the script is called from
cd "$(dirname "$0")/.."

# 1) Application image: build it locally and copy it into every kind node (each node has its own image store)
echo "==> Application image: build ${IMAGE} and load it into the kind nodes"
docker build -t "${IMAGE}" app/
kind load docker-image "${IMAGE}" --name "${CLUSTER_NAME}"

# 2) Platform resources, then wait until the CA and the gateway certificate are issued
echo "==> Platform resources: gateway, internal CA and gateway certificate"
kubectl apply -k platform
kubectl wait --timeout=2m -n cert-manager certificate/internal-root-ca --for=condition=Ready
kubectl wait --timeout=2m clusterissuer/internal-ca --for=condition=Ready
kubectl wait --timeout=2m -n gateway certificate/app-devops-pipeline-e2e-internal --for=condition=Ready

# 3) Application (base + local overlay), then wait until its Pods are ready
echo "==> Application: local overlay"
kubectl apply -k k8s/overlays/local
kubectl rollout status --timeout=2m -n devops-pipeline-e2e deployment/devops-pipeline-e2e

# 4) Entry point ready: the gateway has its certificate and the application route
echo "==> Waiting for the gateway to be programmed"
kubectl wait --timeout=2m -n gateway gateway/public --for=condition=Programmed

# 5) Print how to test it (the commands are shown, not run; quoted 'EOF' keeps $VARS and $(...) as text)
echo "==> Deployed. To test it over HTTPS:"
cat <<'EOF'
  IP=$(kubectl get gateway public -n gateway -o jsonpath='{.status.addresses[0].value}')
  HOST=app.devops-pipeline-e2e.internal
  kubectl get secret internal-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/internal-root-ca.crt
  curl --resolve "$HOST:443:$IP" --cacert /tmp/internal-root-ca.crt "https://$HOST/"
EOF
