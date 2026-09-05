#!/usr/bin/env bash
#
# add-tcp-entry.sh — 用 sing-box 加一条 TCP 备用入口（VLESS + TLS）
#
#   已有：Client -> Hysteria2 (UDP)   -> VPS -> Direct   ← 不动它
#   新增：Client -> VLESS+TLS (TCP)   -> VPS -> Direct   ← 本脚本
#
# 为什么不用 Xray：
#
#   同一台机器上，Xray 26.x 的 REALITY 和 VLESS+TLS 入口都无法握手，
#   连它自己的同版本客户端走回环都连不上，而失败信息只有一句
#   "handshake did not complete successfully"，排查没有抓手。
#   （这台机器上 Xray 的 hysteria inbound 也有"服务活着但不监听端口"
#   的老毛病，见 AGENTS.md §0.1——同一个实现上踩到第二次了。）
#
#   sing-box 是客户端那边已经在用的实现，服务端用同一个项目，
#   报错清楚，字段和客户端一一对应。
#
# 端口默认 8443 而不是 443：
#
#   自签证书挂在 443 上是很明显的代理特征，而 443 是被扫得最狠的端口。
#   换个非标端口，被主动探测命中的概率低一个数量级，代价几乎为零。
#   等有了域名和真证书，再换回 443 才有意义。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash add-tcp-entry.sh
#   bash add-tcp-entry.sh --port 443 --domain example.com   # 有域名时
#
# 卸载：
#
#   bash add-tcp-entry.sh --uninstall
#
set -euo pipefail

PORT=8443
SNI="www.bing.com"
DOMAIN=""
CONFIG="/etc/sing-box/config.json"
CERT_DIR="/etc/sing-box"
SOCKS_PORT=10810
UNINSTALL=0

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      PORT="${2:?--port 需要一个端口号}"; shift 2 ;;
    --sni)       SNI="${2:?--sni 需要一个域名}";     shift 2 ;;
    --domain)    DOMAIN="${2:?--domain 需要一个域名}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0 ;;
    *)           die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"

if [ "$UNINSTALL" -eq 1 ]; then
  log "停止并卸载 sing-box"
  systemctl disable --now sing-box >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/sing-box.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "$CERT_DIR"
  log "已移除。HY2 未受影响：$(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')"
  exit 0
fi

command -v apt-get >/dev/null 2>&1 || die "这个脚本只支持 Ubuntu / Debian"
case "$PORT" in ''|*[!0-9]*) die "端口必须是数字：$PORT" ;; esac

# 有域名就用域名当 SNI，客户端也就不用勾"跳过证书验证"（前提是配了真证书）
[ -n "$DOMAIN" ] && SNI="$DOMAIN"

log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates iproute2 >/dev/null

HY2_WAS_ACTIVE=0
systemctl is-active --quiet hysteria-server 2>/dev/null && HY2_WAS_ACTIVE=1

OCCUPANT="$(ss -ltnp 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" | grep -oE 'users:\(\("[^"]+' | grep -oE '"[^"]+$' | tr -d '"' | head -1 || true)"
if [ -n "$OCCUPANT" ] && [ "$OCCUPANT" != "sing-box" ]; then
  die "TCP ${PORT} 已被 ${OCCUPANT} 占用。换个端口：bash $0 --port 9443"
fi

# ---------------------------------------------------------------- 1. sing-box

if command -v sing-box >/dev/null 2>&1; then
  log "已安装的 sing-box：$(sing-box version 2>/dev/null | head -1)"
else
  log "安装 sing-box（官方脚本）"
  curl -fsSL https://sing-box.app/install.sh | sh
fi
command -v sing-box >/dev/null 2>&1 || die "sing-box 安装失败，请检查上面的输出"

# ---------------------------------------------------------------- 2. UUID 和证书

UUID="$(sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p' "$CONFIG" 2>/dev/null | head -1 || true)"
if [ -n "$UUID" ]; then
  log "沿用现有 UUID：$UUID"
else
  UUID="$(cat /proc/sys/kernel/random/uuid)"
  log "生成 UUID：$UUID"
fi

mkdir -p "$CERT_DIR"
if [ -n "$DOMAIN" ] && [ -f "$CERT_DIR/cert.pem" ] && openssl x509 -in "$CERT_DIR/cert.pem" -noout -issuer 2>/dev/null | grep -qv "CN *= *${SNI}"; then
  log "沿用已有证书"
else
  log "生成自签证书（CN=${SNI}）"
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
    -subj "/CN=${SNI}" -days 3650 >/dev/null 2>&1
fi
chmod 600 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/cert.pem"

# ---------------------------------------------------------------- 3. 配置
#
# 私网 ACL 的写法在 sing-box 1.11 前后变过（route rule 的 outbound: block
# 改成 action: reject）。与其猜版本，不如两种都写一遍，拿 sing-box check
# 去问它——install-hy2-official.sh 那边踩过一次版本漂移，这次直接问。

BACKUP=""
if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  warn "已备份原有配置到 $BACKUP"
fi

write_config() {
  # $1 = "modern" | "legacy"
  local route_block
  if [ "$1" = "modern" ]; then
    route_block='"route": { "rules": [ { "ip_is_private": true, "action": "reject" } ], "final": "direct" }'
  else
    route_block='"route": { "rules": [ { "ip_is_private": true, "outbound": "block" } ], "final": "direct" }'
  fi

  local outbounds='{ "type": "direct", "tag": "direct" }'
  [ "$1" = "legacy" ] && outbounds='{ "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" }'

  cat > "$CONFIG" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT},
      "users": [ { "uuid": "${UUID}" } ],
      "tls": {
        "enabled": true,
        "server_name": "${SNI}",
        "certificate_path": "${CERT_DIR}/cert.pem",
        "key_path": "${CERT_DIR}/key.pem"
      }
    }
  ],
  "outbounds": [ ${outbounds} ],
  ${route_block}
}
EOF
}

log "写入配置：$CONFIG"
SHAPE=""
for shape in modern legacy; do
  write_config "$shape"
  if sing-box check -c "$CONFIG" >/tmp/sb-check.log 2>&1; then
    SHAPE="$shape"
    log "配置校验通过（${shape} schema）✓"
    break
  fi
done
[ -n "$SHAPE" ] || { cat /tmp/sb-check.log >&2; [ -n "$BACKUP" ] && cp "$BACKUP" "$CONFIG"; die "配置校验失败"; }

# ---------------------------------------------------------------- 4. systemd
#
# 官方安装脚本不一定带 unit（版本而异），没有就自己写一份，免得脚本
# 在不同环境下时灵时不灵。

if [ ! -f /etc/systemd/system/sing-box.service ] && [ ! -f /lib/systemd/system/sing-box.service ]; then
  log "写入 systemd 单元"
  cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
After=network.target nss-lookup.target

[Service]
ExecStart=$(command -v sing-box) run -c ${CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow 22/tcp >/dev/null 2>&1 || true
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  log "已放行 TCP ${PORT}（ufw）"
fi

# ---------------------------------------------------------------- 5. 启动

rollback() {
  warn "正在回滚"
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$CONFIG"; systemctl restart sing-box >/dev/null 2>&1 || true
  else
    systemctl disable --now sing-box >/dev/null 2>&1 || true
  fi
}

log "启动 sing-box"
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box
sleep 2

systemctl is-active --quiet sing-box || {
  journalctl -u sing-box -n 30 --no-pager -o cat >&2 || true
  rollback
  die "sing-box 启动失败（详见上面的日志）。HY2 未受影响。"
}

LISTENING=0
for _ in 1 2 3 4 5; do
  ss -ltnp 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && { LISTENING=1; break; }
  sleep 1
done
[ "$LISTENING" -eq 1 ] || { ss -ltnp >&2; rollback; die "没有监听 TCP ${PORT}"; }
log "确认监听中 ✓"

# ---------------------------------------------------------------- 6. 自己连自己验一次
#
# 端口在监听 ≠ 这条入口能用。上一轮就是在"监听中"的状态下报了部署完成，
# 结果两个客户端配完都连不通。所以成功的判据是"真的走通了一次请求"。

log "自测：通过这条入口请求一次出口 IP"
SELFTEST="/tmp/tcp-entry-selftest.json"
cat > "$SELFTEST" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    { "type": "socks", "tag": "in", "listen": "127.0.0.1", "listen_port": ${SOCKS_PORT} }
  ],
  "outbounds": [
    {
      "type": "vless",
      "tag": "out",
      "server": "127.0.0.1",
      "server_port": ${PORT},
      "uuid": "${UUID}",
      "tls": { "enabled": true, "server_name": "${SNI}", "insecure": true }
    }
  ]
}
EOF

sing-box run -c "$SELFTEST" >/tmp/sb-selftest.log 2>&1 &
TEST_PID=$!
sleep 2
SELF_IP="$(curl -fsS --max-time 12 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null || true)"
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true

if [ -z "$SELF_IP" ]; then
  echo "--- 测试客户端日志 ---" >&2
  tail -20 /tmp/sb-selftest.log >&2 2>/dev/null || true
  echo "--- 服务端日志 ---" >&2
  journalctl -u sing-box -n 20 --no-pager -o cat >&2 2>/dev/null || true
  rollback
  die "自测没通过，已回滚。HY2 未受影响。"
fi
log "自测通过 ✓ 出口 IP = ${SELF_IP}"

if [ "$HY2_WAS_ACTIVE" -eq 1 ]; then
  systemctl is-active --quiet hysteria-server && log "HY2 仍在正常运行 ✓" || {
    warn "HY2 掉了，正在拉起"; systemctl restart hysteria-server || true
  }
fi

# ---------------------------------------------------------------- 7. 输出

SERVER_IP="$SELF_IP"
ADDR="${DOMAIN:-$SERVER_IP}"
HY2_PORT="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*:*\([0-9]\{1,5\}\).*/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)"
[ -n "$HY2_PORT" ] || HY2_PORT="24443"

cat <<EOF

========== TCP 备用入口部署完成（已自测通过）==========

  地址        ${ADDR}
  端口        ${PORT}  (TCP)
  UUID        ${UUID}
  SNI         ${SNI}
  跳过证书验证 必须开启（自签证书）

  出口 IP 没变，还是 ${SERVER_IP}。

=======================================================

sing-box：加进 outbounds，和原来的 hysteria2 并列

{
  "type": "vless",
  "tag": "tcp",
  "server": "${ADDR}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "insecure": true
  }
}

用了 selector 的话，把 "tcp" 加进它的 outbounds 列表。

Clash / mihomo：加进 proxies

  - name: my-tcp
    type: vless
    server: ${ADDR}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    servername: ${SNI}
    skip-cert-verify: true

-------------------------------------------------------

两条入口，同一个出口：

  UDP ${HY2_PORT}   HY2        日常主用，更快
  TCP ${PORT}    VLESS+TLS  UDP 不通时的备用

常用命令：

  systemctl status sing-box --no-pager
  journalctl -u sing-box -n 50 --no-pager -o cat
  ss -ltnp | grep ${PORT}

注意：UUID 等同于这条入口的钥匙，不要外传。

EOF
