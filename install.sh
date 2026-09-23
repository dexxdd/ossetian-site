#!/bin/bash
set -e

# ==============================================================
# Скрипт автоматического развертывания VLESS-XHTTP + 3X-UI + Заглушка
# Репозиторий сайта: https://github.com/dexxdd/ossetian-site
# ==============================================================

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
  echo "[-] Ошибка: запустите скрипт от root (sudo bash)!"
  exit 1
fi

clear
echo "=========================================================================="
echo "    АВТОМАТИЧЕСКАЯ УСТАНОВКА 3X-UI + VLESS XHTTP + САЙТ-ЗАГЛУШКА          "
echo "=========================================================================="
echo ""

# Читаем домен из аргументов или терминала
if [ -n "$1" ]; then
  DOMAIN="$1"
else
  printf "Введите ваш домен (например, your-domain.org): "
  read -r DOMAIN < /dev/tty
fi

DOMAIN=$(echo "$DOMAIN" | tr -d '[:space:]')

if [ -z "$DOMAIN" ]; then
  echo "[-] Ошибка: домен не указан! Прерывание."
  exit 1
fi

# Определение IP админа из текущего SSH-подключения
CURRENT_ADMIN_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
if [ -z "$CURRENT_ADMIN_IP" ]; then
  CURRENT_ADMIN_IP=$(who am i 2>/dev/null | awk '{print $5}' | tr -d '()')
fi

echo ""
echo "--------------------------------------------------------------------------"
echo "        НАСТРОЙКА БЕЛОГО СПИСКА ФАЕРВОЛА ДЛЯ АДМИН-ПАНЕЛИ 3X-UI           "
echo "--------------------------------------------------------------------------"
if [ -n "$CURRENT_ADMIN_IP" ]; then
  echo " [+] Ваш текущий IP-адрес подключения (SSH): $CURRENT_ADMIN_IP"
else
  echo " [!] Не удалось автоматически определить ваш IP-адрес подключения."
fi
echo ""
echo " Формат ввода:"
if [ -n "$CURRENT_ADMIN_IP" ]; then
  echo " • Разрешить вход только с вашего текущего IP ($CURRENT_ADMIN_IP):"
  echo "   👉 Просто нажмите [Enter]"
  echo ""
fi
echo " • Указать один или несколько своих IP/подсетей через запятую:"
echo "   👉 Пример: 203.0.113.195, 198.51.100.0/24"
echo ""
echo " • Открыть вход в панель со всех IP мира (без белого списка):"
echo "   👉 Напишите: all"
echo "--------------------------------------------------------------------------"

if [ -n "$CURRENT_ADMIN_IP" ]; then
  printf " Введите IP/подсети [нажмите Enter для %s]: " "$CURRENT_ADMIN_IP"
  read -r INPUT_IPS < /dev/tty
  WHITELIST_IPS="${INPUT_IPS:-$CURRENT_ADMIN_IP}"
else
  printf " Введите IP/подсети через запятую (или 'all'): "
  read -r WHITELIST_IPS < /dev/tty
fi

echo ""
echo "[+] Выбранный домен: $DOMAIN"
echo "[+] Белый список панели: $WHITELIST_IPS"
echo "[+] Определение внешнего IP сервера..."
SERVER_IP=$(curl -s4 icanhazip.com || curl -s4 ifconfig.me || curl -s4 api.ipify.org)
echo "[+] IP сервера: $SERVER_IP"
echo ""

echo "[1/6] Обновление пакетов и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget git nginx certbot jq sqlite3 ufw uuid-runtime qrencode python3

echo "[2/6] Получение SSL-сертификата Let's Encrypt для $DOMAIN..."
systemctl stop nginx 2>/dev/null || true
fuser -k 80/tcp 2>/dev/null || true
certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --preferred-challenges http

CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"

if [ ! -f "$CERT_FILE" ]; then
  echo "[-] Ошибка: сертификат не получен!"
  echo "[-] Проверьте, что в DNS запись A для $DOMAIN указывает на IP $SERVER_IP (Cloudflare Proxy отключен)."
  exit 1
fi

echo "[3/6] Скачивание сайта-заглушки и запуск Nginx на порту 80..."
mkdir -p /var/www/html
rm -rf /var/www/html/* /var/www/html/.* 2>/dev/null || true
git clone https://github.com/dexxdd/ossetian-site.git /var/www/html
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html

cat << 'EOF' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

nginx -t
systemctl restart nginx
systemctl enable nginx

echo "[4/6] Установка 3X-UI панели..."
export XUI_NONINTERACTIVE=1
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

PANEL_PORT=52162
PANEL_USER="admin"
PANEL_PASS=$(openssl rand -hex 6)
PANEL_PATH=$(openssl rand -hex 8)

echo "[+] Настройка защищенного доступа 3X-UI..."
x-ui setting -port "$PANEL_PORT" -username "$PANEL_USER" -password "$PANEL_PASS" -webBasePath "/$PANEL_PATH/"
systemctl restart x-ui
sleep 2

echo "[5/6] Создание подключения VLESS-XHTTP на порту 443 с TLS и uTLS Edge..."
CLIENT_UUID=$(uuidgen)

python3 -c "
import sqlite3, json

conn = sqlite3.connect('/etc/x-ui/x-ui.db')
c = conn.cursor()

domain = '$DOMAIN'
cert_file = '$CERT_FILE'
key_file = '$KEY_FILE'
client_uuid = '$CLIENT_UUID'

c.execute('DELETE FROM inbounds')
c.execute('DELETE FROM client_traffics')

settings = json.dumps({
    'clients': [{'id': client_uuid, 'email': f'user@{domain}', 'flow': ''}],
    'decryption': 'none',
    'fallbacks': [{'dest': 80}]
})

stream_settings = json.dumps({
    'network': 'xhttp',
    'security': 'tls',
    'tlsSettings': {
        'serverName': domain,
        'fingerprint': 'edge',
        'certificates': [{
            'certificateFile': cert_file,
            'keyFile': key_file
        }],
        'alpn': ['http/1.1'],
        'settings': {
            'fingerprint': 'edge'
        }
    },
    'xhttpSettings': {
        'mode': 'auto',
        'host': domain,
        'path': '/api/',
        'xPaddingBytes': '100-1000'
    }
})

sniffing = json.dumps({
    'enabled': True,
    'destOverride': ['http', 'tls', 'quic', 'fakedns']
})

c.execute('''
    INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, sniffing)
    VALUES (1, 0, 0, 0, 'VLESS-XHTTP', 1, 0, '', 443, 'vless', ?, ?, ?)
''', (settings, stream_settings, sniffing))

inbound_id = c.lastrowid
c.execute('''
    INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset)
    VALUES (?, 1, ?, 0, 0, 0, 0, 0)
''', (inbound_id, f'user@{domain}'))

conn.commit()
conn.close()
"

fuser -k 443/tcp 2>/dev/null || true
killall -9 xray 2>/dev/null || true
systemctl restart x-ui
sleep 2

echo "[6/6] Настройка фаервола UFW (с защитой панели)..."
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP Web'
ufw allow 443/tcp comment 'HTTPS VLESS TLS'

# Обработка белого списка для порта панели управления
CLEAN_IPS=$(echo "$WHITELIST_IPS" | tr -d '[:space:]')
if [ "$CLEAN_IPS" = "all" ] || [ -z "$CLEAN_IPS" ]; then
  echo "[+] Админ-панель открыта для всех IP"
  ufw allow "$PANEL_PORT"/tcp comment '3X-UI Public'
else
  IFS=',' read -ra ADDR_ARRAY <<< "$WHITELIST_IPS"
  for item in "${ADDR_ARRAY[@]}"; do
    ip=$(echo "$item" | xargs)
    if [ -n "$ip" ]; then
      echo "[+] Добавление в белый список UFW: $ip -> порт $PANEL_PORT"
      ufw allow from "$ip" to any port "$PANEL_PORT" proto tcp comment '3X-UI Whitelist'
    fi
  done
fi

ufw --force enable

VLESS_LINK="vless://${CLIENT_UUID}@${DOMAIN}:443?alpn=http%2F1.1&encryption=none&extra=%7B%22mode%22%3A%22auto%22%2C%22xPaddingBytes%22%3A%22100-1000%22%7D&fp=edge&host=${DOMAIN}&mode=auto&path=%2Fapi%2F&security=tls&sni=${DOMAIN}&type=xhttp&x_padding_bytes=100-1000#VLESS-XHTTP"

echo ""
echo "=========================================================================="
echo "                 УСТАНОВКА ПОЛНОСТЬЮ ЗАВЕРШЕНА!                          "
echo "=========================================================================="
echo ""
echo "Сайт-заглушка:   http://${DOMAIN}"
echo ""
echo "--- ВХОД В ПАНЕЛЬ 3X-UI ---"
echo "URL:             http://${SERVER_IP}:${PANEL_PORT}/${PANEL_PATH}/"
echo "Логин:           ${PANEL_USER}"
echo "Пароль:          ${PANEL_PASS}"
echo "Белый список:    ${WHITELIST_IPS}"
echo ""
echo "--- ВАША VLESS-ССЫЛКА ДЛЯ ПОДКЛЮЧЕНИЯ ---"
echo "${VLESS_LINK}"
echo ""
echo "--- QR-КОД ДЛЯ ИМПОРТА В ТЕЛЕФОН ---"
qrencode -t ANSIUTF8 "${VLESS_LINK}"
echo "=========================================================================="
