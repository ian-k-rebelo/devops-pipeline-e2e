#!/usr/bin/env bash
# Build the application image and deploy the platform resources and the application to the local kind cluster.
# Prerequisites: the kind cluster exists and scripts/install-platform.sh has been run.
# Safe to run more than once: kubectl apply only changes what differs.
# Each build gets a unique image tag (commit + image content), so a changed image always rolls out
# and an unchanged one does not.
set -euo pipefail

# Names used below (the image tag is computed for each build and replaces the "local" tag set in k8s/overlays/local)
EXPECTED_CONTEXT="kind-devops-pipeline-e2e"
CLUSTER_NAME="devops-pipeline-e2e"
IMAGE_NAME="devops-pipeline-e2e"

# Safety check: refuse to run against any cluster other than the expected one
CURRENT_CONTEXT="$(kubectl config current-context)"
if [[ "${CURRENT_CONTEXT}" != "${EXPECTED_CONTEXT}" ]]; then
  echo "Error: current kubectl context is '${CURRENT_CONTEXT}', expected '${EXPECTED_CONTEXT}'" >&2
  exit 1
fi

# Run from the repository root, wherever the script is called from
cd "$(dirname "$0")/.."

# 1) Application image: build it locally, tag it with the commit and the image content,
#    and copy it into every kind node (each node has its own image store)
#    --provenance=false: no build attestation (it records the build time), so the same content
#    always gets the same image ID; local images never leave this machine
echo "==> Application image: build it and tag it with the commit and the image content"
docker build --provenance=false -t "${IMAGE_NAME}:local" app/
COMMIT="$(git rev-parse --short=7 HEAD)"
# -dirty: the app/ folder has changes that are not committed, so the image matches no commit exactly
DIRTY=""
if [[ -n "$(git status --porcelain -- app/)" ]]; then
  DIRTY="-dirty"
fi
IMAGE_ID="$(docker image inspect --format '{{.Id}}' "${IMAGE_NAME}:local")"
TAG="local-${COMMIT}${DIRTY}-${IMAGE_ID:7:12}"
docker tag "${IMAGE_NAME}:local" "${IMAGE_NAME}:${TAG}"
echo "    image: ${IMAGE_NAME}:${TAG}"
kind load docker-image "${IMAGE_NAME}:${TAG}" --name "${CLUSTER_NAME}"

# 2) Platform resources, then wait until the CA and the gateway certificate are issued
echo "==> Platform resources: gateway, internal CA and gateway certificate"
kubectl apply -k platform
kubectl wait --timeout=2m -n cert-manager certificate/internal-root-ca --for=condition=Ready
kubectl wait --timeout=2m clusterissuer/internal-ca --for=condition=Ready
kubectl wait --timeout=2m -n gateway certificate/app-devops-pipeline-e2e-internal --for=condition=Ready

# 3) Application (base + local overlay, with this build's image tag), then wait until its Pods are ready
#    A temporary overlay outside the repository sets the tag, so nothing in Git changes
#    (unquoted EOF: ${TAG} and $(...) are replaced by their values)
echo "==> Application: local overlay, with this build's image tag"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
cat > "${WORK_DIR}/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - $(realpath --relative-to="${WORK_DIR}" k8s/overlays/local)
images:
  - name: ${IMAGE_NAME}
    newTag: ${TAG}
EOF
kubectl apply -k "${WORK_DIR}"
kubectl rollout status --timeout=2m -n devops-pipeline-e2e deployment/devops-pipeline-e2e

# 4) Entry point ready: the gateway has its certificate and the application route
echo "==> Waiting for the gateway to be programmed"
kubectl wait --timeout=2m -n gateway gateway/public --for=condition=Programmed

# 5) Cleanup: remove older images of the application, in the kind nodes and in the local Docker
echo "==> Cleanup: remove older local images of the application"
# In the kind nodes: application images that no container uses anymore
for node in $(kind get nodes --name "${CLUSTER_NAME}"); do
  docker exec "${node}" crictl images \
    | awk -v name="${IMAGE_NAME}" -v tag="${TAG}" '$1 ~ ("/" name "$") && $2 != tag { print $3 }' \
    | while read -r image_id; do
        docker exec "${node}" crictl rmi "${image_id}" >/dev/null 2>&1 || true
      done
done
# In the local Docker: older local-* tags (the image layers are kept while other tags use them)
docker image ls --format '{{.Repository}}:{{.Tag}}' "${IMAGE_NAME}" \
  | grep -E ":local-" | grep -v ":${TAG}$" \
  | xargs -r docker image rm >/dev/null || true

# 6) Print how to test it (the commands are shown, not run; quoted 'EOF' keeps $VARS and $(...) as text)
echo "==> Deployed ${IMAGE_NAME}:${TAG}. To test it over HTTPS:"
cat <<'EOF'
  IP=$(kubectl get gateway public -n gateway -o jsonpath='{.status.addresses[0].value}')
  HOST=app.devops-pipeline-e2e.internal
  kubectl get secret internal-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/internal-root-ca.crt
  curl --resolve "$HOST:443:$IP" --cacert /tmp/internal-root-ca.crt "https://$HOST/"
EOF
