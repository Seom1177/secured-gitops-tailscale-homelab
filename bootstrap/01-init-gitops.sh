#!/bin/bash

# Init infra (storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# Install ArgoCD Base first (to get CRDs)
echo "Installing ArgoCD Base (Timeout: 30m)..."
helm dependency build gitops
helm upgrade --install argocd gitops \
  --namespace argocd --create-namespace \
  --set platformApps.enabled=false \
  --timeout 30m \
  -f gitops/values.yaml

echo "Waiting for ArgoCD CRDs..."
until kubectl get crd applications.argoproj.io > /dev/null 2>&1; do sleep 2; done

# Install full GitOps (including Apps)
echo "Installing ArgoCD Apps (Timeout: 30m)..."
helm upgrade --install argocd gitops \
  --namespace argocd \
  --timeout 30m \
  -f gitops/values.yaml

# --- VAULT CONFIGURATION ---
chmod +x platform/vault/scripts/init-vault.sh
./platform/vault/scripts/init-vault.sh

# Final Info
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d)
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "---------------------------------------------------"
echo "Bootstrap Complete!"
echo "ArgoCD URL: http://localhost:8080 (port-forward needed)"
echo "ArgoCD User: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"
echo "Vault Root Token: $ROOT_TOKEN"
echo "---------------------------------------------------"


