#!/bin/bash
set -e

echo "Vault: Starting configuration..."

# 1. Wait for Vault pod
echo "Waiting for Vault pod vault-app-0..."
until kubectl get pod -n vault vault-app-0 > /dev/null 2>&1; do sleep 5; done
kubectl wait --for=condition=Ready pod/vault-app-0 -n vault --timeout=300s

# Helpers for vault exec
VAULT_EXEC="kubectl exec -i -n vault vault-app-0 -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt vault"

# 2. Initialization
STATUS=$($VAULT_EXEC status -format=json -tls-server-name=vault 2>/dev/null || echo "{\"initialized\":false}")
if echo "$STATUS" | jq -r '.initialized' | grep -q "false"; then
    echo "Initializing Vault..."
    INIT_OUT=$($VAULT_EXEC operator init -format=json -tls-server-name=vault)
    
    ROOT_TOKEN=$(echo "$INIT_OUT" | jq -r '.root_token')
    KEY1=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[0]')
    KEY2=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[1]')
    KEY3=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[2]')
    KEY4=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[3]')
    KEY5=$(echo "$INIT_OUT" | jq -r '.unseal_keys_b64[4]')

    kubectl create secret generic vault-unseal-keys -n vault \
      --from-literal=root-token="$ROOT_TOKEN" \
      --from-literal=key1="$KEY1" \
      --from-literal=key2="$KEY2" \
      --from-literal=key3="$KEY3" \
      --from-literal=key4="$KEY4" \
      --from-literal=key5="$KEY5" \
      --dry-run=client -o yaml | kubectl apply -f -
    
    echo "Vault initialized and keys saved to secret/vault-unseal-keys"
fi

# 3. Unseal
if $VAULT_EXEC status -format=json -tls-server-name=vault | jq -r '.sealed' | grep -q "true"; then
    echo "Vault is sealed. Unsealing..."
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.key1}' | base64 -d)
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.key2}' | base64 -d)
    $VAULT_EXEC operator unseal -tls-server-name=vault $(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.key3}' | base64 -d)
fi

# 4. Configure Vault
ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d)
VAULT_EXEC_AUTH="kubectl exec -i -n vault vault-app-0 -- env VAULT_CACERT=/vault/userconfig/vault-tls/ca.crt VAULT_TOKEN=$ROOT_TOKEN vault"

echo "Ensuring KV-v2 engine is enabled at secret/..."
$VAULT_EXEC_AUTH secrets list -tls-server-name=vault | grep -q "secret/" || \
  $VAULT_EXEC_AUTH secrets enable -path=secret -tls-server-name=vault kv-v2

echo "Ensuring Kubernetes auth is enabled..."
$VAULT_EXEC_AUTH auth list -tls-server-name=vault | grep -q "kubernetes/" || \
  $VAULT_EXEC_AUTH auth enable -tls-server-name=vault kubernetes

echo "Configuring Kubernetes auth..."
K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
K8S_CA=$(kubectl exec -n vault vault-app-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

$VAULT_EXEC_AUTH write -tls-server-name=vault auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$K8S_CA" \
    issuer="$K8S_ISSUER"

echo "Updating policies..."
$VAULT_EXEC_AUTH policy write -tls-server-name=vault tailscale-policy - <<EOF
path "secret/data/tailscale/*" {
  capabilities = ["read"]
}
EOF

echo "Updating ESO role..."
$VAULT_EXEC_AUTH write -tls-server-name=vault auth/kubernetes/role/eso-tailscale-role \
    bound_service_account_names=eso-app-external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=tailscale-policy \
    ttl=24h

# 5. Seed secrets for Tailscale auth (Interactive)
if [ -z "$TS_CLIENT_ID" ] || [ -z "$TS_CLIENT_SECRET" ]; then
    read -p "Type Tailscale Client ID: " TS_CLIENT_ID
    read -sp "Type Tailscale Client Secret (your input will not be shown): " TS_CLIENT_SECRET
    echo ""
fi

echo "Seeding Tailscale secrets into Vault..."
$VAULT_EXEC_AUTH kv put -tls-server-name=vault \
    secret/tailscale/auth \
    client_id="$TS_CLIENT_ID" \
    client_secret="$TS_CLIENT_SECRET"

echo "Vault: Configuration complete."
