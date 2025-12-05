#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

# Проверка наличия файла секретов
if [ ! -f secrets.yaml ]; then
    echo "ОШИБКА: Файл secrets.yaml не найден!"
    exit 1
fi

# 1. Установка K3s
if ! command -v k3s &> /dev/null; then
    echo -e "${GREEN}>>> Установка K3s (Custom Ports)...${NC}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--kube-apiserver-arg service-node-port-range=1-65535" sh -
    sleep 20
else
    echo -e "${GREEN}>>> K3s уже установлен.${NC}"
fi

# Настройка прав (всегда)
if [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    chmod 644 /etc/rancher/k3s/k3s.yaml
else
    echo "ОШИБКА: Файл конфигурации K3s не найден!"
    exit 1
fi

# 2. Установка Helm
if ! command -v helm &> /dev/null; then
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo -e "${GREEN}>>> Ожидание инициализации Traefik...${NC}"
# Ждем пока появятся CRD от Traefik
TIMEOUT=0
while ! kubectl get crd ingressroutes.traefik.io &> /dev/null; do
    echo "Ждем регистрации CRD Traefik... ($TIMEOUT сек)"
    sleep 5
    TIMEOUT=$((TIMEOUT+5))
    if [ $TIMEOUT -ge 120 ]; then
        echo "ОШИБКА: Traefik не запустился за 2 минуты. Проверьте поды в kube-system."
        exit 1
    fi
done
echo -e "${GREEN}>>> Traefik готов!${NC}"

# 3. Настройка Email
EMAIL=$(grep 'email:' secrets.yaml | awk '{print $2}' | tr -d '"')
kubectl create secret generic traefik-acme-secret \
  --from-literal=email=$EMAIL \
  --namespace kube-system \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f configs/traefik-config.yaml

# 4. Деплой приложения
echo -e "${GREEN}>>> Деплой RemnaNode...${NC}"
helm upgrade --install remnanode ./charts/remnanode \
  --namespace remnanode \
  --create-namespace \
  -f secrets.yaml

echo -e "${GREEN}>>> Успешно! Статус подов:${NC}"
kubectl get pods -n remnanode