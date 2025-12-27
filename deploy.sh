#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- CHECKS ---
if [ ! -f secrets.yaml ]; then
    echo "ERROR: secrets.yaml not found!"
    exit 1
fi

EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
DOMAIN=$(grep 'domain:' secrets.yaml | awk '{print $2}' | tr -d '"')

# --- K3S & HELM ---
# (Skipping checks if already installed for speed, but ensuring env vars)
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
else
    echo "K3s config not found. Is K3s installed?"
    exit 1
fi

# --- TRAEFIK CONFIGURATION ---
echo -e "${GREEN}>>> Applying Traefik Configuration...${NC}"

# 1. Update Secret
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Update HelmConfig
kubectl apply -f configs/traefik-config.yaml

echo -e "${GREEN}>>> Forcing Traefik Update...${NC}"

# 3. Force Rollout Restart (This is the most reliable way)
# We wait for the HelmJob to be done (just in case K3s is still processing)
kubectl wait --for=condition=complete --timeout=60s job/helm-install-traefik -n kube-system 2>/dev/null || true

# Find the deployment name (sometimes it's just 'traefik')
TRAEFIK_DEPLOY=$(kubectl get deploy -n kube-system -l app.kubernetes.io/name=traefik -o name | head -n 1)

if [ -z "$TRAEFIK_DEPLOY" ]; then
    echo "Waiting for Traefik deployment to appear..."
    sleep 10
    TRAEFIK_DEPLOY=$(kubectl get deploy -n kube-system -l app.kubernetes.io/name=traefik -o name | head -n 1)
fi

echo "Restarting $TRAEFIK_DEPLOY..."
kubectl rollout restart $TRAEFIK_DEPLOY -n kube-system

# 4. Wait for Readiness
echo "Waiting for Traefik restart to complete..."
kubectl rollout status $TRAEFIK_DEPLOY -n kube-system --timeout=180s

# Additional sleep to let ACME subsystem initialize inside the container
echo -e "${YELLOW}>>> Waiting 10s for ACME initialization...${NC}"
sleep 10

# --- DEPLOY APP ---
echo -e "\n${GREEN}>>> Deploying RemnaNode...${NC}"
# Uninstall old release to force fresh Ingress registration
helm uninstall remnanode -n remnanode 2>/dev/null || true
sleep 3

helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

# --- VERIFY ---
echo -e "\n${GREEN}>>> Deployment Done. Checking SSL...${NC}"
echo "Checking https://$DOMAIN"

# Quick check loop
for i in {1..10}; do
    ISSUER=$(curl -k -v --connect-timeout 5 "https://$DOMAIN" 2>&1 | grep "issuer:" | head -n 1)
    if [[ "$ISSUER" == *"Let's Encrypt"* ]]; then
        echo -e "${GREEN}SUCCESS: SSL is Let's Encrypt!${NC}"
        exit 0
    fi
    echo -n "."
    sleep 5
done

echo -e "\n${YELLOW}NOTE: SSL might take another minute to issue. Check logs if it stays 'Traefik Default'.${NC}"
echo "Command: kubectl logs -f -n kube-system -l app.kubernetes.io/name=traefik"