#!/bin/bash

# Cek root
[[ $EUID -ne 0 ]] && echo "Jalankan sebagai root: sudo ./install-multi-xray.sh" && exit 1

# Header
echo "=============================================="
echo "  XRAY MULTI-PORT & MULTI-NETWORK INSTALLER"
echo "  Support: VLESS + VMess + Trojan"
echo "  Ports: 443,8443 (TLS) + 2052,2053,8880 (Non-TLS)"
echo "  Networks: WS, gRPC, HTTPUpgrade"
echo "=============================================="

# Input domain
read -p "Masukkan domain Anda (contoh: vpn.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && echo "Domain wajib diisi!" && exit 1

# Input email
read -p "Masukkan email untuk Let's Encrypt: " EMAIL
[[ -z "$EMAIL" ]] && echo "Email wajib diisi!" && exit 1

# Update sistem
echo -e "\n[1/6] Update sistem..."
apt update -y && apt upgrade -y

# Install dependencies
echo -e "\n[2/6] Install dependencies..."
apt install -y curl wget socat nginx certbot python3-certbot-nginx jq

# Install Xray
echo -e "\n[3/6] Install Xray-core..."
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version 1.8.4

# Generate random credentials
UUID=$(xray uuid)
WS_PATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
GRPC_SERVICE="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
HTTPUPGRADE_PATH="/$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 8)"
TROJAN_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)

# Stop nginx untuk certbot
systemctl stop nginx

# Request SSL certificate
echo -e "\n[4/6] Request SSL certificate..."
certbot certonly --standalone -d $DOMAIN --email $EMAIL --agree-tos --non-interactive

# Create base config
cat > /etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF

# Function to add inbound
add_inbound() {
  local port=$1
  local protocol=$2
  local network=$3
  local path=$4
  local service=$5
  local security=$6
  
  local settings=""
  local streamSettings=""
  
  case $protocol in
    "vless")
      settings="{\"clients\":[{\"id\":\"$UUID\",\"flow\":\"xtls-rprx-direct\"}],\"decryption\":\"none\"}"
      ;;
    "vmess")
      settings="{\"clients\":[{\"id\":\"$UUID\",\"alterId\":0}]}"
      ;;
    "trojan")
      settings="{\"clients\":[{\"password\":\"$TROJAN_PASS\"}]}"
      ;;
  esac
  
  case $network in
    "ws")
      streamSettings="{\"network\":\"ws\",\"wsSettings\":{\"path\":\"$path\"}}"
      ;;
    "grpc")
      streamSettings="{\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"$service\"}}"
      ;;
    "httpupgrade")
      streamSettings="{\"network\":\"tcp\",\"tcpSettings\":{\"header\":{\"type\":\"http\",\"request\":{\"path\":[\"$path\"],\"headers\":{\"Host\":[\"$DOMAIN\"]}}}}}"
      ;;
  esac
  
  if [[ "$security" == "tls" ]]; then
    streamSettings=$(echo $streamSettings | jq --arg domain "$DOMAIN" '. + {"security":"tls","tlsSettings":{"serverName":$domain,"certificates":[{"certificateFile":"/etc/letsencrypt/live/'$DOMAIN'/fullchain.pem","keyFile":"/etc/letsencrypt/live/'$DOMAIN'/privkey.pem"}]}}')
  fi
  
  jq --argjson port "$port" \
     --arg protocol "$protocol" \
     --argjson settings "$settings" \
     --argjson streamSettings "$streamSettings" \
     '.inbounds += [{"port": $port, "protocol": $protocol, "settings": $settings, "streamSettings": $streamSettings, "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}}]' \
     /etc/xray/config.json > /tmp/xray_config.json && mv /tmp/xray_config.json /etc/xray/config.json
}

# Add all inbounds
echo -e "\n[5/6] Generate inbounds..."

# TLS Ports (443, 8443)
for port in 443 8443; do
  # VLESS
  add_inbound $port "vless" "ws" "$WS_PATH" "" "tls"
  add_inbound $port "vless" "grpc" "" "$GRPC_SERVICE" "tls"
  add_inbound $port "vless" "httpupgrade" "$HTTPUPGRADE_PATH" "" "tls"
  
  # VMess
  add_inbound $port "vmess" "ws" "$WS_PATH" "" "tls"
  add_inbound $port "vmess" "grpc" "" "$GRPC_SERVICE" "tls"
  add_inbound $port "vmess" "httpupgrade" "$HTTPUPGRADE_PATH" "" "tls"
  
  # Trojan
  add_inbound $port "trojan" "ws" "$WS_PATH" "" "tls"
  add_inbound $port "trojan" "grpc" "" "$GRPC_SERVICE" "tls"
  add_inbound $port "trojan" "httpupgrade" "$HTTPUPGRADE_PATH" "" "tls"
done

# Non-TLS Ports (2052, 2053, 8880)
for port in 2052 2053 8880; do
  # VLESS
  add_inbound $port "vless" "ws" "$WS_PATH" "" "none"
  add_inbound $port "vless" "grpc" "" "$GRPC_SERVICE" "none"
  add_inbound $port "vless" "httpupgrade" "$HTTPUPGRADE_PATH" "" "none"
  
  # VMess
  add_inbound $port "vmess" "ws" "$WS_PATH" "" "none"
  add_inbound $port "vmess" "grpc" "" "$GRPC_SERVICE" "none"
  add_inbound $port "vmess" "httpupgrade" "$HTTPUPGRADE_PATH" "" "none"
  
  # Trojan
  add_inbound $port "trojan" "ws" "$WS_PATH" "" "none"
  add_inbound $port "trojan" "grpc" "" "$GRPC_SERVICE" "none"
  add_inbound $port "trojan" "httpupgrade" "$HTTPUPGRADE_PATH" "" "none"
done

# Configure nginx as fallback
cat > /etc/nginx/sites-available/default << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}

server {
    listen 8443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

# Create dummy web server
mkdir -p /var/www/html
echo "Server is running" > /var/www/html/index.html

# Start services
echo -e "\n[6/6] Start services..."
systemctl restart nginx
systemctl restart xray
systemctl enable nginx
systemctl enable xray

# Generate links
generate_links() {
  local protocol=$1
  local port=$2
  local security=$3
  local network=$4
  local path=$5
  local service=$6
  local remark="$protocol-$port-$network"
  
  case $protocol in
    "vless")
      local id=$UUID
      local link="vless://$id@$DOMAIN:$port"
      ;;
    "vmess")
      local id=$UUID
      local vmess_json="{\"v\":2,\"ps\":\"$remark\",\"add\":\"$DOMAIN\",\"port\":$port,\"id\":\"$id\",\"aid\":0,\"net\":\"$network\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"$path\",\"tls\":\"$security\"}"
      local link="vmess://$(echo -n "$vmess_json" | base64 -w 0)"
      ;;
    "trojan")
      local id=$TROJAN_PASS
      local link="trojan://$id@$DOMAIN:$port"
      ;;
  esac
  
  # Add parameters based on network
  case $network in
    "ws")
      link+="?path=$path&security=$security&host=$DOMAIN&type=ws&sni=$DOMAIN#$remark"
      ;;
    "grpc")
      link+="?mode=gun&security=$security&type=grpc&serviceName=$service&sni=$DOMAIN#$remark"
      ;;
    "httpupgrade")
      link+="?path=$path&security=$security&host=$DOMAIN&type=httpupgrade&sni=$DOMAIN#$remark"
      ;;
  esac
  
  echo "$link"
}

# Save all links to file
cat > /root/xray-links.txt << EOF
XRAY MULTI-PORT & MULTI-NETWORK CONFIGURATION
Domain: $DOMAIN
Generated: $(date)

=== CREDENTIALS ===
UUID: $UUID
Trojan Password: $TROJAN_PASS
WS Path: $WS_PATH
gRPC Service: $GRPC_SERVICE
HTTPUpgrade Path: $HTTPUPGRADE_PATH

=== TLS PORTS (443, 8443) ===
EOF

# Generate TLS links
for port in 443 8443; do
  echo "" >> /root/xray-links.txt
  echo "Port $port (TLS):" >> /root/xray-links.txt
  
  for protocol in vless vmess trojan; do
    echo "" >> /root/xray-links.txt
    echo "  $protocol:" >> /root/xray-links.txt
    
    # WS
    local link=$(generate_links $protocol $port "tls" "ws" "$WS_PATH" "")
    echo "    WS: $link" >> /root/xray-links.txt
    
    # gRPC
    link=$(generate_links $protocol $port "tls" "grpc" "" "$GRPC_SERVICE")
    echo "    gRPC: $link" >> /root/xray-links.txt
    
    # HTTPUpgrade
    link=$(generate_links $protocol $port "tls" "httpupgrade" "$HTTPUPGRADE_PATH" "")
    echo "    HTTPUpgrade: $link" >> /root/xray-links.txt
  done
done

# Generate Non-TLS links
echo "" >> /root/xray-links.txt
echo "=== NON-TLS PORTS (2052, 2053, 8880) ===" >> /root/xray-links.txt

for port in 2052 2053 8880; do
  echo "" >> /root/xray-links.txt
  echo "Port $port (Non-TLS):" >> /root/xray-links.txt
  
  for protocol in vless vmess trojan; do
    echo "" >> /root/xray-links.txt
    echo "  $protocol:" >> /root/xray-links.txt
    
    # WS
    local link=$(generate_links $protocol $port "none" "ws" "$WS_PATH" "")
    echo "    WS: $link" >> /root/xray-links.txt
    
    # gRPC
    link=$(generate_links $protocol $port "none" "grpc" "" "$GRPC_SERVICE")
    echo "    gRPC: $link" >> /root/xray-links.txt
    
    # HTTPUpgrade
    link=$(generate_links $protocol $port "none" "httpupgrade" "$HTTPUPGRADE_PATH" "")
    echo "    HTTPUpgrade: $link" >> /root/xray-links.txt
  done
done

# Display sample links
echo -e "\n=============================================="
echo "  INSTALASI SELESAI!"
echo "=============================================="
echo -e "\nDomain: $DOMAIN"
echo "Total Akun: 45 kombinasi (3 protokol x 5 port x 3 network)"
echo -e "\n=== CONTOH LINK (VLESS di Port 443) ==="
echo "1. WebSocket:"
generate_links "vless" 443 "tls" "ws" "$WS_PATH" ""
echo -e "\n2. gRPC:"
generate_links "vless" 443 "tls" "grpc" "" "$GRPC_SERVICE"
echo -e "\n3. HTTPUpgrade:"
generate_links "vless" 443 "tls" "httpupgrade" "$HTTPUPGRADE_PATH" ""
echo -e "\n=============================================="
echo "Semua link tersimpan di: /root/xray-links.txt"
echo "=============================================="
