#!/usr/bin/env bash
#
# add-vless-tls.sh — 给现有节点加一条 VLESS + TLS 的 TCP 备用入口
#
#   已有：Client -> Hysteria2 (UDP)  -> VPS -> Direct     ← 不动它
#   新增：Client -> VLESS+TLS (TCP 443) -> VPS -> Direct  ← 本脚本
#
# 和 add-reality.sh 的关系：
#
#   REALITY 隐蔽性更好，但握手对版本、指纹、目标站点都敏感，失败时服务端
#   只会说一句 "handshake did not complete successfully"，不告诉你是哪一项
#   不匹配——实测在 Xray 26.x 上排查成本很高。
#
#   这一份用标准 TLS：客户端只要支持 VLESS 就能连，自签证书配
#   "跳过证书验证"，和 HY2 那边的做法一致。代价是流量特征比 REALITY 明显，
#   长期主用不如 REALITY，但作为"UDP 挂了还能进得去"的备用入口完全够。
#
# 关键前提和 add-reality.sh 一样：
#
#   入口（怎么进 VPS）  ←  只改这一层
#   出口（从哪里上网）  ←  完全不变，同一台机器同一个 IP
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash add-vless-tls.sh
#   bash add-vless-tls.sh --port 8443
#
# 卸载：
#
#   bash add-vless-tls.sh --uninstall
#
set -euo pipefail

PORT=443
SNI="www.bing.com"
CONFIG="/usr/local/etc/xray/config.json"
CERT_DIR="/etc/xray/certs/self"
SOCKS_PORT=10809
UNINSTALL=0

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      PORT="${2:?--port 需要一个端口号}"; shift 2 ;;
    --sni)       SNI="${2:?--sni 需要一个域名}";     shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *)           die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"

if [ "$UNINSTALL" -eq 1 ]; then
  log "停止并卸载 Xray（TCP 备用入口）"
  systemctl disable --now xray >/dev/null 2>&1 || true
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null || true
  rm -rf "$CERT_DIR"
  log "已移除。HY2 未受影响：$(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')"
  exit 0
fi

command -v apt-get >/dev/null 2>&1 || die "这个脚本只支持 Ubuntu / Debian"
case "$PORT" in ''|*[!0-9]*) die "端口必须是数字：$PORT" ;; esac

log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates iproute2 >/dev/null

HY2_WAS_ACTIVE=0
systemctl is-active --quiet hysteria-server 2>/dev/null && HY2_WAS_ACTIVE=1

if command -v xray >/dev/null 2>&1; then
  log "已安装的 Xray：$(xray version 2>/dev/null | head -1)"
else
  log "安装 Xray"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
command -v xray >/dev/null 2>&1 || die "Xray 安装失败"

# ---------------------------------------------------------------- 1. 复用已有 UUID
#
# 如果这台机器上已经配过 REALITY，沿用同一个 UUID：客户端那边只需要改
# 传输参数，不用再换一遍 ID。

UUID="$(sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -1 || true)"
if [ -n "$UUID" ]; then
  log "沿用现有 UUID：$UUID"
else
  UUID="$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
  log "生成新 UUID：$UUID"
fi

# ---------------------------------------------------------------- 2. 自签证书

log "生成自签证书（CN=${SNI}）"
mkdir -p "$CERT_DIR"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
  -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1

# 官方 Xray 单元以 nobody 运行，证书要让它读得到。这个坑在 HY2 那边
# 已经踩过一次（服务在 systemd 报告 Started 之后才因为读不到文件退出）。
chmod 644 "$CERT_DIR/cert.pem"
chmod 640 "$CERT_DIR/key.pem"
chown -R nobody:nogroup "$CERT_DIR" 2>/dev/null || chown -R nobody:nobody "$CERT_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 3. 配置

BACKUP=""
if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  warn "已备份原有配置到 $BACKUP"
fi
mkdir -p "$(dirname "$CONFIG")" /var/log/xray

log "写入配置：$CONFIG"
cat > "$CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "vless-tls",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [ { "id": "${UUID}" } ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": [ "h2", "http/1.1" ],
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/cert.pem",
              "keyFile": "${CERT_DIR}/key.pem"
            }
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [ "http", "tls", "quic" ],
        "metadataOnly": false
      }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom",   "settings": {} },
    { "tag": "block",  "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "inboundTag": [ "vless-tls" ],
        "ip": [
          "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
          "127.0.0.0/8", "169.254.0.0/16", "fc00::/7", "fe80::/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

xray run -test -c "$CONFIG" >/tmp/xray-tls-test.log 2>&1 || {
  cat /tmp/xray-tls-test.log >&2
  [ -n "$BACKUP" ] && cp "$BACKUP" "$CONFIG"
  die "配置校验失败"
}
log "配置校验通过 ✓"

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  log "已放行 TCP ${PORT}（ufw）"
fi

# ---------------------------------------------------------------- 4. 启动

rollback() {
  warn "正在回滚"
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then cp "$BACKUP" "$CONFIG"; else rm -f "$CONFIG"; fi
  systemctl restart xray >/dev/null 2>&1 || systemctl disable --now xray >/dev/null 2>&1 || true
}

log "启动 Xray"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2

systemctl is-active --quiet xray || {
  journalctl -u xray -n 30 --no-pager >&2 || true
  rollback
  die "Xray 启动失败。HY2 未受影响。"
}

LISTENING=0
for _ in 1 2 3 4 5; do
  ss -ltnp 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && { LISTENING=1; break; }
  sleep 1
done
[ "$LISTENING" -eq 1 ] || { ss -ltnp >&2; rollback; die "没有监听 TCP ${PORT}"; }
log "确认监听中 ✓"

# ---------------------------------------------------------------- 5. 自己连自己验一次
#
# 这一步是从 REALITY 那次教训来的：上次装完报告"部署完成"，人跑去两个
# 客户端上各配了一遍，才发现根本连不通。端口在监听只说明服务起来了，
# 不代表这条入口真的能用。所以在宣布成功之前，先自己走一遍。

log "自测：通过这条入口请求一次出口 IP"
SELFTEST="/tmp/vless-tls-selftest.json"
cat > "$SELFTEST" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    { "tag": "s", "listen": "127.0.0.1", "port": ${SOCKS_PORT},
      "protocol": "socks", "settings": { "udp": false } }
  ],
  "outbounds": [
    {
      "tag": "t", "protocol": "vless",
      "settings": {
        "vnext": [ { "address": "127.0.0.1", "port": ${PORT},
          "users": [ { "id": "${UUID}", "encryption": "none" } ] } ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": { "serverName": "${SNI}", "allowInsecure": true }
      }
    }
  ]
}
EOF

xray run -c "$SELFTEST" >/dev/null 2>&1 &
TEST_PID=$!
sleep 2
SELF_IP="$(curl -fsS --max-time 12 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null || true)"
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true

if [ -z "$SELF_IP" ]; then
  echo "--- xray 错误日志 ---" >&2
  tail -20 /var/log/xray/error.log >&2 2>/dev/null || true
  rollback
  die "自测没通过：入口起来了但连不通，已回滚。HY2 未受影响。"
fi
log "自测通过 ✓ 出口 IP = ${SELF_IP}"

if [ "$HY2_WAS_ACTIVE" -eq 1 ]; then
  systemctl is-active --quiet hysteria-server && log "HY2 仍在正常运行 ✓" || {
    warn "HY2 掉了，正在拉起"
    systemctl restart hysteria-server || true
  }
fi

# ---------------------------------------------------------------- 6. 输出

SERVER_IP="$SELF_IP"
HY2_PORT="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*:*\([0-9]\{1,5\}\).*/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)"
[ -n "$HY2_PORT" ] || HY2_PORT="24443"

cat <<EOF

============ TCP 备用入口部署完成（已自测通过）============

  服务器      ${SERVER_IP}
  端口        ${PORT}  (TCP)
  UUID        ${UUID}
  SNI         ${SNI}
  跳过证书验证 必须开启（自签证书）

  出口 IP 没变，还是 ${SERVER_IP}。

===========================================================

sing-box：加进 outbounds 数组，和原来的 hysteria2 并列

{
  "type": "vless",
  "tag": "tcp443",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "insecure": true
  }
}

如果用了 selector，记得把 "tcp443" 加进它的 outbounds 列表。

Clash / mihomo：加进 proxies 列表

  - name: my-tcp443
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    servername: ${SNI}
    skip-cert-verify: true

-----------------------------------------------------------

两条入口，同一个出口：

  UDP ${HY2_PORT}   HY2        日常主用，更快
  TCP ${PORT}   VLESS+TLS  UDP 不通时的备用

注意：UUID 等同于这条入口的钥匙，不要外传。

EOF
