#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

# Check for secrets file
if [ ! -f secrets.yaml ]; then
    echo "ERROR: secrets.yaml not found!"
    echo "Please copy secrets.example.yaml to secrets.yaml and fill in your data."
    exit 1
fi

# 1. Install K3s (if not exists)
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Installing K3s (Custom Ports)...${NC}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--kube-apiserver-arg service-node-port-range=1-65535" sh -
    echo "Waiting for K3s readiness..."
    sleep 20
else
    echo -e "${GREEN}>>> K3s is already installed.${NC}"
fi

# Configure access (Persistent)
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    # 1. Export for current session
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 /etc/rancher/k3s/k3s.yaml

    # 2. Configure for Root (Current execution context)
    mkdir -p ~/.kube
    cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    chmod 600 ~/.kube/config

    # 3. Configure for SUDO_USER (The user who ran sudo)
    if [ -n "$SUDO_USER" ]; then
        USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
        if [ -d "$USER_HOME" ]; then
            mkdir -p "$USER_HOME/.kube"
            cp /etc/rancher/k3s/k3s.yaml "$USER_HOME/.kube/config"
            
            USER_GROUP=$(id -gn "$SUDO_USER")
            chown -R "$SUDO_USER:$USER_GROUP" "$USER_HOME/.kube"
            chmod 600 "$USER_HOME/.kube/config"
            echo ">>> Configured kubectl/helm access for user: $SUDO_USER"
        fi
    fi
else
    echo "ERROR: K3s config not found!"
    exit 1
fi

# 2. Install Helm
if ! command -v helm &> /dev/null; then
    echo -e "${GREEN}>>> Installing Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 3. Traefik Check
echo -e "${GREEN}>>> Waiting for Traefik initialization...${NC}"
TIMEOUT=0
while ! kubectl get crd ingressroutes.traefik.io &> /dev/null; do
    echo "Waiting for Traefik CRDs... (${TIMEOUT}s)"
    sleep 5
    TIMEOUT=$((TIMEOUT+5))
    if [ $TIMEOUT -ge 120 ]; then
        echo "ERROR: Traefik failed to start within 120s."
        exit 1
    fi
done
echo -e "${GREEN}>>> Traefik is ready.${NC}"

# 4. Configure SSL Email
EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f configs/traefik-config.yaml

# 5. Deploy Application
echo -e "${GREEN}>>> Deploying RemnaNode...${NC}"
helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

echo -e "${GREEN}>>> Deployment successful! Pod status:${NC}"
kubectl get pods -n remnanode