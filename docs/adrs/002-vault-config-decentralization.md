# ADR-002: Vault Configuration Decentralization

**Status:** Accepted · **Date:** 2026-05-30

## Context

Vault initialization was handled by a single monolithic script (`platform/vault/scripts/init-vault.sh`) that mixed three distinct responsibilities:

1. **Bootstrap** — wait for pods, initialize, save unseal keys, unseal all pods
2. **Configuration** — enable engines, write policies, create auth roles, seed secrets
3. **Orchestration** — trigger ArgoCD syncs for dependent applications

Every time a new service (e.g., tailscale, monitoring, seaweedfs) was added, the script had to be edited to add:
- A new Vault policy
- An update to the shared `eso-role` to include the new policy
- Commands to seed the service's secrets

This created tight coupling between the Vault chart and every service that consumed secrets from it. Changes were imperative (bash), not declarative, and invisible in PR reviews beyond "lines changed in a script."

Additionally, all services shared a single `ClusterSecretStore` (`vault-backend`) that authenticated via a single Vault role (`eso-role`). This violated least-privilege: every service had access to every policy attached to that role, even policies for unrelated services.

## Options Considered

### Option A — Centralized YAML config file

Keep the monolithic init script but make it read a `vault-config.yaml` that declares policies, roles, and seeds declaratively. Adding a new service means editing the YAML.

**Pros:** Declarative, PR-friendly.  
**Cons:** Still a single point of change. The config file lives in the vault chart, coupling it to every service.

### Option B — Vault Secrets Operator (VSO)

Install the HashiCorp Vault Secrets Operator and use its CRDs (`VaultPolicy`, `VaultAuth`, etc.) to declare Vault configuration as Kubernetes resources.

**Pros:** Fully Kubernetes-native, ArgoCD manages everything.  
**Cons:** VSO does **not** have `VaultPolicy` or `VaultRole` CRDs — it only handles `VaultAuth`, `VaultStaticSecret`, `VaultDynamicSecret`. Policies and roles must still be managed externally. Additionally, adding another operator just for this is disproportionate.

### Option C — Terraform / OpenTofu

Manage Vault configuration (policies, roles, auth methods) via Terraform's `vault` provider.

**Pros:** Industry standard, declarative, stateful.  
**Cons:** Another tool in the stack, external state management, doesn't integrate with ArgoCD's GitOps model.

### Option D — Per-service PostSync Jobs + namespaced SecretStores (SELECTED)

**Bootstrap** stays as a lean script. **Configuration** moves to per-service ArgoCD `PostSync` Jobs that each own their own Vault policy, role, and secrets. The shared `ClusterSecretStore` is replaced by per-service namespaced `SecretStore` resources.

## Decision

**Option D: Decentralized per-service configuration via PostSync Jobs and namespaced SecretStores.**

### Architecture

```
platform/vault/scripts/
├── bootstrap-vault.sh          # Init + unseal only (no policies, no roles, no seeds)

platform/vault/templates/eso/
├── vault-config-rbac.yaml      # SA + Role for all PostSync Jobs
├── vault-config-tailscale.yaml     # PostSync Job: policy + role + seeds
├── vault-config-monitoring.yaml    # PostSync Job: policy + role + seeds

platform/tailscale/templates/
├── secret-store-tailscale.yaml  # SecretStore → role: eso-tailscale
├── secret-tailscale.yaml        # ExternalSecret (updated ref)

platform/monitoring/templates/
├── secret-store-monitoring.yaml # SecretStore → role: eso-monitoring
├── secret-monitor.yaml          # ExternalSecret (updated ref)
```

### PostSync Job Pattern

Each Job is a Kubernetes `Job` in the `vault` namespace with:
```yaml
annotations:
  argocd.argoproj.io/hook: PostSync
  argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

The Job:
1. Reads the Vault root token from the `*-unseal-keys` secret
2. Writes its policy via `vault policy write` (heredoc to `kubectl exec`)
3. Creates its Vault role via `vault write auth/kubernetes/role/eso-<service>`
4. Seeds its secrets (static or generated) via `vault kv put`

All operations are idempotent — policies are overwritten (same content), roles are overwritten, and secrets are skipped if they already exist.

### SecretStore Pattern

Each service chart defines its own namespaced `SecretStore` that references a dedicated Vault role:

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: vault-<service>
  namespace: <service-ns>
spec:
  provider:
    vault:
      server: {{ .Values.vaultAddress | default "https://vault.vault.svc:8200" }}
      auth:
        kubernetes:
          role: "eso-<service>"
          serviceAccountRef:
            name: vault-external-secrets
            namespace: external-secrets
```

The TCP connection to Vault originates from the ESO pod in `external-secrets` namespace (via `serviceAccountRef.namespace`), not from the service's namespace. This keeps the network surface area minimal.

## Rationale

1. **Least-privilege.** Each service has its own Vault role with only its own policy. No service can accidentally read another service's secrets.

2. **Ownership boundary.** Adding a new service means adding:
   - A PostSync Job in the vault chart (creates the policy + role in Vault)
   - A SecretStore in the service's own chart (references the role)
   - An ExternalSecret in the service's own chart (consumes the secret)

   Each change is isolated, visible in PRs, and doesn't modify shared infrastructure.

3. **GitOps-native.** PostSync Jobs are a standard ArgoCD pattern. The Job runs after Vault syncs successfully, ensuring Vault is ready before configuration is applied.

4. **No new operators.** The Jobs use `kubectl exec vault-0 -- vault ...` — the same pattern as the original script. No `vault` binary needed in the Job image.

5. **Idempotent by design.** All operations can be re-run safely.

## Consequences

- **Positive:** Clean separation of concerns, least-privilege roles, PR-visible changes, no more shared `ClusterSecretStore`, each service independently deployable.
- **Negative:** More Kubernetes resources (one Job + one SecretStore per service). The `vaultAddress` Helm value must be configured per-service chart (default: vault.vault.svc:8200, override for dev: vault-dev.vault.svc:8200).
- **Migration:** Two-phase rollout. Phase 1 deploys new SecretStores + Jobs alongside the existing ClusterSecretStore. Phase 2 migrates ExternalSecrets and removes the ClusterSecretStore. Zero downtime if ordered correctly.
- **NetworkPolicy:** Currently open to all namespaces (`namespaceSelector: {}`). A future change will restrict access to only `vault` and `external-secrets` namespaces.

## Updated Files

| Action | File |
|--------|------|
| Created | `platform/vault/scripts/bootstrap-vault.sh` |
| Created | `platform/vault/templates/eso/vault-config-rbac.yaml` |
| Created | `platform/vault/templates/eso/vault-config-tailscale.yaml` |
| Created | `platform/vault/templates/eso/vault-config-monitoring.yaml` |
| Created | `platform/tailscale/templates/secret-store-tailscale.yaml` |
| Created | `platform/monitoring/templates/secret-store-monitoring.yaml` |
| Updated | `platform/tailscale/templates/secret-tailscale.yaml` — store ref change |
| Updated | `platform/monitoring/templates/secret-monitor.yaml` — store ref change |
| Updated | `bootstrap/01-init-gitops.sh` — script reference, removed TS prompts |
| Deleted | `platform/vault/scripts/init-vault.sh` |
| Deleted | `platform/vault/templates/eso/vault-eso-backend.yaml` |
