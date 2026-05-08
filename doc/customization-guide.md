# Customization & Fork Guide

This guide will walk you through the steps required to personalize this homelab after forking the repository. Since GitOps relies on declarative state, you need to update several references to point to your own infrastructure and repository.

## 1. Update Repository References

ArgoCD needs to know where its source of truth is. By default, it points to the original repository.

### Update ArgoCD Applications (App-of-Apps)

This project follows the **App-of-Apps** pattern. The main entry point is `gitops/root-prod-app.yaml`, which bootstraps the entire cluster. 

Because many applications in `gitops/prod/` point to Helm charts located within this same repository (local charts), you **must** update the `repoURL` in all manifest files to point to your fork.

1.  **Entry Point**: Update the `repoURL` in `gitops/root-prod-app.yaml`.
2.  **App Definitions**: Update all files under `gitops/prod/` (e.g., `vault-app.yaml`, `eso-app.yaml`, etc.).

You can use this command to update all references at once:
```bash
# Replace 'Seom1177' with your GitHub username
grep -ril "Seom1177/argocd-gitops-homelab" gitops/ | xargs sed -i 's|Seom1177/argocd-gitops-homelab|YOUR_USERNAME/argocd-gitops-homelab|g'
```

## 2. Tailscale Configuration

To use your own Tailscale network, follow these steps:

1.  **Update K3s Config**: When following the [K3s Install Guide](k3s-install.md), ensure you use your specific Tailscale IP and hostnames. This is the foundation of your node identity.
2.  **Generate an Auth Key**: Go to your Tailscale Admin Console and generate a reusable Auth Key. For more advanced setups, refer to the [official Tailscale Kubernetes Operator documentation](https://tailscale.com/docs/features/kubernetes-operator).
3.  **Tailscale Operator**: If you use the Tailscale Operator, you will need to provision secrets. Follow the [Secrets Structure tutorial](secrets-structure.md) to manage these via Vault.

## 3. Vault & Secrets Management

This lab relies heavily on HashiCorp Vault for secure secret delivery. To customize it:

1.  **Initialize Vault**: Follow the steps in the [Getting Started](../doc/getting-started.md) guide.
2.  **Secrets Structure**: It is **crucial** to follow the [Secrets Structure guide](secrets-structure.md) to understand how to seed your own credentials (Tailscale, Cloudflare, etc.) into Vault.
3.  **External Secrets Operator (ESO)**: Update the `ClusterSecretStore` in `platform/external-secrets/` to point to your Vault instance's address.


## 4. Personal Branding

Feel free to update the `README.md` footer and any other metadata to reflect your own journey!

---
*Good luck with your DevSecOps journey! If you find this useful, consider giving the original repo a star.*
