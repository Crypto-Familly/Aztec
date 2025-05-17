#!/bin/bash

# Автоматична видача прав на виконання, якщо їх нема
if [[ ! -x "$0" ]]; then
  echo "Надаю права на виконання скрипту..."
  chmod +x "$0"
fi

# ==== Кольори ====
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# ==== Логотип і соцмережі ====
show_logo() {
  curl -s https://raw.githubusercontent.com/Crypto-Familly/crypto-familly-logo/refs/heads/main/logo.sh | bash 2>/dev/null

  echo -e "${CYAN}================= Crypto Familly =================${NC}"
  echo -e "💬 Telegram Hub: ${BLUE}https://t.me/CryptoFamilyHub${NC}"
  echo -e "💻 GitHub:        ${BLUE}https://github.com/Crypto-Familly${NC}"
  echo -e "${CYAN}==================================================${NC}"
}

# ==== Перевірка ОС ====
check_os() {
  version=$(lsb_release -rs)
  if [[ $(echo "$version < 22.04" | bc) -eq 1 ]]; then
    echo -e "${RED}[✘] Потрібна Ubuntu 22.04 або новіша. Поточна версія: $version${NC}"
    exit 101
  fi
}

# ==== Перевірка портів ====
check_ports() {
  ports=(8080 40400)
  for port in "${ports[@]}"; do
    if lsof -i :$port &>/dev/null; then
      echo -e "${RED}[!] Порт $port зайнятий!${NC}"
      echo "Процес:"
      sudo lsof -i :$port
      read -p "Завершити процес на порту $port? (y/n): " choice
      if [[ $choice == "y" ]]; then
        pid=$(sudo lsof -ti :$port)
        sudo kill -9 $pid
        echo -e "${GREEN}[✓] Процес завершено.${NC}"
      else
        echo -e "${RED}[✘] Необхідно звільнити порт для роботи ноди. Вихід.${NC}"
        exit 102
      fi
    fi
  done
}

# ==== Перевірка ресурсів ====
check_resources() {
  MIN_CPU=8
  MIN_RAM=16384  # 16GB в MB
  MIN_DISK_GB=100 # 100GB

  # CPU
  cpu_cores=$(nproc)
  if (( cpu_cores < MIN_CPU )); then
    echo -e "${RED}[✘] Мінімум ядер CPU: $MIN_CPU, знайдено: $cpu_cores${NC}"
    exit 103
  fi

  # RAM
  ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  ram_mb=$(( ram_kb / 1024 ))
  if (( ram_mb < MIN_RAM )); then
    echo -e "${RED}[✘] Мінімум оперативної пам'яті: $((MIN_RAM / 1024)) GB, знайдено: $((ram_mb / 1024)) GB${NC}"
    exit 104
  fi

  # Диск
  disk_kb=$(df --output=avail "$HOME" | tail -1)
  disk_gb=$(( disk_kb / 1024 / 1024 ))
  if (( disk_gb < MIN_DISK_GB )); then
    echo -e "${RED}[✘] Мінімум вільного місця на диску: ${MIN_DISK_GB}GB, знайдено: ${disk_gb}GB${NC}"
    exit 105
  fi

  echo -e "${GREEN}[✓] Перевірка ресурсів пройдена успішно.${NC}"
}

# ==== Встановлення залежностей ====
install_dependencies() {
  sudo apt-get update && sudo apt-get upgrade -y
  sudo apt install curl iptables build-essential git wget lz4 jq make gcc nano automake autoconf tmux htop nvme-cli libgbm1 pkg-config libssl-dev libleveldb-dev tar clang bsdmainutils ncdu unzip libleveldb-dev iptables-persistent -y
}

# ==== Встановлення Docker ====
install_docker() {
  if ! command -v docker &> /dev/null; then
    echo -e "${YELLOW}Docker не знайдено. Встановлюємо...${NC}"
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    sudo groupadd docker 2>/dev/null
    sudo usermod -aG docker $USER
    sudo chmod 666 /var/run/docker.sock
    sudo systemctl start docker
    rm get-docker.sh
    echo -e "${GREEN}[✓] Docker встановлено.${NC}"
  else
    echo -e "${GREEN}[✓] Docker вже встановлений.${NC}"
  fi
}

# ==== Перевірка версії Docker образу та автооновлення ====
auto_update_node() {
  echo -e "${CYAN}Перевірка оновлень Aztec-ноди...${NC}"
  local_image_version=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep aztecprotocol/aztec | head -n1)
  latest_version="aztecprotocol/aztec:0.85.0-alpha-testnet.8"

  if [[ "$local_image_version" != "$latest_version" ]]; then
    echo -e "${YELLOW}Доступне оновлення ноди. Завантажуємо новий образ...${NC}"
    docker pull "$latest_version"
    echo -e "${GREEN}[✓] Оновлення завершено.${NC}"
    # Перезапуск ноди, якщо запущена
    if systemctl is-active --quiet aztec-sequencer; then
      echo -e "${CYAN}Перезапускаємо Aztec-ноду...${NC}"
      sudo systemctl restart aztec-sequencer
      echo -e "${GREEN}[✓] Нода перезапущена.${NC}"
    fi
  else
    echo -e "${GREEN}Ваша Aztec-нода вже оновлена до останньої версії.${NC}"
  fi
}

# ==== Створення systemd-сервісу Aztec ====
setup_node() {
  echo -e "${GREEN}[+] Починаємо налаштування Aztec-ноди...${NC}"
  mkdir -p "$HOME/aztec-sequencer"
  cd "$HOME/aztec-sequencer" || exit 1

  docker pull aztecprotocol/aztec:0.85.0-alpha-testnet.8

  echo -n "🔑 Введіть ETHEREUM_HOSTS (RPC Sepolia): "
  read RPC
  echo -n "🔑 Введіть L1_CONSENSUS_HOST_URLS (Beacon Sepolia): "
  read BEACON
  echo -n "🔐 Введіть приватний ключ вашого валідатора: "
  read -s PRIVKEY
  echo
  IP=$(hostname -I | awk '{print $1}')
  echo -e "🌐 Визначено IP-адресу сервера: ${GREEN}$IP${NC}"

  mkdir -p "$HOME/my-node/node"

  SERVICE_PATH="/etc/systemd/system/aztec-sequencer.service"

  sudo tee $SERVICE_PATH > /dev/null <<EOF
[Unit]
Description=Aztec Sequencer Node
After=docker.service
Requires=docker.service

[Service]
User=$USER
Restart=always
RestartSec=10
ExecStart=/usr/bin/docker run --rm \\
  --network host \\
  -e ETHEREUM_HOSTS="$RPC" \\
  -e L1_CONSENSUS_HOST_URLS="$BEACON" \\
  -e DATA_DIRECTORY=/data \\
  -e VALIDATOR_PRIVATE_KEY="$PRIVKEY" \\
  -e P2P_IP="$IP" \\
  -e LOG_LEVEL=debug \\
  -v $HOME/my-node/node:/data \\
  --name aztec-sequencer \\
  aztecprotocol/aztec:0.85.0-alpha-testnet.8 \\
  sh -c 'node --no-warnings /usr/src/yarn-project/aztec/dest/bin/index.js start --network alpha-testnet --node --archiver --sequencer'

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reexec
  sudo systemctl daemon-reload
  sudo systemctl enable aztec-sequencer
  sudo systemctl start aztec-sequencer

  echo -e "${GREEN}[✓] Aztec-нода встановлена та налаштована на автозапуск.${NC}"
  echo "Щоб переглядати логи: ${GREEN}journalctl -fu aztec-sequencer${NC}"
}

# ==== Перевірка статусу ноди ====
check_node_status() {
  if systemctl is-active --quiet aztec-sequencer; then
    echo -e "${GREEN}Нода запущена та працює.${NC}"
    echo "Останні 10 рядків логів:"
    journalctl -u aztec-sequencer -n 10 --no-pager
  else
    echo -e "${RED}Нода не запущена.${NC}"
  fi
}

# ==== Меню ====
show_menu() {
  clear
  show_logo
  echo -e "\n${GREEN}1.${NC} Перевірити та встановити залежності, Docker, ресурси"
  echo -e "${GREEN}2.${NC} Перевірити порти та налаштувати Aztec-ноду"
  echo -e "${GREEN}3.${NC} Перевірити статус ноди та логи"
  echo -e "${GREEN}4.${NC} Автооновлення ноди"
  echo -e "${GREEN}0.${NC} Вийти"
  echo -ne "\nВиберіть опцію: "
  read choice

  case $choice in
    1)
      check_os
      check_resources
      install_dependencies
      install_docker
      ;;
    2)
      check_ports
      setup_node
      ;;
    3)
      check_node_status
      ;;
    4)
      auto_update_node
      ;;
    0)
      echo "До зустрічі!"
      exit 0
      ;;
    *)
      echo -e "${RED}Невірний вибір.${NC}"
      ;;
  esac
}

# ==== MAIN ====
main() {
  while true; do
    show_menu
    echo -e "\nНатисніть Enter для повернення до меню..."
    read
  done
}

main
