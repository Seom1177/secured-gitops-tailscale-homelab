# Sync Waves (Installation Order)

ArgoCD deploys components in a specific order. Components with lower numbers are deployed first. Resources within the same wave are created in parallel.

> **Why order matters**: Some components depend on others being ready. For example, you can't connect Tailscale to Vault if Vault hasn't been initialized yet.

## Current Order

| Step | Wave | Component | What it does |
|------|------|-----------|--------------|
| 1 | `-6` | `cert-manager` | Manages TLS certificates (HTTPS) for Vault and other services |
| 2 | `-5` | `vault` | Deploys HashiCorp Vault with TLS enabled |
| 3 | `-4` | `vault-unseal-job` | Automatically unseals Vault using keys generated during bootstrap |
| 4 | `-3` | `vault-config` | Configures Vault: auth methods, policies, roles |
| 5 | `-3` | `eso-operator` | Installs the External Secrets Operator and its CRDs |
| 6 | `-2` | `eso-config` | Creates ClusterSecretStore and ExternalSecrets (connects to Vault) |
| 7 | `-1` | `tailscale` | Deploys Tailscale operator and secure Ingresses |

## How It Works (Step-by-Step)

1. **cert-manager** (`-6`): Before Vault starts, we need certificates. cert-manager generates them and saves them into a Kubernetes Secret called `vault-tls`.

2. **Vault** (`-5`): Installs with TLS enabled. It reads the certificate from the secret and starts listening on HTTPS. It starts in a "sealed" state, which is normal for security.

3. **Vault Unseal** (`-4`): A one-time Kubernetes Job. it takes the unseal keys stored in the `vault-unseal-keys` secret (created by the bootstrap script) and unseals Vault so it can be used.

4. **Vault Config** (`-3`): Handles the internal configuration of Vault, like enabling Kubernetes authentication and setting up permissions. This is done during the bootstrap process or via a configurator job.

5. **ESO Operator** (`-3`): Installs the External Secrets Operator. This needs to happen before we try to create any custom resources like ClusterSecretStores.

6. **ESO Config** (`-2`): Creates the `ClusterSecretStore` (connecting to Vault) and `ExternalSecrets`. This is where the actual syncing of secrets starts.

7. **Tailscale** (`-1`): Installs the Tailscale operator using the credentials synced by ESO.
 It also creates the **Ingress** resources that allow you to access `https://vault` or `https://argocd` from your Tailscale network.

## Ingress Management

To avoid circular dependencies, all Tailscale-managed access is centralized in `platform/tailscale`. This ensures that secure access points are only created once the Tailscale operator is fully ready to handle them.

## Bootstrap Flow

The `01-init-gitops.sh` script is run **only once** when setting up the cluster for the first time. It performs the following:

```bash
# Initialize the cluster and ArgoCD
./bootstrap/01-init-gitops.sh
```

The script:
- Installs ArgoCD
- Installs cert-manager (so it's ready before Vault)
- Applies the Vault Application in ArgoCD
- Waits for the TLS certificate to be ready
- Initializes Vault and saves unseal keys as a Kubernetes Secret
- Unseals Vault
- Enables the secrets engine and seeds Tailscale credentials
- Applies the root Application (which manages everything else via GitOps)
