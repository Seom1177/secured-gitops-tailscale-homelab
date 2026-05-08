# K3s Installation

This guide describes the process of installing K3s on Fedora Linux, optimized for Tailscale networking and with secrets encryption enabled at rest.

## Prerequisites

- Fedora Linux (Tested on versions 44).
- Tailscale installed and authenticated on the node.
- Root access.

## 1. System Preparation

Fedora requires specific configurations for Firewalld, SELinux, and networking to ensure K3s operates correctly.

### Network Optimizations

Enable IP forwarding to allow Tailscale to properly route traffic between the K3s pods and nodes.

```bash
sudo tee /etc/sysctl.d/99-tailscale.conf > /dev/null <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

> [!IMPORTANT]
> This is required if the node will act as a subnet router or if you expect pod-to-pod communication across different Tailscale nodes.

### Configure Firewalld


K3s requires several ports to be open. For Tailscale environments, it is recommended to trust the Tailscale interface or explicitly allow the Pod and Service CIDRs to ensure inter-node communication.

```bash
# Option A: Trust the Tailscale interface (Simplest for Homelabs)
sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0

# Option B: Selective CIDR Trust (More Secure)
# Allow traffic from the K3s Pod and Service networks
sudo firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
sudo firewall-cmd --permanent --zone=trusted --add-source=10.43.0.0/16

# Open essential K3s ports
sudo firewall-cmd --permanent --add-port=6443/tcp   # API Server
sudo firewall-cmd --permanent --add-port=10250/tcp  # Kubelet Metrics

sudo firewall-cmd --reload
```

### Swap Management

Unlike standard Kubernetes, K3s supports running with swap enabled. This is particularly useful on Fedora, which uses `zram` by default.

#### Option A: Keep Swap Enabled (Recommended for small nodes)
Fedora 44 uses `zram` by default, and k3s supports running with swap enabled. So, we can keep swap enabled.

#### Option B: Disable Swap (Standard practice)
If you prefer predictable resource management, disable swap entirely:
```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
```

## 2. K3s Configuration

To ensure K3s uses Tailscale for internal communication and enables encryption, create the configuration directory and file.

### Create Configuration

Replace `<TAILSCALE_IP>` with the actual Tailscale IP of the node and `<TAILSCALE_HOSTNAME>` with its Tailscale DNS name.

```bash
sudo mkdir -p /etc/rancher/k3s

sudo tee /etc/rancher/k3s/config.yaml > /dev/null <<EOF
# Tailscale Networking (Required for mesh connectivity)
node-ip: "<TAILSCALE_IP>"             # Local identity on the Tailnet
node-external-ip: "<TAILSCALE_IP>"    # Reported external IP
advertise-address: "<TAILSCALE_IP>"   # Address used by other nodes to join
flannel-iface: "tailscale0"           # Force pod traffic through Tailscale tunnel


# Security and OS
selinux: true
secrets-encryption: true

# Access and Identity
tls-san:
  - "<TAILSCALE_IP>"             # Valid for connections via IP
  - "<TAILSCALE_HOSTNAME>"       # Valid for local tailnet name
  - "<TAILSCALE_FQDN>"           # Valid for full Tailscale DNS name


# Cluster Initialization (Embedded etcd)
cluster-init: true
token: "generate-a-secure-token-here"
EOF


```

## 3. Installation

Run the K3s installer. It will automatically detect the configuration file created in the previous step.

```bash
curl -sfL https://get.k3s.io | sudo sh -
```

## 4. Secrets Encryption Verification

K3s uses AES-CBC encryption for secrets at rest when the `secrets-encryption: true` flag is set.

### Check Encryption Status

To verify that encryption is active and see the current rotation stage:

```bash
sudo k3s secrets-encrypt status
```

### Rotating Keys

If a key rotation is required in the future:

1. **Rotate keys**: `sudo k3s secrets-encrypt rotate-keys`
2. **Monitor progress**: Wait until the status shows `reencrypt_finished`.
3. **Restart K3s**: `sudo systemctl restart k3s`

## 5. Post-Installation

### Configure Kubectl Access

Set up `kubectl` access for the current user and ensure the configuration persists across sessions.

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config
chmod 600 ~/.kube/config
```

#### Persist KUBECONFIG Variable

Add the export command to the shell configuration file to make it permanent.

**For Bash:**
```bash
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

**For Zsh:**
```bash
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.zshrc
source ~/.zshrc
```

**For Fish:**
```fish
set -Ux KUBECONFIG $HOME/.kube/config
```

### Verify Installation

Verify the cluster status:

```bash
kubectl get nodes -o wide
```

