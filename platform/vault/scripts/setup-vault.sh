#!/bin/sh
# platform/vault/scripts/setup-vault.sh

set -e

# Helpers
seed_secret() {
    local path=$1
    local data=$2
    echo "Checking $path..."
    # kv get send error if secret does not exist
    if vault kv get -tls-server-name=$TLS_SERVER_NAME "$path" > /dev/null 2>&1; then
        echo "  -> $path already exists. Skipping."
    else
        echo "  -> Seeding placeholder data for $path..."
        vault kv put -tls-server-name=$TLS_SERVER_NAME "$path" $data
    fi
}

# 1. Wait for Vault API to respond
echo "Waiting for Vault API at $VAULT_ADDR..."
until vault status -tls-server-name=$TLS_SERVER_NAME > /dev/null 2>&1 || [ $? -eq 2 ]; do
  echo "Still waiting for Vault..."
  sleep 5
done

# 2. Initialization (if not initialized)
STATUS=$(vault status -format=json -tls-server-name=$TLS_SERVER_NAME)
if [ "$(echo $STATUS | jq -r '.initialized')" = "false" ]; then
    echo "Initializing Vault..."
    INIT_OUT=$(vault operator init -format=json -tls-server-name=$TLS_SERVER_NAME)
    
    # Extract keys and root token
    ROOT_TOKEN=$(echo $INIT_OUT | jq -r '.root_token')
    KEY1=$(echo $INIT_OUT | jq -r '.unseal_keys_b64[0]')
    KEY2=$(echo $INIT_OUT | jq -r '.unseal_keys_b64[1]')
    KEY3=$(echo $INIT_OUT | jq -r '.unseal_keys_b64[2]')
    KEY4=$(echo $INIT_OUT | jq -r '.unseal_keys_b64[3]')
    KEY5=$(echo $INIT_OUT | jq -r '.unseal_keys_b64[4]')

    # Create the secret in Kubernetes for the sidecar/hook to use
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

# 3. Unseal (if sealed)
if vault status -format=json -tls-server-name=$TLS_SERVER_NAME | jq -r '.sealed' | grep -q "true"; then
    echo "Vault is sealed. Unsealing..."
    vault operator unseal -tls-server-name=$TLS_SERVER_NAME $(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.key1}' | base64 -d)
    vault operator unseal -tls-server-name=$TLS_SERVER_NAME $(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.key2}' | base64 -d)
    vault operator unseal -tls-server-name=$TLS_SERVER_NAME $(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.key3}' | base64 -d)
fi
# echo "Fetching root token for configuration..."
# export VAULT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d)

# 4. Internal configuration
# Enable secret engines
echo "Ensuring KV-v2 engine is enabled at secret/..."
vault secrets list -tls-server-name=$TLS_SERVER_NAME | grep -q "secret/" || \
  vault secrets enable -path=secret -tls-server-name=$TLS_SERVER_NAME kv-v2

# Seeding placeholders to avoid External Secrets failures
seed_secret "secret/tailscale/auth" "client_id=ChangeMe client_secret=ChangeMe"

# Kubernetes auth
echo "Ensuring Kubernetes auth is enabled..."
vault auth list -tls-server-name=$TLS_SERVER_NAME | grep -q "kubernetes/" || \
  vault auth enable -tls-server-name=$TLS_SERVER_NAME kubernetes

echo "Configuring Kubernetes auth..."
K8S_ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
K8S_CA=$(cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

vault write -tls-server-name=$TLS_SERVER_NAME auth/kubernetes/config \
    kubernetes_host="https://kubernetes.default.svc" \
    kubernetes_ca_cert="$K8S_CA" \
    issuer="$K8S_ISSUER"

# Policies
echo "Updating policies..."
vault policy write -tls-server-name=$TLS_SERVER_NAME tailscale-policy - <<EOF
path "secret/data/tailscale/*" {
  capabilities = ["read"]
}
EOF

# ESO roles
echo "Updating ESO role..."
vault write -tls-server-name=$TLS_SERVER_NAME auth/kubernetes/role/eso-tailscale-role \
    bound_service_account_names=eso-app-external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=tailscale-policy \
    ttl=24h

echo "Vault Setup Job finished successfully."
