#!/bin/bash
set -e

MTG_BIN="/usr/local/bin/mtg"
MTG_CONF="/etc/mtg.toml"
NGINX_STREAM_CONF="/etc/nginx/stream.d/mtp_mix.conf"
FAKE_DOMAIN="www.microsoft.com"

# 交互输入端口
read -p "请输入主端口 (默认 443): " PORT_MAIN
PORT_MAIN=${PORT_MAIN:-443}

read -p "请输入备用端口 (默认 2053): " PORT_BACKUP
PORT_BACKUP=${PORT_BACKUP:-2053}

PORT_MTG="2398"   # mtg 内部监听

install_deps() {
  echo "[*] 安装依赖..."
  apt update
  apt install -y golang nginx libnginx-mod-stream openssl curl
}

install_mtg() {
  echo "[*] 安装 mtg..."
  go install github.com/9seconds/mtg/v2@latest
  install -Dm755 $(go env GOPATH)/bin/mtg $MTG_BIN
}

gen_secret() {
  echo "[*] 生成 Fake-TLS Secret..."
  SECRET=$($MTG_BIN generate-secret --hex $FAKE_DOMAIN | tr -d '\r\n')
  echo "secret = \"$SECRET\"" > $MTG_CONF
  echo "bind-to = \"127.0.0.1:$PORT_MTG\"" >> $MTG_CONF

  cat >/etc/systemd/system/mtg.service <<EOF
[Unit]
Description=mtg - MTProto proxy
After=network.target
[Service]
ExecStart=$MTG_BIN run $MTG_CONF
Restart=always
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
DynamicUser=true
[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now mtg
}

setup_nginx() {
  echo "[*] 配置 Nginx SNI 分流..."

  if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    sed -i '/^http {/i stream {\n    include /etc/nginx/stream.d/*.conf;\n}\n' /etc/nginx/nginx.conf
  fi

  if grep -q 'load_module modules/ngx_stream_module.so;' /etc/nginx/nginx.conf && \
     [ -f /etc/nginx/modules-enabled/50-mod-stream.conf ]; then
    sed -i '/load_module modules\/ngx_stream_module.so;/d' /etc/nginx/nginx.conf
    echo "[i] 已移除 nginx.conf 里重复的 stream 模块加载"
  fi

  mkdir -p /etc/nginx/stream.d /etc/nginx/selfssl

  if [ ! -f /etc/nginx/selfssl/fallback.crt ]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/nginx/selfssl/fallback.key \
      -out /etc/nginx/selfssl/fallback.crt \
      -subj "/CN=example.com"
  fi

  cat > $NGINX_STREAM_CONF <<EOF
map \$ssl_preread_server_name \$mtg_upstream {
    default                 web_backend;
    "$FAKE_DOMAIN"          mtg_backend;
}
upstream mtg_backend { server 127.0.0.1:$PORT_MTG; }
upstream web_backend { server 127.0.0.1:8443; }

server {
    listen $PORT_MAIN reuseport;
    proxy_timeout 10m;
    proxy_pass \$mtg_upstream;
    ssl_preread on;
}
server {
    listen $PORT_BACKUP reuseport;
    proxy_timeout 10m;
    proxy_pass \$mtg_upstream;
    ssl_preread on;
}
EOF

  cat >/etc/nginx/sites-available/fallback-https.conf <<'EOF'
server {
    listen 8443 ssl;
    server_name _;
    ssl_certificate     /etc/nginx/selfssl/fallback.crt;
    ssl_certificate_key /etc/nginx/selfssl/fallback.key;
    location / { return 200 "ok\n"; }
}
EOF
  ln -sf /etc/nginx/sites-available/fallback-https.conf /etc/nginx/sites-enabled/fallback-https.conf

  nginx -t && systemctl reload nginx
}

apply_security() {
  echo "[*] 应用内核加固参数..."
  cat >>/etc/sysctl.conf <<EOF
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.icmp_echo_ignore_broadcasts=1
EOF
  sysctl -p
}

show_link() {
  IP=$(curl -4 -s ifconfig.me)
  SECRET=$(grep secret $MTG_CONF | cut -d'"' -f2)
  echo ""
  echo "✅ 部署完成！你的代理链接："
  echo "tg://proxy?server=$IP&port=$PORT_MAIN&secret=$SECRET"
  echo "备用端口：$PORT_BACKUP"
}

main() {
  install_deps
  install_mtg
  gen_secret
  setup_nginx
  apply_security
  show_link
}

main
