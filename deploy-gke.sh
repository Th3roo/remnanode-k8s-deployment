#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'

# Проверка секретов
if [ ! -f secrets.yaml ]; then
    echo "ERROR: secrets.yaml not found!"
    echo "Please copy secrets.example.yaml to secrets.yaml and fill in your data."
    exit 1
fi

echo -e "\${GREEN}>>> 1. Подключение Helm репозиториев... \${NC}"
helm repo add traefik https://traefik.github.io/charts
helm repo update

echo -e "\${GREEN}>>> 2. Установка/Обновление Traefik (GKE Mode)... \${NC}"
# Извлекаем email для Let's Encrypt
EMAIL=\$(grep 'email:' secrets.yaml | awk '{print \$2}' | tr -d '"')

# Устанавливаем Traefik с передачей аргументов для SSL
helm upgrade --install traefik traefik/traefik \\
  --namespace kube-system \\
  --values configs/traefik-gke-values.yaml \\
  --set additionalArguments="{--certificatesresolvers.le.acme.tlschallenge=true,--certificatesresolvers.le.acme.storage=/data/acme.json,--certificatesresolvers.le.acme.email=\$EMAIL,--certificatesresolvers.le.acme.caServer=https://acme-v02.api.letsencrypt.org/directory}" \\
  --wait

echo -e "\${GREEN}>>> Traefik готов. \${NC}"

echo -e "\${GREEN}>>> 3. Деплой RemnaNode... \${NC}"
# Деплоим твой чарт
helm upgrade --install remnanode ./charts/remnanode \\
  --namespace remnanode \\
  --create-namespace \\
  -f secrets.yaml

echo -e "\${GREEN}>>> Деплой успешен! \${NC}"

# Пытаемся получить внешний IP ноды
NODE_IP=\$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')

echo -e "\${GREEN}==============================================\${NC}"
echo -e "\${GREEN}>>> IP для DNS (A-запись): \$NODE_IP \${NC}"
echo -e "\${GREEN}==============================================\${NC}"
