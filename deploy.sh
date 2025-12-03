#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

if [ ! -f secrets.yaml ]; then
    echo "ОШИБКА: Файл secrets.yaml не найден!"
    exit 1
fi

# 1. Установка K3s с расширенным диапазоном портов
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Установка K3s (Custom Ports)...${NC}"
    # Разрешаем использовать любые порты для NodePort/HostPort
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--kube-apiserver-arg service-node-port-range=1-65535" sh -
    
    echo "Ожидание готовности кластера..."
    sleep 20
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 /etc/rancher/k3s/k3s.yaml
else
    echo -e "${GREEN}>>> K3s уже установлен.${NC}"
fi

# 2. Установка Helm
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# 3. Настройка Email
EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f configs/traefik-config.yaml

# 4. Деплой
echo -e "${GREEN}>>> Деплой RemnaNode...${NC}"
helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

echo -e "${GREEN}>>> Готово!${NC}"
kubectl get pods -n remnanode