# Remnanode K3s Stack

High-performance, configuration-driven Xray node deployment on Kubernetes (K3s).
Designed for Remnawave Controller

## Features

* **Configuration Driven:** All settings are managed via a single `secrets.yaml` file
* **Multi-Protocol Support:**
  * **Reality/Trojan:** TCP Passthrough via Traefik (SNI routing)
  * **WebSocket:** Secure Path routing with automatic SSL
  * **XHTTP:** Native support without WS header interference
  * **gRPC:** Full HTTP/2 (h2c) support
  * **Shadowsocks:** Direct HostPort access (TCP + UDP) for maximum performance
* **Automatic SSL:** Traefik + Let's Encrypt (TLS 1.3)
* **Auto-Updates:** Daily automatic restart and database updates

## Prerequisites

* A fresh Linux server (Debian/Ubuntu recommended)
* Domain name pointed to the server's IP
* Root access

## Quick Start

1. **Clone the repository:**

    ```bash
    git clone https://github.com/Th3roo/remnanode_k3s.git
    cd remnanode_k3s
    ```

2. **Configure secrets:**

    ```bash
    cp secrets.example.yaml secrets.yaml
    nano secrets.yaml
    ```

    *Fill in your Email, Domain, Secret Key, and define your Inbounds*

3. **Deploy:**

    ```bash
    chmod +x deploy.sh
    sudo ./deploy.sh
    ```

## Configuration Reference (`secrets.yaml`)

Define your inbounds in the `inbounds` list. The deployment script will automatically generate Ingress rules, Services, and open ports based on the `mode`

| Mode | Description | Use Case |
| :--- | :--- | :--- |
| `ingress-sni` | TCP Passthrough (Layer 4). Routing based on SNI. | VLESS Reality, Trojan Reality |
| `ingress-path` | HTTP/WS Routing (Layer 7). Adds WS headers. | VLESS WebSocket, VMess WS |
| `ingress-xhttp` | HTTP Routing (Layer 7). No extra headers. | Trojan XHTTP, VLESS XHTTP |
| `ingress-grpc` | HTTP/2 h2c Routing. Matches ServiceName. | VLESS gRPC, Trojan gRPC |
| `direct` | Direct HostPort mapping. Opens TCP & UDP. | Shadowsocks, Fallbacks |

### Important Panel Settings (Remnawave)

When configuring Inbounds in the Remnawave Panel:

1. **Listen IP:** Always set to `0.0.0.0`
2. **Security:** Set to `none` (Traefik handles TLS termination). And set TLS in remnaware panel
3. **Sniffing:**
    * **Reality/Shadowsocks:** Can be Enabled
    * **gRPC/XHTTP:** **MUST be Disabled**
4. **Host:**
    * **WS/XHTTP:** Set to your domain (e.g., `example.com`) to match Traefik headers

## Troubleshooting

**Check Pod Status:**

```bash
kubectl get pods -n remnanode
```

**Check Xray Logs:**

```bash
kubectl logs -f -n remnanode -l app=remnanode -c remnanode
```

**Check Traefik Logs:**

```bash
kubectl logs -f -n kube-system -l app.kubernetes.io/name=traefik
```

**Full Reset (Uninstall):**

```bash
helm uninstall remnanode -n remnanode
kubectl delete ns remnanode
```
