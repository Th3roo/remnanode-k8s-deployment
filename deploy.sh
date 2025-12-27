#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- 0. PRE-FLIGHT CHECKS ---
if [ ! -f secrets.yaml ]; then
    echo -e "${RED}ERROR: secrets.yaml not found!${NC}"
    exit 1
fi

EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
DOMAIN=$(grep 'domain:' secrets.yaml | awk '{print $2}' | tr -d '"')

if [ -z "$EMAIL" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}ERROR: Email or Domain missing in secrets.yaml${NC}"
    exit 1
fi

# --- 1. INSTALL K3S ---
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Installing K3s...${NC}"
    # Install with increased timeout for slow startups
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--kube-apiserver-arg service-node-port-range=1-65535 --write-kubeconfig-mode 644" sh -
    echo "Waiting for K3s node readiness..."
    sleep 15
else
    echo -e "${GREEN}>>> K3s already installed.${NC}"
fi

# Export Config
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config 2>/dev/null || true

# --- 2. INSTALL HELM ---
if ! command -v helm &> /dev/null; then
    echo -e "${GREEN}>>> Installing Helm...${NC}"
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- 3. CONFIGURE TRAEFIK (THE FIX) ---
echo -e "\n${GREEN}>>> Configuring Traefik SSL (ACME)...${NC}"

# 3.1 Create Secret (Email)
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

# 3.2 Apply HelmChartConfig (Traefik Args)
kubectl apply -f configs/traefik-config.yaml

# 3.3 INTELLIGENT WAIT LOOP
echo -e "${GREEN}>>> Verifying Traefik Configuration...${NC}"
echo "We will now wait until Traefik is ACTUALLY running with the Let's Encrypt email."
echo "If it's not detected, we will restart the pod automatically."

MAX_ATTEMPTS=20
ATTEMPT=0
SUCCESS=0

while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    # Get the name of the CURRENT running pod (exclude Terminating ones)
    POD_NAME=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik --field-selector=status.phase=Running -o name | head -n 1)

    if [ -z "$POD_NAME" ]; then
        echo -ne "${YELLOW}.Wait for pod.${NC}"
        sleep 5
        ATTEMPT=$((ATTEMPT+1))
        continue
    fi

    # Check the arguments inside the pod
    ARGS=$(kubectl get $POD_NAME -n kube-system -o jsonpath='{.spec.containers[0].args}' 2>/dev/null)

    if [[ "$ARGS" == *"--certificatesresolvers.le.acme.email=$EMAIL"* ]]; then
        echo -e "\n${GREEN}>>> SUCCESS: Traefik is running with SSL Email enabled!${NC}"
        SUCCESS=1
        
        # Double check readiness
        kubectl wait --for=condition=ready $POD_NAME -n kube-system --timeout=60s
        break
    else
        echo -e "\n${YELLOW}>>> Detected Traefik without SSL config. Deleting pod to force reload...${NC}"
        kubectl delete $POD_NAME -n kube-system --wait=false
        echo "Waiting for new pod..."
        sleep 10
    fi
    
    ATTEMPT=$((ATTEMPT+1))
done

if [ $SUCCESS -eq 0 ]; then
    echo -e "\n${RED}CRITICAL ERROR: Could not configure Traefik after multiple attempts.${NC}"
    echo "Check: kubectl get helmchartconfig -A"
    exit 1
fi

# Pause to let ACME provider initialize internally
echo -e "${YELLOW}>>> Pausing 10s to ensure ACME engine is up...${NC}"
sleep 10

# --- 4. DEPLOY APPLICATION ---
echo -e "\n${GREEN}>>> Deploying RemnaNode...${NC}"

# Uninstall first to ensure clean state if re-running
helm uninstall remnanode -n remnanode 2>/dev/null || true
sleep 2

helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

# --- 5. CERTIFICATE VERIFICATION ---
echo -e "\n${GREEN}>>> Waiting for Certificate Issuance (Domain: $DOMAIN)...${NC}"
echo "This prevents the 'Default Cert' issue."

MAX_CHECKS=40
CHECK=0
CERT_OK=0

while [ $CHECK -lt $MAX_CHECKS ]; do
    # Check Issuer via curl
    ISSUER=$(curl -k -v --connect-timeout 5 "https://$DOMAIN" 2>&1 | grep "issuer:" | head -n 1)

    if [[ "$ISSUER" == *"Let's Encrypt"* ]]; then
        echo -e "\n${GREEN}>>> SSL VERIFIED! Issuer: Let's Encrypt${NC}"
        CERT_OK=1
        break
    fi

    echo -ne "${YELLOW}.${NC}"
    sleep 5
    CHECK=$((CHECK+1))
done

if [ $CERT_OK -eq 1 ]; then
    echo -e "\n\n${GREEN}==============================================${NC}"
    echo -e "${GREEN}   DEPLOYMENT COMPLETE & SECURE${NC}"
    echo -e "${GREEN}   URL: https://$DOMAIN${NC}"
    echo -e "${GREEN}==============================================${NC}"
else
    echo -e "\n${RED}WARNING: Certificate issuance is taking longer than expected.${NC}"
    echo "Check logs: kubectl logs -f -n kube-system -l app.kubernetes.io/name=traefik"
fi