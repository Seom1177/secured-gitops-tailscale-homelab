#!/bin/bash
set -e

# --- ArgoCD Version ---
ARGOCD_VERSION=9.5.13

# Init infra (storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# --- STEP 1: Install ArgoCD (standalone, with custom config) ---
echo "Adding ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "Installing ArgoCD"
helm upgrade --install argocd argo/argo-cd \
  --version $ARGOCD_VERSION \
  --namespace argocd --create-namespace \
  --timeout 30m \
  -f bootstrap/values-argocd.yaml

echo "Waiting for ArgoCD CRDs..."
until kubectl get crd applications.argoproj.io > /dev/null 2>&1; do sleep 2; done

echo "Waiting for ArgoCD server to be ready..."
kubectl rollout status deployment/argocd-server -n argocd --timeout=10m

# --- STEP 2: Install App-of-Apps (platform applications) ---
echo "Installing GitOps App-of-Apps"
helm upgrade --install gitops gitops \
  --namespace argocd \
  --timeout 30m \
  -f gitops/values.yaml

# --- STEP 3: Vault configuration ---
chmod +x platform/vault/scripts/init-vault.sh
./platform/vault/scripts/init-vault.sh

# Final Info
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d 2>/dev/null || echo "N/A")
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "---------------------------------------------------"
echo "Bootstrap Complete!"
echo "ArgoCD URL: http://localhost:8080 (kubectl port-forward svc/argocd-server -n argocd -p 8080:443)"
echo "ArgoCD User: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"
echo "Warning: Change your secrets in the secrets folder, read doc/secrets-structure.md for info"
echo "Vault UI: http://localhost:8200 (kubectl port-forward svc/vault-app -n vault -p 8200:8200)"
echo "Vault Root Token: $ROOT_TOKEN"
echo "---------------------------------------------------"
