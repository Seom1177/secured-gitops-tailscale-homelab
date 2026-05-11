#!/bin/bash

# Init infra (storage class)
chmod +x infra/init-infra.sh
./infra/init-infra.sh

# Install ArgoCD
echo "Installing ArgoCD Base..."
helm dependency build gitops
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --set argo-cd.enabled=true \
  -f gitops/values.yaml

echo "Waiting for ArgoCD CRDs..."
until kubectl get crd applications.argoproj.io > /dev/null 2>&1; do sleep 2; done

echo "Installing ArgoCD Apps..."
helm upgrade --install argocd-app gitops \
  --namespace argocd \
  -f gitops/values.yaml

# Wait for Vault Setup Job
echo "Waiting for Vault setup Job to complete..."
kubectl wait --for=condition=complete job/vault-setup -n vault --timeout=300s

# Seed secrets for Tailscale auth (Interactive)
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d)

if [ -z "$TS_CLIENT_ID" ] || [ -z "$TS_CLIENT_SECRET" ]; then
    read -p "Type Tailscale Client ID: " TS_CLIENT_ID
    read -sp "Type Tailscale Client Secret (your input will not be shown): " TS_CLIENT_SECRET
    echo ""
fi

echo "Seeding Tailscale secrets into Vault..."
kubectl exec -n vault vault-app-0 -- /bin/sh \
    -c "export VAULT_TOKEN=$ROOT_TOKEN; vault kv put \
        -address=https://127.0.0.1:8200 \
        -ca-cert=/vault/userconfig/vault-tls/ca.crt \
        -tls-server-name=vault \
        secret/tailscale/auth \
        client_id=$TS_CLIENT_ID \
        client_secret=$TS_CLIENT_SECRET"

# Final Info
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
echo "---------------------------------------------------"
echo "Bootstrap Complete!"
echo "ArgoCD URL: http://localhost:8080 (port-forward needed)"
echo "ArgoCD User: admin"
echo "ArgoCD Password: $ARGOCD_PASSWORD"
echo "Vault Root Token: $ROOT_TOKEN"
echo "---------------------------------------------------"

