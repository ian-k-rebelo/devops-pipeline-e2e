# devops-pipeline-e2e
End-to-end DevOps pipeline: a minimal web application delivered with Git, Docker, Kubernetes, Terraform and GitHub Actions.
> Work in progress. Author: Ian Rebelo


## Run locally (kind)

Runs the whole stack on a local Kubernetes cluster ([kind](https://kind.sigs.k8s.io/)):
the Flask application behind an Envoy Gateway, over HTTPS only, with a certificate issued by an internal CA (cert-manager).

### Prerequisites

| Tool | Tested version |
|---|---|
| Docker | 29.9.0 |
| kind | v0.33.0 |
| kubectl | v1.37.1 (includes Kustomize v5.8.1) |
| Kubernetes (kind node image) | v1.37.0 |
| Helm | v4.3.1 |
| [cloud-provider-kind](https://github.com/kubernetes-sigs/cloud-provider-kind) | v0.12.0 |

No `sudo` is needed: your user only needs to be able to run Docker.

`cloud-provider-kind` gives the Gateway an external IP. Keep it running in a separate terminal:

```bash
cloud-provider-kind --gateway-channel disabled --enable-default-ingress=false --enable-lb-tunnel=false
```

### 1. Create the cluster

```bash
kind create cluster --config kind/cluster.yaml
```

Creates the `devops-pipeline-e2e` cluster (1 control-plane and the worker nodes defined in `kind/cluster.yaml`) and switches kubectl to the `kind-devops-pipeline-e2e` context.

### 2. Install the platform

```bash
./scripts/install-platform.sh
```

Installs, with pinned versions, the CRDs and the controllers of Envoy Gateway and cert-manager (Helm).
Safe to run more than once. Refuses to run against any context other than `kind-devops-pipeline-e2e`.

### 3. Deploy

```bash
./scripts/deploy-local.sh
```

Builds the application image, loads it into the kind nodes, applies the platform resources (`platform/`: Gateway, internal CA, gateway certificate) and the application (`k8s/overlays/local`), and waits until everything is ready.

### Test it

```bash
IP=$(kubectl get gateway public -n gateway -o jsonpath='{.status.addresses[0].value}')
HOST=app.devops-pipeline-e2e.internal
kubectl get secret internal-root-ca -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/internal-root-ca.crt
curl --resolve "$HOST:443:$IP" --cacert /tmp/internal-root-ca.crt "https://$HOST/"
```

- `--resolve` sends the request to the Gateway's IP without editing `/etc/hosts`.
- `--cacert` trusts the internal root CA, so the certificate is verified (no `-k`/`--insecure`).
- Only HTTPS (port 443) is exposed; plain HTTP is not served.

### Notes and troubleshooting

- **Code changes do not show up:** the image tag is always `local`, so the Pods are not replaced when you rebuild. After `./scripts/deploy-local.sh`, run
  `kubectl rollout restart deployment/devops-pipeline-e2e -n devops-pipeline-e2e`.
  (Unique image tags will replace this in the CI/CD stage.)
- **The Gateway has no IP / `curl: (7)`:** `cloud-provider-kind` is not running.
- **`curl: (60)` certificate error after recreating the cluster:** each new cluster has a new root CA. Run the `kubectl get secret … > /tmp/internal-root-ca.crt` command again.
- **The scripts refuse to run:** kubectl is pointing to another cluster. Check with `kubectl config current-context`.

### Clean up

```bash
kind delete cluster --name devops-pipeline-e2e
```

Deletes the cluster and everything in it. Then stop `cloud-provider-kind` (Ctrl+C).
