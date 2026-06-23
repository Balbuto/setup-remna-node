#!/bin/bash
# ==============================================================================
# 🚀 ИНТЕРАКТИВНЫЙ ИНСТРУМЕНТ НАСТРОЙКИ И УПРАВЛЕНИЯ REMNANODE (v1.7.2)
# ==============================================================================
# Скрипт автоматического развертывания, оптимизации и маскировки ноды Remnawave.
# Объединяет лучшие практики безопасности, сетевой оптимизации и отказоустойчивости.
#
# Особенности:
#  - Полностью русифицированный интерфейс и информационные сообщения
#  - Исправлена константа SCRIPT_URL на правильный адрес репозитория Balbuto
#  - Принудительная мгновенная проверка прав root на первой строчке запуска скрипта
#  - Полный вынос и отображение внутренних логов Xray (out/err) на хост
#  - Полностью исправлена подсистема диагностики (устойчива к локалям и pipefail)
#  - Исправлен баг Nginx proxy_protocol в TLS/xHTTP режимах (сайт-заглушка работает!)
#  - Предотвращение конфликтов портов при одновременном запуске TLS и xHTTP
#  - Поддержка передового протокола VLESS+TLS+xHTTP (Xray-Core)
#  - Смена маскировочных шаблонов: как случайно, так и выбор конкретного из списка
#  - Встроенный профессиональный мутатор 'uniquify-theme' и шаблоны Mrvibecodic
#  - Интерактивная настройка и открытие кастомных портов Xray Core в UFW
#  - Динамическое удаление образов Docker (images) при деинсталляции
#  - Автоматическая глобальная регистрация команды 'remnanode' при первом запуске
#  - Интерактивное меню управления и статус ноды в реальном времени
#  - Контейнер Nginx ВСЕГДА устанавливается в качестве маскировочного fallback сайта
#  - Раздел диагностики системы (ресурсы CPU, ОЗУ, Диск) и размеров логов
#  - Просмотр логов Xray/Nginx/Docker в реальном времени
#  - Строгий режим Bash: set -Eeuo pipefail
#  - Оптимизация сети (BBR + SAFE/HIGHLOAD Sysctl профили)
#  - Выбор версий Xray-Core (включая pre-releases) через GitHub API
#  - Поддержка трех протоколов: VLESS Reality (Selfsteal), VLESS+TLS, VLESS+TLS+xHTTP
#  - Прописывание SSL-сертификатов непосредственно в секцию remnanode (для TLS/xHTTP)
#  - Полный вынос логов Nginx и Remnanode на хост с авторотацией (logrotate)
#  - Скрытность маскировочных сайтов (мутация HTML, мета-тегов и CSS)
#  - Безопасная, недеструктивная настройка UFW (без сброса не связанных правил)
#  - Множественные варианты выпуска SSL: Standalone, Cloudflare DNS, Gcore DNS
#  - Управление IPv6, смена доменов, смена IP панели и чистый деинсталлятор
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# --- ЖЕСТКАЯ ПРОВЕРКА ПРАВ ROOT (Выполняется на самом первом этапе, до инициализации файлов) ---
if [ "$EUID" -ne 0 ]; then
    echo -e "\033[0;31m[✗] Ошибка: Этот скрипт должен быть запущен от имени root! Пожалуйста, используйте 'sudo' или 'su'.\033[0m" >&2
    exit 1
fi

# --- Ссылка на сырой код скрипта в репозитории Balbuto ---
# (Используется для удаленной автоматической регистрации и обновлений)
SCRIPT_URL="https://raw.githubusercontent.com/Balbuto/setup-remna-node/main/setup_node.sh"

# --- Цвета ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'; GRAY='\033[38;5;244m'; NC='\033[0m'

# --- Символы ---
INFO="[${BLUE}i${NC}]"
SUCCESS="[${GREEN}✓${NC}]"
WARNING="[${YELLOW}!${NC}]"
ERROR="[${RED}✗${NC}]"

# --- Константы путей ---
APP_DIR="/opt/remnanode"
LOG_DIR="/var/log/remnanode"
LOG_FILE="/var/log/remnanode_install.log"
XRAY_BIN_DIR="/opt/remnanode/bin"
XRAY_FILE="$XRAY_BIN_DIR/xray"
CERTS_DIR="/opt/remnanode/certs"
WWW_DIR="/var/www/html"

# Инициализируем переменные, чтобы избежать ошибок unbound variable при вызове из разных функций
XRAY_VERSION_CHOICE="built-in"
NODE_DOMAIN=""
DECOY_DOMAIN="github.com"

# --- Инициализация логирования ---
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== Запуск управления Remnanode: $(date) ===" > "$LOG_FILE"

log() {
    echo -e "$1"
    # Удаляем ANSI-цвета перед записью в лог
    echo "$1" | sed -r 's/\x1B\[[0-9;]*[mK]//g' >> "$LOG_FILE"
}

# --- Проверки окружения ---
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
            log "${WARNING} Скрипт тестировался на Ubuntu/Debian. Ваша ОС: $NAME. Возможны сбои."
        fi
    else
        log "${ERROR} Не удалось определить операционную систему."
        exit 1
    fi
}

detect_arch() {
    ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$ARCH" in
        amd64|x86_64) ARCH_XRAY="64" ;;
        arm64|aarch64) ARCH_XRAY="arm64-v8a" ;;
        *) log "${ERROR} Неподдерживаемая архитектура: $ARCH"; exit 1 ;;
    esac
}

# --- Автоматическая регистрация команды в системе (С исправлениями для удаленного curl-запуска) ---
register_globally() {
    local script_path; script_path=$(readlink -f "$0")
    
    # Обнаружение удаленного запуска (через curl | bash или bash <(curl ...))
    if [[ "$script_path" =~ /dev/fd/ || "$script_path" == "bash" || "$script_path" == "stdin" || ! -f "$script_path" ]]; then
        log "${INFO} Обнаружен удаленный запуск скрипта. Загружаем физический файл в систему..."
        mkdir -p "/usr/local/bin"
        
        # Скачиваем файл скрипта напрямую по SCRIPT_URL
        if wget -q -O "/usr/local/bin/remnanode" "$SCRIPT_URL"; then
            chmod +x "/usr/local/bin/remnanode" 2>/dev/null || true
            log "${SUCCESS} Скрипт успешно сохранен и зарегистрирован как команда: ${GREEN}remnanode${NC}"
            sleep 1.5
        else
            # Резервная попытка через curl
            if curl -sSL "$SCRIPT_URL" -o "/usr/local/bin/remnanode" 2>/dev/null; then
                chmod +x "/usr/local/bin/remnanode" 2>/dev/null || true
                log "${SUCCESS} Скрипт успешно сохранен и зарегистрирован как команда: ${GREEN}remnanode${NC}"
                sleep 1.5
            fi
        fi
    else
        # Локальный классический запуск
        if [ "$script_path" != "/usr/local/bin/remnanode" ]; then
            ln -sf "$script_path" "/usr/local/bin/remnanode" &>/dev/null || cp "$script_path" "/usr/local/bin/remnanode" &>/dev/null
            chmod +x "/usr/local/bin/remnanode" 2>/dev/null || true
            log "${SUCCESS} Скрипт успешно зарегистрирован в системе!"
            log "${INFO} Теперь вы можете запускать меню из любой папки командой: ${GREEN}remnanode${NC}"
            sleep 1.5
        fi
    fi
}

# --- Извлечение базового домена для Wildcard ---
extract_base_domain() {
    local domain="$1"
    echo "$domain" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

# --- Системная оптимизация ---
optimize_network() {
    log "${INFO} Настройка сетевого стека..."
    
    # Резервное копирование sysctl
    if [ -f /etc/sysctl.d/99-remnanode.conf ]; then
        cp /etc/sysctl.d/99-remnanode.conf /etc/sysctl.d/99-remnanode.conf.bak
    fi

    # Определение объема памяти
    local ram_kb; ram_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local ram_gb; ram_gb=$((ram_kb / 1024 / 1024))
    
    log "${INFO} Обнаружено ОЗУ: ${ram_gb} GB"
    
    # Выбор профиля sysctl
    if [ "$ram_gb" -ge 2 ]; then
        log "${SUCCESS} Применяется профиль HIGHLOAD для оптимальной работы VPN"
        cat > /etc/sysctl.d/99-remnanode.conf <<EOF
# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# Limits & Buffer Tuning
fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
vm.swappiness = 10
vm.max_map_count = 262144

net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_tw_reuse = 1

# Security
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Conntrack
net.netfilter.nf_conntrack_max = 1048576
EOF
    else
        log "${SUCCESS} Применяется профиль SAFE (консервативный) для VPS с малым объемом памяти"
        cat > /etc/sysctl.d/99-remnanode.conf <<EOF
# TCP BBR Congestion Control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

fs.file-max = 524288
vm.swappiness = 10
vm.max_map_count = 262144

net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 600

# Security
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0

# Conntrack
net.netfilter.nf_conntrack_max = 65536
EOF
    fi

    # Настройка лимитов системных ресурсов
    cat > /etc/security/limits.d/99-remnanode.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    sysctl --system >> "$LOG_FILE" 2>&1 || true
    log "${SUCCESS} Сетевые параметры ядра и системные лимиты успешно обновлены."
}

# --- Установка dependencies ---
install_dependencies() {
    log "${INFO} Установка необходимых пакетов..."
    apt-get update -qq
    apt-get install -y -qq curl wget jq unzip tar cron logrotate ufw certbot ca-certificates gnupg python3-pip perl openssl >> "$LOG_FILE" 2>&1
    
    # Безопасная установка Docker через официальный репозиторий
    if ! command -v docker &> /dev/null; then
        log "${INFO} Установка Docker через официальный репозиторий..."
        install -m 0755 -d /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || \
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg
        fi
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
          > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >> "$LOG_FILE" 2>&1
        systemctl enable --now docker >> "$LOG_FILE" 2>&1
        log "${SUCCESS} Docker успешно установлен."
    else
        log "${SUCCESS} Docker уже установлен."
    fi
}

# --- Менеджер версий Xray-Core ---
select_xray_version() {
    log "${INFO} Получение версий Xray-Core с GitHub..."
    local releases_json
    releases_json=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases 2>/dev/null || echo "")
    
    if [ -z "$releases_json" ]; then
        log "${WARNING} Не удалось получить список версий с API GitHub. Будет установлена встроенная в контейнер версия."
        XRAY_VERSION_CHOICE="built-in"
        return
    fi

    # Извлечение тегов версий и признака pre-release
    local versions
    versions=$(echo "$releases_json" | jq -r '.[] | "\(.tag_name) (Pre-release: \(.prerelease))"')
    
    echo -e "\n${BLUE}✨ ВЫБОР ВЕРСИИ XRAY-CORE${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    local i=1
    declare -A version_map
    
    # Показываем встроенный вариант по умолчанию
    echo -e " 1) Использовать версию из контейнера (по умолчанию)"
    version_map[1]="built-in"
    
    while IFS= read -r line; do
        if [ $i -ge 10 ]; then break; fi
        local tag_name; tag_name=$(echo "$line" | awk '{print $1}')
        local is_pre; is_pre=$(echo "$line" | grep -q "Pre-release: true" && echo "yes" || echo "no")
        
        local display_tag="$tag_name"
        if [ "$is_pre" = "yes" ]; then
            display_tag="${tag_name} ${RED}[Pre-release]${NC}"
        else
            display_tag="${tag_name} ${GREEN}[Stable]${NC}"
        fi
        
        echo -e " $((i+1))) Xray-Core $display_tag"
        version_map[$((i+1))]="$tag_name"
        ((i++))
    done <<< "$versions"
    
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -p "Выберите номер версии [1]: " version_num
    version_num=${version_num:-1}
    
    XRAY_VERSION_CHOICE="${version_map[$version_num]:-built-in}"
    log "${SUCCESS} Выбран вариант: ${CYAN}$XRAY_VERSION_CHOICE${NC}"
    
    if [ "$XRAY_VERSION_CHOICE" != "built-in" ]; then
        download_xray_core "$XRAY_VERSION_CHOICE"
    fi
}

download_xray_core() {
    local version="$1"
    log "${INFO} Загрузка Xray-Core ${version} для архитектуры ${ARCH_XRAY}..."
    
    mkdir -p "$XRAY_BIN_DIR"
    local temp_dir; temp_dir=$(mktemp -d)
    
    local download_url="https://github.com/XTLS/Xray-core/releases/download/${version}/Xray-linux-${ARCH_XRAY}.zip"
    
    if ! wget -q --show-progress -O "$temp_dir/xray.zip" "$download_url"; then
        log "${ERROR} Не удалось скачать Xray-Core!"
        rm -rf "$temp_dir"
        exit 1
    fi
    
    unzip -q -o "$temp_dir/xray.zip" -d "$temp_dir"
    mv "$temp_dir/xray" "$XRAY_FILE"
    chmod +x "$XRAY_FILE"
    
    # Также сохраняем geo-файлы
    mv "$temp_dir/geoip.dat" "$XRAY_BIN_DIR/geoip.dat" 2>/dev/null || true
    mv "$temp_dir/geosite.dat" "$XRAY_BIN_DIR/geosite.dat" 2>/dev/null || true
    
    rm -rf "$temp_dir"
    log "${SUCCESS} Xray-Core успешно сохранен в $XRAY_FILE"
}

# --- Логирование и Ротация логов на хосте ---
setup_logging_and_rotation() {
    log "${INFO} Настройка папок логов и автоматической ротации..."
    
    # Создание директорий логов на хосте
    mkdir -p "$LOG_DIR/node"
    mkdir -p "$LOG_DIR/nginx"
    
    # Конфигурация logrotate для логов ноды и nginx
    local logrotate_config="/etc/logrotate.d/remnanode"
    
    cat > "$logrotate_config" <<EOF
$LOG_DIR/node/*.log $LOG_DIR/nginx/*.log {
    daily
    size 50M
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    sharedscripts
    postrotate
        docker restart remnawave-nginx 2>/dev/null || true
    endscript
}
EOF
    
    chmod 644 "$logrotate_config"
    log "${SUCCESS} Лог-файлы будут записываться на хосте в каталог ${BLUE}$LOG_DIR${NC}"
    log "${SUCCESS} Logrotate успешно настроен: ротация ежедневная / при достижении 50MB, хранение 7 архивов."
}

# --- Универсальный выпуск SSL сертификатов (по типу eGamesAPI) ---
issue_ssl_certificates_multi() {
    local domain="$1"
    
    echo -e "\n${BLUE}🔐 ВЫБОР МЕТОДА ВЫПУСКА SSL СЕРТИФИКАТА${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    echo " 1) Cloudflare API (DNS-01, с поддержкой wildcard *.домен)"
    echo " 2) Certbot Standalone (HTTP-01, проверка по 80 порту - стандартно)"
    echo " 3) Gcore DNS API (DNS-01, с поддержкой wildcard *.домен)"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -p "Выберите метод выпуска [2]: " ssl_method
    ssl_method=${ssl_method:-2}
    
    local base_domain; base_domain=$(extract_base_domain "$domain")
    local wildcard_domain="*.$base_domain"
    
    # Запрос почты
    read -p "Введите ваш email для Let's Encrypt: " le_email
    while [ -z "$le_email" ]; do
        read -p "${RED}Email обязателен для получения SSL: ${NC}" le_email
    done
    
    # Папка для сертификатов ноды
    mkdir -p "$CERTS_DIR"
    
    case $ssl_method in
        1)
            # Cloudflare API (DNS-01)
            log "${INFO} Подготовка к выпуску сертификата через Cloudflare API (DNS-01)..."
            
            # Установка пакета плагина
            apt-get install -y -qq python3-certbot-dns-cloudflare >> "$LOG_FILE" 2>&1
            
            echo -e "\nВыберите метод авторизации Cloudflare:"
            echo " 1) Через API Token (Рекомендуется, более безопасно)"
            echo " 2) Через Global API Key (Устаревший метод)"
            read -p "Ваш выбор [1]: " cf_auth_method
            cf_auth_method=${cf_auth_method:-1}
            
            mkdir -p ~/.secrets/certbot
            
            if [ "$cf_auth_method" -eq 1 ]; then
                read -p "Введите ваш Cloudflare API Token: " cf_token
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $cf_token
EOL
            else
                read -p "Введите ваш Cloudflare Email: " cf_email
                read -p "Введите ваш Global API Key: " cf_key
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $cf_email
dns_cloudflare_api_key = $cf_key
EOL
            fi
            
            chmod 600 ~/.secrets/certbot/cloudflare.ini
            
            log "${INFO} Запуск выпуска Wildcard-сертификата (*.${base_domain})..."
            if certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$base_domain" \
                -d "$wildcard_domain" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$LOG_FILE" 2>&1; then
                
                cp "/etc/letsencrypt/live/$base_domain/fullchain.pem" "$CERTS_DIR/fullchain.pem"
                cp "/etc/letsencrypt/live/$base_domain/privkey.pem" "$CERTS_DIR/privkey.pem"
                log "${SUCCESS} Wildcard SSL сертификат успешно выпущен через Cloudflare DNS!"
            else
                log "${ERROR} Ошибка выпуска сертификата через Cloudflare API! Проверьте лог $LOG_FILE"
                exit 1
            fi
            ;;
            
        2)
            # Certbot Standalone (HTTP-01)
            log "${INFO} Выпуск сертификата в Standalone режиме (HTTP-01)..."
            
            # Освобождаем 80 порт
            systemctl stop nginx 2>/dev/null || true
            docker stop remnawave-nginx 2>/dev/null || true
            
            if command -v ufw &> /dev/null; then
                ufw allow 80/tcp comment 'HTTP for Certbot verification' >/dev/null 2>&1
                ufw reload >/dev/null 2>&1
            fi
            
            if certbot certonly \
                --standalone \
                -d "$domain" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$LOG_FILE" 2>&1; then
                
                cp "/etc/letsencrypt/live/$domain/fullchain.pem" "$CERTS_DIR/fullchain.pem"
                cp "/etc/letsencrypt/live/$domain/privkey.pem" "$CERTS_DIR/privkey.pem"
                log "${SUCCESS} SSL сертификат успешно выпущен в Standalone режиме!"
            else
                log "${ERROR} Не удалось выпустить SSL сертификат! Ознакомьтесь с логом $LOG_FILE"
                exit 1
            fi
            ;;
            
        3)
            # Gcore DNS API (DNS-01)
            log "${INFO} Подготовка к выпуску сертификата через Gcore DNS API (DNS-01)..."
            
            # Установка плагина gcore
            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                log "${INFO} Установка плагина certbot-dns-gcore..."
                python3 -m pip install --break-system-packages certbot-dns-gcore >> "$LOG_FILE" 2>&1 || \
                python3 -m pip install certbot-dns-gcore >> "$LOG_FILE" 2>&1
            fi
            
            read -p "Введите ваш Gcore API Token: " gcore_token
            
            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $gcore_token
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini
            
            log "${INFO} Запуск выпуска Wildcard-сертификата (*.${base_domain}) через Gcore..."
            if certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$base_domain" \
                -d "$wildcard_domain" \
                --email "$le_email" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1 >> "$LOG_FILE" 2>&1; then
                
                cp "/etc/letsencrypt/live/$base_domain/fullchain.pem" "$CERTS_DIR/fullchain.pem"
                cp "/etc/letsencrypt/live/$base_domain/privkey.pem" "$CERTS_DIR/privkey.pem"
                log "${SUCCESS} Wildcard SSL сертификат успешно выпущен через Gcore DNS!"
            else
                log "${ERROR} Ошибка выпуска сертификата через Gcore API! Проверьте лог $LOG_FILE"
                exit 1
            fi
            ;;
        *)
            log "${ERROR} Выбран неверный метод."
            exit 1
            ;;
    esac
    
    chmod 600 "$CERTS_DIR/"*
    
    # Настройка автоматического продления и копирования сертификатов в Remnanode
    local active_domain="$domain"
    if [ "$ssl_method" -eq 1 ] || [ "$ssl_method" -eq 3 ]; then
        active_domain="$base_domain"
    fi
    
    local renew_hook_file="/etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh"
    mkdir -p "$(dirname "$renew_hook_file")"
    cat > "$renew_hook_file" <<EOF
#!/bin/bash
if [ -d "/etc/letsencrypt/live/$active_domain" ]; then
    cp "/etc/letsencrypt/live/$active_domain/fullchain.pem" "$CERTS_DIR/fullchain.pem"
    cp "/etc/letsencrypt/live/$active_domain/privkey.pem" "$CERTS_DIR/privkey.pem"
    chmod 600 "$CERTS_DIR/"*
    docker restart remnanode 2>/dev/null || true
fi
EOF
    chmod +x "$renew_hook_file"
}

# --- Маскировочные шаблоны (SelfSteal + встроенный мутатор Mrvibecodic/node-templates) ---
generate_masked_template() {
    local decoy_domain="$1"
    local chosen_template_arg="${2:-}"  # Необязательный аргумент конкретного шаблона
    
    log "${INFO} Загрузка профессиональных шаблонов маскировки Mrvibecodic/node-templates..."
    
    mkdir -p "$WWW_DIR"
    local temp_zip; temp_zip=$(mktemp)
    
    # Скачивание репозитория Mrvibecodic/node-templates с мутатором
    local templates_url="https://github.com/Mrvibecodic/node-templates/archive/refs/heads/main.zip"
    if ! wget -q -O "$temp_zip" "$templates_url"; then
        log "${WARNING} Не удалось скачать шаблоны Mrvibecodic, генерируем базовую уникальную HTML заглушку."
        create_fallback_html "$decoy_domain"
        rm -f "$temp_zip"
        return
    fi
    
    local temp_unzip; temp_unzip=$(mktemp -d)
    unzip -q -o "$temp_zip" -d "$temp_unzip"
    
    local repo_root="$temp_unzip/node-templates-main"
    if [ ! -d "$repo_root" ]; then
        log "${WARNING} Ошибка структуры архива. Генерируем базовую HTML заглушку."
        create_fallback_html "$decoy_domain"
        rm -rf "$temp_unzip" "$temp_zip"
        return
    fi
    
    # Доступные высококачественные шаблоны
    local templates=("endless-verify" "esports-stream-template" "levelup-hub" "playza-game-catalog" "rybaliti-2.0" "screenwire-digest" "vibrai-photo-editor" "worldzoo-stream-template")
    
    # Определяем выбранный шаблон (случайный или конкретный)
    local selected_template=""
    if [ -n "$chosen_template_arg" ]; then
        selected_template="$chosen_template_arg"
    else
        selected_template="${templates[$RANDOM % ${#templates[@]}]}"
    fi
    
    log "${INFO} Выбран профессиональный шаблон маскировки: ${CYAN}$selected_template${NC}"
    
    # Запускаем продвинутую контекстную мутацию и анти-фингерпринтинг с помощью uniquify-theme.sh
    local temp_out; temp_out=$(mktemp -d)
    
    log "${INFO} Запуск мутатора уникальности кода 'uniquify-theme'..."
    if bash "$repo_root/uniquify-theme.sh" \
        -s "$repo_root/$selected_template" \
        -o "$temp_out" \
        --seed "$(openssl rand -hex 16)" \
        --no-zip \
        --no-install-deps >> "$LOG_FILE" 2>&1; then
        
        # Полностью очищаем WWW_DIR и копируем мутированные файлы
        rm -rf "$WWW_DIR"/* 2>/dev/null || true
        mkdir -p "$WWW_DIR"
        cp -r "$temp_out"/* "$WWW_DIR/"
        log "${SUCCESS} Маскировочный сайт успешно сгенерирован и полностью уникализирован по хэшам и классам!"
    else
        log "${WARNING} Ошибка работы мутатора uniquify-theme. Копируем файлы без мутации."
        rm -rf "$WWW_DIR"/* 2>/dev/null || true
        mkdir -p "$WWW_DIR"
        cp -r "$repo_root/$selected_template"/* "$WWW_DIR/"
    fi
    
    rm -rf "$temp_unzip" "$temp_zip" "${temp_out:-}"
}

create_fallback_html() {
    local domain="$1"
    mkdir -p "$WWW_DIR"
    local rand_id; rand_id=$(openssl rand -hex 8)
    cat > "$WWW_DIR/index.html" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta name="server-hash" content="${rand_id}">
    <title>Сайт на реконструкции</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background-color: #f8f9fa; color: #212529; margin: 0; }
        .container { text-align: center; padding: 2rem; border-radius: 8px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); background: white; }
        h1 { font-size: 24px; margin-bottom: 8px; }
        p { color: #6c757d; font-size: 14px; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Сайт временно недоступен</h1>
        <p>На данном ресурсе ведутся запланированные технические работы. Пожалуйста, зайдите позже.</p>
    </div>
</body>
</html>
EOF
}

# --- Развертывание Docker Compose ---
deploy_compose() {
    local protocol="$1"
    local node_port="$2"
    local secret_key="$3"
    
    mkdir -p "$APP_DIR"
    cd "$APP_DIR"
    
    # Сохранение секретов во внешнем файле окружения .env
    cat > .env <<EOF
### REMNANODE CONFIG ###
NODE_PORT=$node_port
SECRET_KEY=$secret_key
XTLS_API_PORT=61000
EOF

    # Генерация самоподписанных (snakeoil) SSL ключей для локального fallback веб-сервера Nginx
    # Мы генерируем их во внутреннем каталоге ноды для изоляции от внешнего окружения
    local snakeoil_cert="$CERTS_DIR/snakeoil.pem"
    local snakeoil_key="$CERTS_DIR/snakeoil.key"
    if [ ! -f "$snakeoil_cert" ]; then
        mkdir -p "$CERTS_DIR"
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "$snakeoil_key" \
            -out "$snakeoil_cert" \
            -subj "/CN=localhost" >> "$LOG_FILE" 2>&1
        chmod 600 "$snakeoil_key" "$snakeoil_cert"
    fi

    # Формирование docker-compose.yml (Контейнер Nginx ВСЕГДА разворачивается для маскировки)
    cat > docker-compose.yml <<EOF
services:
  remnanode:
    image: ghcr.io/remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
    env_file:
      - .env
    volumes:
      - /dev/shm:/dev/shm:rw
      - $LOG_DIR/node:/var/log/supervisor
$( [ "$protocol" = "tls" ] || [ "$protocol" = "xhttp" ] && echo "      - $CERTS_DIR:/etc/xray/certs:ro" )
$( [ "$XRAY_VERSION_CHOICE" != "built-in" ] && echo "      - $XRAY_FILE:/usr/local/bin/xray" )
$( [ "$XRAY_VERSION_CHOICE" != "built-in" ] && [ -f "$XRAY_BIN_DIR/geoip.dat" ] && echo "      - $XRAY_BIN_DIR/geoip.dat:/usr/local/share/xray/geoip.dat" )
$( [ "$XRAY_VERSION_CHOICE" != "built-in" ] && [ -f "$XRAY_BIN_DIR/geosite.dat" ] && echo "      - $XRAY_BIN_DIR/geosite.dat:/usr/local/share/xray/geosite.dat" )

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - /dev/shm:/dev/shm:rw
      - $WWW_DIR:/var/www/html:ro
      - $LOG_DIR/nginx:/var/log/nginx
      - $CERTS_DIR/snakeoil.pem:/etc/nginx/ssl/snakeoil.pem:ro
      - $CERTS_DIR/snakeoil.key:/etc/nginx/ssl/snakeoil.key:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
EOF

    # Формирование nginx.conf в зависимости от протокола
    if [ "$protocol" = "reality" ]; then
        # VLESS Reality: Xray пересылает зашифрованный TLS трафик с proxy_protocol на Nginx, Nginx терминирует SSL
        cat > nginx.conf <<EOF
server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    server_name $NODE_DOMAIN;
    ssl_certificate "/etc/nginx/ssl/snakeoil.pem";
    ssl_certificate_key "/etc/nginx/ssl/snakeoil.key";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

        # Установка snakeoil сертификатов если их нет (нужно для валидности конфига Nginx)
        if [ ! -f /etc/ssl/certs/ssl-cert-snakeoil.pem ]; then
            apt-get install -y ssl-cert >> "$LOG_FILE" 2>&1 || {
                openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout /etc/ssl/private/ssl-cert-snakeoil.key \
                -out /etc/ssl/certs/ssl-cert-snakeoil.pem \
                -subj "/CN=localhost" >> "$LOG_FILE" 2>&1
            }
        fi
    else
        # VLESS+TLS / VLESS+TLS+xHTTP: Xray расшифровал трафик (или использует чистый сокет), 
        # Nginx принимает HTTP-запросы из Unix-сокета с поддержкой proxy_protocol (Исправлено!)
        cat > nginx.conf <<EOF
server {
    listen unix:/dev/shm/nginx.sock proxy_protocol default_server;
    server_name _;

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet" always;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    fi

    # Запуск контейнеров
    log "${INFO} Запуск контейнеров Docker..."
    docker compose down &>/dev/null || true
    docker compose up -d >> "$LOG_FILE" 2>&1
    
    if [ $? -eq 0 ]; then
        log "${SUCCESS} Контейнеры успешно развернуты и запущены!"
    else
        log "${ERROR} Ошибка запуска контейнеров! Проверьте логи: $LOG_FILE"
        exit 1
    fi
}

# --- Фаервол (UFW) ---
configure_firewall() {
    local node_port="$1"
    local panel_ip="$2"
    
    log "${INFO} Настройка брандмауэра UFW..."
    
    # 1. Задаем политики по умолчанию, не сбрасывая фаервол полностью во избежание пропажи SSH/других правил
    ufw default deny incoming >> "$LOG_FILE" 2>&1 || true
    ufw default allow outgoing >> "$LOG_FILE" 2>&1 || true
    
    # 2. Автоопределение активного порта SSH во избежание локаута
    local ssh_port=22
    if command -v ss &>/dev/null; then
        local detected_port; detected_port=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | grep -oE '[0-9]+$' | head -n 1)
        if [ -n "$detected_port" ]; then
            ssh_port="$detected_port"
        fi
    fi
    log "${INFO} Разрешаем активный порт SSH: ${CYAN}$ssh_port${NC}"
    ufw allow "$ssh_port"/tcp comment 'SSH Port' >> "$LOG_FILE" 2>&1
    
    # 3. Разрешение веб-трафика для Xray / Nginx (HTTP, HTTPS)
    log "${INFO} Разрешаем порты HTTP (80) и HTTPS (443) для Xray/Nginx..."
    ufw allow 80/tcp comment 'HTTP / Certbot' >> "$LOG_FILE" 2>&1
    ufw allow 443/tcp comment 'Xray Incoming TCP' >> "$LOG_FILE" 2>&1
    ufw allow 443/udp comment 'Xray Incoming UDP' >> "$LOG_FILE" 2>&1
    
    # 4. Открытие кастомных портов Xray Core, если они настроены
    if [ -f "$APP_DIR/.xray_ports" ]; then
        local custom_ports; custom_ports=$(cat "$APP_DIR/.xray_ports" | tr '\n' ' ' | xargs)
        for port in $custom_ports; do
            if [ -n "$port" ]; then
                log "${INFO} Открытие в UFW кастомного порта Xray: ${CYAN}$port${NC}"
                ufw allow "$port"/tcp comment 'Xray Custom Port TCP' >> "$LOG_FILE" 2>&1
                ufw allow "$port"/udp comment 'Xray Custom Port UDP' >> "$LOG_FILE" 2>&1
            fi
        done
    fi
    
    # 5. Строгое ограничение: порт управления доступен ТОЛЬКО для IP панели
    log "${INFO} Ограничиваем порт управления ${CYAN}$node_port${NC} только для IP панели: ${GREEN}$panel_ip${NC}"
    ufw allow from "$panel_ip" to any port "$node_port" proto tcp comment 'Remnanode Control from Panel' >> "$LOG_FILE" 2>&1
    
    # 6. Активация UFW
    ufw --force enable >> "$LOG_FILE" 2>&1
    ufw reload >> "$LOG_FILE" 2>&1
    
    log "${SUCCESS} Брандмауэр UFW успешно настроен!"
}

# --- Вспомогательный безопасный запуск внешних скриптов с HTTPS и TLS (По типу Balbuto) ---
run_verified_benchmark() {
    local name="$1"
    local url="$2"
    local args="${3:-}"
    
    echo -e "\n${BLUE}🧪 Запуск теста: ${WHITE}$name${NC}..."
    echo -e "${GRAY}Безопасная загрузка с: $url${NC}"
    
    local temp_script; temp_script=$(mktemp)
    
    # Скачивание только по HTTPS с протоколом TLS 1.2+
    if curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 -o "$temp_script" "$url" 2>>"$LOG_FILE"; then
        chmod +x "$temp_script"
        echo -e "${GREEN}Запуск теста...${NC}\n"
        
        # Выполнение в подоболочке с локально выключенным set -e, чтобы падение теста не уронило весь CLI
        (
            set +e
            set +o pipefail
            if [ -n "$args" ]; then
                bash "$temp_script" $args
            else
                bash "$temp_script"
            fi
        )
        echo -e "\n${SUCCESS} Тест '${name}' завершен!"
    else
        echo -e "${ERROR} Ошибка скачивания скрипта. Проверьте подключение к сети."
    fi
    rm -f "$temp_script"
}

# --- Подсистема проведения комплексных мульти-тестов сервера (v1.7.0) ---
run_server_multitests() {
    (
        set +e
        set +o pipefail
        
        while true; do
            clear
            echo -e "${GREEN}"
            echo "  ========================================================"
            echo "  🧪 МУЛЬТИ-ТЕСТЫ И ДИАГНОСТИКА СЕРВЕРА (v1.7.0)"
            echo "  ========================================================"
            echo -e "${NC}"
            echo " Выберите тест для запуска:"
            echo " 1) 🌍 Проверка локации IP и провайдера (IP Geolocation)"
            echo " 2) 🚫 Censorcheck — Тест геоблокировок (доступность RU/западных сайтов)"
            echo " 3) 🕵️ Censorcheck — Тест DPI (активное вмешательство провайдера)"
            echo " 4) ⚡ iPerf3 RU — Скорость интернета до серверов в РФ"
            echo " 5) 💾 YABS — Тест производительности процессора и скорости диска (fio)"
            echo " 6) 📡 IP Check Place — Проверка качества и репутационного скора IP"
            echo " 7) 📊 bench.sh — Классический тест параметров железа и сети"
            echo " 8) 🔥 sysbench CPU — Локальный стресс-тест вычислительных ядер"
            echo " 9) 🧠 sysbench Memory — Стресс-тест скорости оперативной памяти"
            echo " 10) 🗺️  Проверка пинга и маршрута (Traceroute) до yandex.ru"
            echo " 99) 🚀 Запустить ВСЕ доступные тесты по очереди"
            echo " 0) Назад"
            echo -e "${GRAY}--------------------------------------------------${NC}"
            read -p "Выберите действие [0-99]: " test_choice
            test_choice=${test_choice:-0}

            case $test_choice in
                1)
                    clear
                    echo -e "${BLUE}🌍 Проверка локации IP и провайдера...${NC}\n"
                    curl -fsSL --proto '=https' --tlsv1.2 https://ipapi.co/json 2>/dev/null | jq '.' || \
                    curl -fsSL --proto '=https' --tlsv1.2 https://ipinfo.io 2>/dev/null || echo "Ошибка получения данных."
                    pause_prompt
                    ;;
                2)
                    clear
                    run_verified_benchmark "Censorcheck (Геоблоки)" "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" "--mode geoblock"
                    pause_prompt
                    ;;
                3)
                    clear
                    run_verified_benchmark "Censorcheck (DPI Тест)" "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" "--mode dpi"
                    pause_prompt
                    ;;
                4)
                    clear
                    echo -e "${INFO} Установка iperf3 для запуска теста скорости..."
                    apt-get install -y -qq iperf3 >> "$LOG_FILE" 2>&1 || true
                    run_verified_benchmark "iPerf3 RU Speedtest" "https://github.com/itdoginfo/russian-iperf3-servers/raw/main/speedtest.sh"
                    pause_prompt
                    ;;
                5)
                    clear
                    run_verified_benchmark "YABS (Yet Another Bench Script)" "https://yabs.sh" "-4"
                    pause_prompt
                    ;;
                6)
                    clear
                    run_verified_benchmark "IP Check Place" "https://ip.check.place/script/check.sh" "-l ru"
                    pause_prompt
                    ;;
                7)
                    clear
                    run_verified_benchmark "bench.sh" "https://bench.sh"
                    pause_prompt
                    ;;
                8)
                    clear
                    echo -e "${BLUE}🔥 Стресс-тест процессора через sysbench CPU...${NC}\n"
                    if ! command -v sysbench &>/dev/null; then
                        echo -e "${INFO} Установка sysbench для проведения стресс-тестов..."
                        apt-get install -y -qq sysbench >> "$LOG_FILE" 2>&1 || true
                    fi
                    if command -v sysbench &>/dev/null; then
                        sysbench cpu --cpu-max-prime=20000 run
                    else
                        echo -e "${ERROR} Не удалось установить sysbench."
                    fi
                    pause_prompt
                    ;;
                9)
                    clear
                    echo -e "${BLUE}🧠 Стресс-тест оперативной памяти через sysbench Memory...${NC}\n"
                    if ! command -v sysbench &>/dev/null; then
                        echo -e "${INFO} Установка пакета sysbench..."
                        apt-get install -y -qq sysbench >> "$LOG_FILE" 2>&1 || true
                    fi
                    if command -v sysbench &>/dev/null; then
                        sysbench memory run
                    else
                        echo -e "${ERROR} Не удалось установить sysbench."
                    fi
                    pause_prompt
                    ;;
                10)
                    clear
                    echo -e "${BLUE}🗺️  Проверка пинга и маршрута до yandex.ru...${NC}\n"
                    if ! command -v traceroute &>/dev/null; then
                        echo -e "${INFO} Установка пакета traceroute..."
                        apt-get install -y -qq traceroute >> "$LOG_FILE" 2>&1 || true
                    fi
                    echo -e "\n${BLUE}Выполнение Ping (4 пакета):${NC}"
                    ping -c 4 yandex.ru || true
                    if command -v traceroute &>/dev/null; then
                        echo -e "\n${BLUE}Выполнение Traceroute (макс. 20 хопов):${NC}"
                        traceroute -m 20 yandex.ru || true
                    fi
                    pause_prompt
                    ;;
                99)
                    clear
                    echo -e "${BLUE}🚀 Запуск ВСЕХ тестов по очереди (это может занять несколько минут)...${NC}\n"
                    
                    # 1. IP
                    echo -e "\n🌍 --- Геолокация IP ---"
                    curl -fsSL --proto '=https' --tlsv1.2 https://ipapi.co/json 2>/dev/null | jq '.' || true
                    # 2. Censorcheck Geoblock
                    run_verified_benchmark "Censorcheck (Геоблоки)" "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" "--mode geoblock"
                    # 3. Censorcheck DPI
                    run_verified_benchmark "Censorcheck (DPI Тест)" "https://github.com/vernette/censorcheck/raw/master/censorcheck.sh" "--mode dpi"
                    # 4. YABS
                    run_verified_benchmark "YABS (Yet Another Bench Script)" "https://yabs.sh" "-4"
                    # 5. IP check place
                    run_verified_benchmark "IP Check Place" "https://ip.check.place/script/check.sh" "-l ru"
                    # 6. sysbench CPU
                    if command -v sysbench &>/dev/null || apt-get install -y -qq sysbench &>>"$LOG_FILE"; then
                        sysbench cpu --cpu-max-prime=15000 run || true
                    fi
                    # 7. Ping
                    ping -c 4 yandex.ru || true
                    
                    log "${SUCCESS} Все тесты успешно завершены!"
                    pause_prompt
                    ;;
                0)
                    return
                    ;;
            esac
        done
    )
}

# --- Функция паузы в меню ---
pause_prompt() {
    echo ""
    read -p "Нажмите Enter, чтобы вернуться в меню..." _
}

# --- ИНТЕРАКТИВНЫЕ ДЕЙСТВИЯ МЕНЮ ---

# 1) Первоначальная настройка ноды
run_initial_setup() {
    clear
    log "${INFO} Запуск первоначальной настройки и установки ноды..."
    
    # Сбрасываем старые файлы портов если есть
    mkdir -p "$APP_DIR"
    rm -f "$APP_DIR/.xray_ports"
    
    # Настройки оптимизации и зависимости
    optimize_network
    install_dependencies
    
    # Выбор версии Xray-core
    select_xray_version
    
    # Настройка логов и ротации
    setup_logging_and_rotation
    
    # Запрос данных для связи с панелью
    echo -e "\n${BLUE}🔌 НАСТРОЙКА ИДЕНТИФИКАЦИИ И СВЯЗИ С ПАНЕЛЬЮ${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    read -p "Введите IP адрес панели Remnawave (для настройки UFW): " panel_ip
    while [[ ! "$panel_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
        read -p "${RED}Неверный формат IP. Введите корректный IPv4 панели: ${NC}" panel_ip
    done
    
    read -p "Введите домен вашей ноды (например, node.example.com): " node_domain
    while [ -z "$node_domain" ]; do
        read -p "${RED}Домен ноды не может быть пустым: ${NC}" node_domain
    done
    NODE_DOMAIN="$node_domain"

    read -p "Порт управления нодой (для панели) [2222]: " node_port
    node_port=${node_port:-2222}
    
    echo -e "\n${YELLOW}Вставьте сертификат ноды, выданный в панели Remnawave${NC}"
    echo -e "${GRAY}(Для окончания ввода нажмите Enter дважды подряд):${NC}"
    local certificate=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$certificate" ]; then
                break
            fi
        else
            certificate="${certificate}${line}\n"
        fi
    done
    
    local secret_key_value; secret_key_value=$(echo -e "$certificate" | xargs)
    while [ -z "$secret_key_value" ]; do
        log "${ERROR} Сертификат не может быть пустым!"
        exit 1
    done

    # Запрос кастомных входящих портов Xray во время установки
    echo -e "\n${BLUE}⚙️  ВХОДЯЩИЕ ПОРТЫ ДЛЯ КЛИЕНТОВ XRAY${NC}"
    echo -e "По умолчанию порты 80 и 443 будут открыты автоматически."
    read -p "Желаете открыть дополнительные входящие порты для Xray в UFW? (через пробел, например: 8443 2053) [Нет]: " add_ports_choice
    add_ports_choice=${add_ports_choice:-""}
    if [ -n "$add_ports_choice" ]; then
        local clean_ports; clean_ports=$(echo "$add_ports_choice" | tr ',' ' ' | xargs)
        for p in $clean_ports; do
            if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
                echo "$p" >> "$APP_DIR/.xray_ports"
                log "${SUCCESS} Порт $p добавлен в список автооткрытия."
            fi
        done
    fi

    # Выбор протокола шифрования
    echo -e "\nВыберите тип шифрования клиентского трафика:"
    echo " 1) VLESS Reality (маскировочный сайт / Selfsteal)"
    echo " 2) VLESS+TLS (классический TLS с вашим доменом ноды)"
    echo " 3) VLESS+TLS+xHTTP (новый высокопроизводительный транспортный протокол Xray)"
    read -p "Ваш выбор [1]: " proto_choice
    proto_choice=${proto_choice:-1}
    
    local protocol="reality"
    if [ "$proto_choice" -eq 2 ]; then
        protocol="tls"
    elif [ "$proto_choice" -eq 3 ]; then
        protocol="xhttp"
    fi
    
    # Скачивание и генерация маскировочного сайта SelfSteal
    if [ "$protocol" = "reality" ]; then
        read -p "Домен маскировки (decoy domain) [github.com]: " decoy_domain
        DECOY_DOMAIN=${decoy_domain:-github.com}
        generate_masked_template "$DECOY_DOMAIN"
    else
        # Для TLS генерируем маскировку под собственный домен ноды (для fallback)
        generate_masked_template "$NODE_DOMAIN"
        # Выпуск легитимного SSL
        issue_ssl_certificates_multi "$NODE_DOMAIN"
    fi
    
    # Генерация docker-compose и запуск
    deploy_compose "$protocol" "$node_port" "$secret_key_value"
    configure_firewall "$node_port" "$panel_ip"
    
    # Сохраняем метаданные для последующего использования в меню
    echo "$panel_ip" > "$APP_DIR/.panel_ip"
    echo "$protocol" > "$APP_DIR/.protocol"
    echo "$NODE_DOMAIN" > "$APP_DIR/.node_domain"
    
    # Создание глобальной ссылки на этот скрипт во избежание утери
    local script_path; script_path=$(readlink -f "$0")
    ln -sf "$script_path" "/usr/local/bin/remnanode" &>/dev/null || cp "$script_path" "/usr/local/bin/remnanode" &>/dev/null
    chmod +x "/usr/local/bin/remnanode" 2>/dev/null || true
    
    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "🎉   УСТАНОВКА И НАСТРОЙКА НОДЫ УСПЕШНО ЗАВЕРШЕНА!   🎉"
    echo -e "Вы можете запускать это меню командой: ${CYAN}remnanode${NC}"
    echo -e "${GREEN}========================================================${NC}"
    
    pause_prompt
}

# 2) Выпуск и обновление SSL при смене домена ноды
change_domain_and_ssl() {
    clear
    echo -e "${BLUE}🔐 СМЕНА ДОМЕНА НОДЫ И ПЕРЕВЫПУСК SSL${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        log "${ERROR} Нода еще не установлена! Пожалуйста, выполните первоначальную настройку."
        pause_prompt
        return
    fi
    
    read -p "Введите новый домен вашей ноды: " new_domain
    while [ -z "$new_domain" ]; do
        read -p "${RED}Домен не может быть пустым: ${NC}" new_domain
    done
    NODE_DOMAIN="$new_domain"
    echo "$NODE_DOMAIN" > "$APP_DIR/.node_domain"
    
    # Читаем конфигурации из существующих файлов
    local node_port; node_port=$(grep "NODE_PORT" "$APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    local secret_key_value; secret_key_value=$(grep "SECRET_KEY" "$APP_DIR/.env" | cut -d'=' -f2- | xargs || echo "")
    local protocol; protocol=$(cat "$APP_DIR/.protocol" 2>/dev/null || echo "tls")
    
    # Перегенерируем маскировочный сайт в любом случае
    generate_masked_template "$NODE_DOMAIN"

    if [ "$protocol" = "tls" ] || [ "$protocol" = "xhttp" ]; then
        issue_ssl_certificates_multi "$NODE_DOMAIN"
    fi
    
    # Перевыпускаем конфигурацию
    deploy_compose "$protocol" "$node_port" "$secret_key_value"
    
    log "${SUCCESS} Домен ноды успешно изменен на $NODE_DOMAIN, конфигурация обновлена!"
    pause_prompt
}

# 3) Установка кастомной версии Xray Core
update_xray_core_only() {
    clear
    echo -e "${BLUE}⚡ УСТАНОВКА/ОБНОВЛЕНИЕ КАСТОМНОЙ ВЕРСИИ XRAY-CORE${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        log "${ERROR} Нода еще не установлена! Пожалуйста, выполните первоначальную настройку."
        pause_prompt
        return
    fi
    
    # Выбор и загрузка
    select_xray_version
    
    # Читаем конфигурации для перегенерации compose
    local node_port; node_port=$(grep "NODE_PORT" "$APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    local secret_key_value; secret_key_value=$(grep "SECRET_KEY" "$APP_DIR/.env" | cut -d'=' -f2- | xargs || echo "")
    local protocol; protocol=$(cat "$APP_DIR/.protocol" 2>/dev/null || echo "reality")
    NODE_DOMAIN=$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo "localhost")
    
    deploy_compose "$protocol" "$node_port" "$secret_key_value"
    
    log "${SUCCESS} Версия Xray-Core успешно обновлена!"
    pause_prompt
}

# 4) Смена IP панели
change_panel_ip() {
    clear
    echo -e "${BLUE}🔌 СМЕНА IP АДРЕСА ПАНЕЛИ (UFW RULE UPDATE)${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
        log "${ERROR} Нода еще не установлена!"
        pause_prompt
        return
    fi
    
    local old_panel_ip; old_panel_ip=$(cat "$APP_DIR/.panel_ip" 2>/dev/null || echo "")
    log "${INFO} Текущий разрешенный IP панели: ${YELLOW}${old_panel_ip:-Не определен}${NC}"
    
    read -p "Введите новый IP адрес панели: " new_panel_ip
    while [[ ! "$new_panel_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; do
        read -p "${RED}Неверный формат IP. Введите корректный IPv4: ${NC}" new_panel_ip
    done
    
    local node_port; node_port=$(grep "NODE_PORT" "$APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")
    
    # Недеструктивное удаление старого правила
    if [ -n "$old_panel_ip" ]; then
        log "${INFO} Удаление старого правила UFW для IP панели: ${YELLOW}$old_panel_ip${NC}"
        ufw delete allow from "$old_panel_ip" to any port "$node_port" proto tcp >> "$LOG_FILE" 2>&1 || true
    fi
    
    # Добавление правила для нового IP панели
    log "${INFO} Добавление правила UFW для нового IP панели: ${GREEN}$new_panel_ip${NC}"
    ufw allow from "$new_panel_ip" to any port "$node_port" proto tcp comment 'Remnanode Control from Panel' >> "$LOG_FILE" 2>&1
    ufw reload >> "$LOG_FILE" 2>&1
    
    # Сохраняем новый IP
    echo "$new_panel_ip" > "$APP_DIR/.panel_ip"
    
    log "${SUCCESS} Разрешенный IP панели изменен на $new_panel_ip. Порт $node_port защищен UFW!"
    pause_prompt
}

# 5) Управление IPv6
manage_ipv6_menu() {
    clear
    echo -e "${BLUE}🌐 УПРАВЛЕНИЕ IPV6 В СИСТЕМЕ${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    
    # Проверка текущего статуса
    local ipv6_disabled; ipv6_disabled=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo "0")
    if [ "$ipv6_disabled" -eq 1 ]; then
        echo -e "Текущий статус IPv6: ${RED}ОТКЛЮЧЕН${NC}"
    else
        echo -e "Текущий статус IPv6: ${GREEN}ВКЛЮЧЕН${NC}"
    fi
    echo -e "${GRAY}--------------------------------------------------${NC}"
    echo " 1) Полностью отключить IPv6 (рекомендуется для избежания утечек)"
    echo " 2) Включить IPv6 обратно"
    echo " 0) Назад"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -p "Выберите действие [0-2]: " ipv6_choice
    ipv6_choice=${ipv6_choice:-0}
    
    case $ipv6_choice in
        1)
            cat > /etc/sysctl.d/99-remnanode-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
            sysctl -p /etc/sysctl.d/99-remnanode-ipv6.conf >> "$LOG_FILE" 2>&1 || true
            log "${SUCCESS} IPv6 успешно отключен в системе!"
            pause_prompt
            ;;
        2)
            rm -f /etc/sysctl.d/99-remnanode-ipv6.conf
            sysctl --system >> "$LOG_FILE" 2>&1 || true
            log "${SUCCESS} IPv6 успешно включен обратно!"
            pause_prompt
            ;;
        0)
            return
            ;;
    esac
}

# 6) Полное удаление ноды с откатом изменений
uninstall_and_rollback() {
    clear
    echo -e "${RED}⚠️  ВНИМАНИЕ! ПОЛНОЕ УДАЛЕНИЕ НОДЫ И ОТКАТ СИСТЕМЫ${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    echo -e "${RED}Это действие полностью остановит ноду, сотрет все конфигурационные файлы,${NC}"
    echo -e "${RED}логи, маскировочные сайты, Docker-образы и вернет брандмауэр UFW/оптимизации в исходное состояние.${NC}"
    echo -e "${GRAY}--------------------------------------------------${NC}"
    read -p "Вы уверены, что хотите продолжить? (y/N): " confirm
    if [[ ! $confirm =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Удаление отменено.${NC}"
        sleep 1
        return
    fi
    
    log "${INFO} Остановка контейнеров Docker..."
    if [ -f "$APP_DIR/docker-compose.yml" ]; then
        cd "$APP_DIR"
        docker compose down -v >> "$LOG_FILE" 2>&1 || true
        
        # Динамически извлекаем и удаляем все скачанные образы Docker (images) из compose файла
        log "${INFO} Извлечение и динамическое удаление образов Docker..."
        local images; images=$(grep -E '^[[:space:]]*image:' "$APP_DIR/docker-compose.yml" | awk '{print $2}' | tr -d '"' | tr -d "'")
        for img in $images; do
            log "${INFO} Удаление образа Docker: ${CYAN}$img${NC}"
            docker rmi "$img" >> "$LOG_FILE" 2>&1 || true
        done
    fi
    
    log "${INFO} Удаление системных оптимизаций sysctl и лимитов..."
    rm -f /etc/sysctl.d/99-remnanode.conf
    rm -f /etc/sysctl.d/99-remnanode-ipv6.conf
    rm -f /etc/security/limits.d/99-remnanode.conf
    sysctl --system >> "$LOG_FILE" 2>&1 || true
    
    log "${INFO} Сброс и деактивация брандмауэра UFW..."
    if command -v ufw &>/dev/null; then
        ufw --force reset >> "$LOG_FILE" 2>&1 || true
    fi
    
    log "${INFO} Очистка файлов и каталогов..."
    rm -rf "$APP_DIR"
    rm -rf "$LOG_DIR"
    rm -rf "$WWW_DIR"
    rm -f /etc/logrotate.d/remnanode
    rm -f /etc/letsencrypt/renewal-hooks/deploy/copy-remnanode-certs.sh
    rm -f /usr/local/bin/remnanode
    
    echo -e "\n${GREEN}========================================================${NC}"
    echo -e "${SUCCESS} Нода Remnanode и её Docker-образы успешно удалены!"
    echo -e "Все сетевые и системные параметры возвращены в исходное состояние."
    echo -e "${GREEN}========================================================${NC}\n"
    
    exit 0
}

# 7)  Диагностика и просмотр логов (в стиле DigneZzZ/remnawave-scripts)
diagnose_and_logs() {
    # Создаем подоболочку (subshell) с отключенным строгим режимом во избежание сбоев из-за локалей или отсутствия файлов
    (
        set +e
        set +o pipefail

        while true; do
            clear
            echo -e "${GREEN}"
            echo "  ========================================================"
            echo "  📊 ДИАГНОСТИКА И ПРОСМОТР ЛОГОВ НОДЫ"
            echo "  ========================================================"
            echo -e "${NC}"
            
            if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
                echo -e "${RED} Нода еще не установлена! Логи недоступны.${NC}"
                pause_prompt
                return
            fi

            # 1. Проверка системных ресурсов
            echo -e "📌 ${WHITE}Ресурсы сервера:${NC}"
            
            # Локале-независимый расчет CPU через ps
            local cpu_use; cpu_use=$(ps -eo pcpu 2>/dev/null | awk 'NR>1 {sum+=$1} END {print sum}')
            if [ -z "$cpu_use" ] || [ "$cpu_use" = "0" ]; then
                cpu_use="Недоступно"
            else
                local cores; cores=$(nproc 2>/dev/null || echo 1)
                cpu_use=$(awk "BEGIN {print int($cpu_use/$cores)}")"%"
            fi
            
            local mem_info; mem_info=$(free -h 2>/dev/null | grep "Mem:")
            local mem_used; mem_used=$(echo "$mem_info" | awk '{print $3}' || echo "N/A")
            local mem_total; mem_total=$(echo "$mem_info" | awk '{print $2}' || echo "N/A")
            local mem_use="${mem_used} / ${mem_total}"
            
            local disk_use; disk_use=$(df -h "$APP_DIR" 2>/dev/null | tail -1 | awk '{print $5 " (Свободно " $4 ")"}' || echo "Недоступно")
            
            echo -e "   - Загрузка CPU:     ${CYAN}$cpu_use${NC}"
            echo -e "   - Использование ОЗУ: ${CYAN}$mem_use${NC}"
            echo -e "   - Занято на диске:   ${CYAN}$disk_use${NC}"
            
            # 2. Проверка статуса докеров
            echo -e "\n📌 ${WHITE}Статус Docker контейнеров:${NC}"
            local node_status="${RED}○ Остановлен${NC}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnanode"; then
                node_status="${GREEN}● Запущен${NC}"
            fi
            
            local nginx_status="${RED}○ Остановлен${NC}"
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "remnawave-nginx"; then
                nginx_status="${GREEN}● Запущен${NC}"
            fi
            
            echo -e "   - remnanode:        $node_status"
            echo -e "   - remnawave-nginx:  $nginx_status"
            
            # 3. Вес файлов логов на хосте
            echo -e "\n📌 ${WHITE}Размер лог-файлов на хосте:${NC}"
            local node_acc_size; node_acc_size=$(du -sh "$LOG_DIR/node/xray.out.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local node_err_size; node_err_size=$(du -sh "$LOG_DIR/node/xray.err.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local nginx_acc_size; nginx_acc_size=$(du -sh "$LOG_DIR/nginx/access.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            local nginx_err_size; nginx_err_size=$(du -sh "$LOG_DIR/nginx/error.log" 2>/dev/null | awk '{print $1}' || echo "0B")
            
            echo -e "   - Xray access.log:  ${CYAN}$node_acc_size${NC}"
            echo -e "   - Xray error.log:   ${CYAN}$node_err_size${NC}"
            echo -e "   - Nginx access.log:  ${CYAN}$nginx_acc_size${NC}"
            echo -e "   - Nginx error.log:   ${CYAN}$nginx_err_size${NC}"
            
            echo -e "${GRAY}--------------------------------------------------${NC}"
            echo " 1) 📥 Лог запросов Xray (access.log) в реальном времени"
            echo " 2) 📥 Лог ошибок Xray (error.log) в реальном времени"
            echo " 3) 📥 Лог запросов веб-сервера Nginx в реальном времени"
            echo " 4) 📥 Вывод логов из контейнера Docker (remnanode)"
            echo " 5) 🔄 Вынужденно применить ротацию логов (logrotate)"
            echo " 0) Назад"
            echo -e "${GRAY}--------------------------------------------------${NC}"
            read -p "Выберите действие [0-5]: " log_choice
            log_choice=${log_choice:-0}
            
            case $log_choice in
                1)
                    clear
                    echo -e "${BLUE}Показ лога access.log (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$LOG_DIR/node/xray.out.log" || true
                    ;;
                2)
                    clear
                    echo -e "${BLUE}Показ лога error.log (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$LOG_DIR/node/xray.err.log" || true
                    ;;
                3)
                    clear
                    echo -e "${BLUE}Показ лога Nginx (Выход: Ctrl+C)...${NC}\n"
                    tail -n 100 -f "$LOG_DIR/nginx/access.log" || true
                    ;;
                4)
                    clear
                    echo -e "${BLUE}Показ Docker-логов remnanode (Выход: Ctrl+C)...${NC}\n"
                    docker compose -f "$APP_DIR/docker-compose.yml" logs -f --tail=100 || true
                    ;;
                5)
                    echo -e "${INFO} Запуск принудительной ротации логов..."
                    if logrotate -f /etc/logrotate.d/remnanode; then
                        echo -e "${SUCCESS} Ротация логов успешно выполнена!"
                    else
                        echo -e "${ERROR} Ошибка выполнения ротации!"
                    fi
                    sleep 1.5
                    ;;
                0)
                    return
                    ;;
            esac
        done
    )
}

# --- Управление кастомными портами Xray Core и правилами UFW ---
manage_xray_ports() {
    while true; do
        clear
        echo -e "${GREEN}"
        echo "  ========================================================"
        echo "  🔌 УПРАВЛЕНИЕ КЛИЕНТСКИМИ ПОРТАМИ XRAY И UFW"
        echo "  ========================================================"
        echo -e "${NC}"
        
        if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
            log "${ERROR} Нода еще не установлена! Управление портами недоступно."
            pause_prompt
            return
        fi

        # Чтение текущего открытого IP панели и порта управления нодой
        local panel_ip; panel_ip=$(cat "$APP_DIR/.panel_ip" 2>/dev/null || echo "Не определен")
        local node_port; node_port=$(grep "NODE_PORT" "$APP_DIR/.env" | cut -d'=' -f2 | xargs || echo "2222")

        echo -e "📌 ${WHITE}Базовые порты ноды:${NC}"
        echo -e "   - Port управления нодой:  ${CYAN}$node_port${NC} (Открыт в UFW только для IP панели: ${GREEN}$panel_ip${NC})"
        echo -e "   - Стандартные веб-порты:   ${CYAN}80, 443${NC} (Всегда открыты глобально для входящего трафика)"

        # Вывод кастомных портов
        echo -e "\n📌 ${WHITE}Список кастомных входящих портов Xray в UFW:${NC}"
        if [ -f "$APP_DIR/.xray_ports" ] && [ -s "$APP_DIR/.xray_ports" ]; then
            local current_ports; current_ports=$(cat "$APP_DIR/.xray_ports" | tr '\n' ' ' | xargs)
            for port in $current_ports; do
                echo -e "   - Port: ${GREEN}$port${NC} (UFW: Разрешен TCP/UDP входящий)"
            done
        else
            echo -e "   ${GRAY}Список пуст. Кастомные клиентские порты не настроены.${NC}"
        fi

        echo -e "${GRAY}--------------------------------------------------${NC}"
        echo " 1) ➕ Добавить новый клиентский порт / диапазон портов Xray в UFW"
        echo " 2) ➖ Удалить порт / диапазон из списка разрешенных"
        echo " 3) 🔄 Принудительно перезагрузить правила брандмауэра (UFW reload)"
        echo " 0) Назад"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -p "Выберите действие [0-3]: " port_action
        port_choice=${port_action:-0}

        case $port_choice in
            1)
                echo -e "\n${BLUE}Добавление нового клиентского порта:${NC}"
                read -p "Введите номер порта или диапазон (например, 8443 или 2000:2010): " input_port
                
                # Валидация ввода (только цифры или диапазон с двоеточием)
                if [[ "$input_port" =~ ^[0-9]+$ || "$input_port" =~ ^[0-9]+:[0-9]+$ ]]; then
                    # Проверяем на дубликаты
                    if [ -f "$APP_DIR/.xray_ports" ] && grep -Fxq "$input_port" "$APP_DIR/.xray_ports"; then
                        log "${WARNING} Порт ${YELLOW}$input_port${NC} уже есть в списке."
                    else
                        echo "$input_port" >> "$APP_DIR/.xray_ports"
                        
                        # Моментальное открытие в UFW
                        log "${INFO} Открытие в UFW кастомного порта: ${CYAN}$input_port${NC}"
                        ufw allow "$input_port"/tcp comment 'Xray Custom Port TCP' >> "$LOG_FILE" 2>&1
                        ufw allow "$input_port"/udp comment 'Xray Custom Port UDP' >> "$LOG_FILE" 2>&1
                        ufw reload >> "$LOG_FILE" 2>&1
                        
                        log "${SUCCESS} Port $input_port успешно добавлен и разрешен в UFW!"
                    fi
                else
                    log "${ERROR} Неверный формат порта. Введите число (например, 8443) или диапазон (например, 3000:3010)."
                fi
                sleep 1.5
                ;;
            2)
                if [ ! -f "$APP_DIR/.xray_ports" ] || [ ! -s "$APP_DIR/.xray_ports" ]; then
                    log "${WARNING} Список кастомных портов пуст."
                    sleep 1.5
                    continue
                fi

                echo -e "\n${BLUE}Удаление клиентского порта:${NC}"
                read -p "Введите точный порт/диапазон для удаления: " del_port

                if grep -Fxq "$del_port" "$APP_DIR/.xray_ports"; then
                    # Удаляем из нашего файла
                    sed -i "/^$del_port$/d" "$APP_DIR/.xray_ports"
                    
                    # Закрываем в UFW
                    log "${INFO} Удаление правил UFW для порта: ${CYAN}$del_port${NC}"
                    ufw delete allow "$del_port"/tcp >> "$LOG_FILE" 2>&1 || true
                    ufw delete allow "$del_port"/udp >> "$LOG_FILE" 2>&1 || true
                    ufw reload >> "$LOG_FILE" 2>&1
                    
                    log "${SUCCESS} Порт $del_port успешно удален из конфигов и закрыт в UFW!"
                else
                    log "${ERROR} Порт $del_port не найден в списке."
                fi
                sleep 1.5
                ;;
            3)
                log "${INFO} Перезапуск брандмауэра UFW..."
                # Принудительно вызываем полную перенастройку UFW для исключения рассинхронизации
                configure_firewall "$node_port" "$panel_ip"
                log "${SUCCESS} Правила фаервола успешно синхронизированы!"
                sleep 1.5
                ;;
            0)
                return
                ;;
        esac
    done
}

# 9) Управление маскировочными шаблонами Selfsteal (с возможностью рандома и выбора конкретного)
change_decoy_template_menu() {
    while true; do
        clear
        echo -e "${GREEN}"
        echo "  ========================================================"
        echo "  🎭 СМЕНА МАСКИРОВОЧНОГО ШАБЛОНА САЙТА (SELFSTEAL)"
        echo "  ========================================================"
        echo -e "${NC}"
        
        if [ ! -f "$APP_DIR/docker-compose.yml" ]; then
            log "${ERROR} Нода еще не установлена! Маскировка недоступна."
            pause_prompt
            return
        fi
        
        local node_domain; node_domain=$(cat "$APP_DIR/.node_domain" 2>/dev/null || echo "localhost")
        
        echo -e "📌 Домен вашей ноды: ${CYAN}$node_domain${NC}"
        echo -e "--------------------------------------------------------"
        echo " 1) 🔄 Сменить шаблон на СЛУЧАЙНЫЙ (Рандомно)"
        echo " 2) 🎨 Выбрать КОНКРЕТНЫЙ шаблон из списка"
        echo " 0) Назад"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -p "Выберите действие [0-2]: " temp_choice
        temp_choice=${temp_choice:-0}
        
        local templates=("endless-verify" "esports-stream-template" "levelup-hub" "playza-game-catalog" "rybaliti-2.0" "screenwire-digest" "vibrai-photo-editor" "worldzoo-stream-template")
        local templates_ru=("Страница верификации (endless-verify)" "Киберспортивный портал (esports-stream-template)" "Игровой хаб для геймеров (levelup-hub)" "Каталог онлайн-игр (playza-game-catalog)" "Блог/Форум о рыбалке (rybaliti-2.0)" "Новостной IT-дайджест (screenwire-digest)" "Онлайн-фоторедактор (vibrai-photo-editor)" "Стримы из зоопарков (worldzoo-stream-template)")
        
        case $temp_choice in
            1)
                generate_masked_template "$node_domain"
                docker restart remnawave-nginx >> "$LOG_FILE" 2>&1 || true
                log "${SUCCESS} Маскировочный шаблон успешно изменен на случайный и перезапущен!"
                pause_prompt
                ;;
            2)
                echo -e "\n${BLUE}Доступные профессиональные шаблоны:${NC}"
                for i in "${!templates[@]}"; do
                    echo -e " $((i+1))) ${templates_ru[$i]}"
                done
                echo -e "${GRAY}--------------------------------------------------${NC}"
                read -p "Выберите номер шаблона [1]: " template_num
                template_num=${template_num:-1}
                local index=$((template_num - 1))
                
                if [ $index -ge 0 ] && [ $index -lt ${#templates[@]} ]; then
                    local chosen="${templates[$index]}"
                    generate_masked_template "$node_domain" "$chosen"
                    docker restart remnawave-nginx >> "$LOG_FILE" 2>&1 || true
                    log "${SUCCESS} Маскировочный сайт успешно изменен на '${chosen}' и перезапущен!"
                else
                    log "${ERROR} Неверный номер шаблона."
                fi
                pause_prompt
                ;;
            0)
                return
                ;;
        esac
    done
}

# --- Главное интерактивное меню ---
main_menu() {
    while true; do
        clear
        echo -e "${GREEN}"
        echo "  ========================================================"
        echo "  🚀 REMNANODE ИНТЕРАКТИВНОЕ УПРАВЛЕНИЕ НОДОЙ (v1.7.2)"
        echo "  ========================================================"
        echo -e "${NC}"
        
        # Определение текущего статуса ноды
        local status="Не установлена"
        local color="$RED"
        if [ -f "$APP_DIR/docker-compose.yml" ]; then
            if docker ps | grep -q "remnanode"; then
                status="Активна (Запущена)"
                color="$GREEN"
            else
                status="Установлена (Остановлена)"
                color="$YELLOW"
            fi
        fi
        
        echo -e "📌 Текущий статус ноды: ${color}${status}${NC}"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        echo " 1) 🚀 Первоначальная настройка и запуск ноды"
        echo " 2) 🔐 Выпуск и обновление SSL при смене домена ноды"
        echo " 3) ⚡ Установка/Обновление кастомной версии Xray-Core"
        echo " 4) 🔌 Смена IP адреса панели (Обновление правил UFW)"
        echo " 5) 🌐 Управление IPv6 (Вкл / Откл)"
        echo " 6) 🗑️  Полное удаление ноды с откатом всех изменений"
        echo " 7) 📊 Диагностика и просмотр логов ноды"
        echo " 8) 🔌 Управление клиентскими портами Xray и UFW"
        echo " 9) 🎭 Смена маскировочного шаблона сайта (Selfsteal)"
        echo " 10) 🧪 Запустить мульти-тесты и диагностику сервера (YABS/DPI)"
        echo " 0) Выход"
        echo -e "${GRAY}--------------------------------------------------${NC}"
        read -p "Выберите действие [0-10]: " menu_choice
        menu_choice=${menu_choice:-0}
        
        case $menu_choice in
            1) run_initial_setup ;;
            2) change_domain_and_ssl ;;
            3) update_xray_core_only ;;
            4) change_panel_ip ;;
            5) manage_ipv6_menu ;;
            6) uninstall_and_rollback ;;
            7) diagnose_and_logs ;;
            8) manage_xray_ports ;;
            9) change_decoy_template_menu ;;
            10) run_server_multitests ;;
            0) exit 0 ;;
            *) echo -e "${RED}Неверный выбор.${NC}"; sleep 1 ;;
        esac
    done
}

# --- Главная точка входа ---
main() {
    check_root
    check_os
    detect_arch
    
    # Автоматическая принудительная регистрация CLI-оболочки при запуске
    register_globally
    
    # Сразу запускаем интерактивное меню
    main_menu
}

main
