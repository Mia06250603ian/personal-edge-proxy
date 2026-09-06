#!/usr/bin/env bash
#
# install-hy2.sh — 在一台干净的 Ubuntu / Debian VPS 上部署最小可用的 Hysteria2 节点
#
# 对应 README 的 Profile A：
#
#   Client -> Hysteria2 -> VPS -> Direct
#
# 设计目标：手机 SSH 也能一条命令跑完，不需要手写 JSON。
#
# 这个脚本只做 Profile A。它不会安装 WARP，不会配置固定 SOCKS5，
# 也不会安装 REALITY。需要那些请看 README 和 docs/。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash install-hy2.sh
#   bash install-hy2.sh --port 24443
#   bash install-hy2.sh --port 24443 --sni www.bing.com
#
# 指定节点密码（不指定则随机生成）。适合无人值守场景，例如把本脚本
# 挂到云服务商的「启动脚本 / user-data」里：密码是你自己定的，
# 于是不需要登录服务器也能拼出客户端链接。
#
#   bash install-hy2.sh --password 'YourNodePassword'
#
# 卸载：
#
#   bash install-hy2.sh --uninstall
#
set -euo pipefail

PORT=24443
SNI="www.bing.com"
PASSWORD=""
CERT_DIR="/etc/xray/certs/self"
CONFIG="/usr/local/etc/xray/config.json"
UNINSTALL=0

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      PORT="${2:?--port 需要一个端口号}"; shift 2 ;;
    --sni)       SNI="${2:?--sni 需要一个域名}";     shift 2 ;;
    --password)  PASSWORD="${2:?--password 需要一个密码}"; shift 2 ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *)           die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"

if [ "$UNINSTALL" -eq 1 ]; then
  log "停止并卸载 Xray"
  systemctl disable --now xray 2>/dev/null || true
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null || true
  rm -rf "$CERT_DIR"
  log "已卸载。防火墙规则未自动删除，如需清理：ufw delete allow ${PORT}/udp"
  exit 0
fi

command -v apt-get >/dev/null 2>&1 || die "这个脚本只支持 Ubuntu / Debian（需要 apt-get）"

case "$PORT" in
  ''|*[!0-9]*) die "端口必须是数字：$PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口超出范围：$PORT"

# ---------------------------------------------------------------- 1. 依赖

log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates >/dev/null

# ---------------------------------------------------------------- 2. Xray

if command -v xray >/dev/null 2>&1; then
  log "检测到已安装的 Xray：$(xray version 2>/dev/null | head -1)"
else
  log "安装 Xray（官方脚本）"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

command -v xray >/dev/null 2>&1 || die "Xray 安装失败，请检查上面的输出"

# Hysteria2 inbound 需要较新的 Xray。低于 25.x 大概率不支持。
XRAY_VER="$(xray version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
XRAY_MAJOR="${XRAY_VER%%.*}"
if [ -n "$XRAY_MAJOR" ] && [ "$XRAY_MAJOR" -lt 25 ] 2>/dev/null; then
  warn "当前 Xray 版本 $XRAY_VER 可能不支持 hysteria inbound；本脚本按 25.x+ 编写。"
  warn "如果下面的配置校验失败，请先升级 Xray 再重跑。"
fi

# ---------------------------------------------------------------- 3. 自签证书

# 说明：这里用自签证书，所以客户端必须开启 "允许不安全 / skip-cert-verify"。
#
# 取舍：HY2 的身份验证靠密码，密码不会因为证书自签而泄露；自签的代价是
# 客户端无法验证服务端身份，理论上存在中间人替换服务端的风险。
# 如果你有域名，建议改用 ACME 签发的真实证书（见 docs/mobile-quickstart.md）。

log "生成自签证书（SNI: ${SNI}）"
mkdir -p "$CERT_DIR"
# 先生成到临时目录，验证含 SAN 之后再原子替换。
# 直接写目标路径的话，生成失败会毁掉现在还能用的那张证书——
# 而这台机器上可能正跑着一条依赖它的入口。
CERT_TMP="$(mktemp -d)"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$CERT_TMP/key.pem" -out "$CERT_TMP/fullchain.pem" \
  -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}" \
  -days 3650 >/dev/null 2>&1
if ! openssl x509 -in "$CERT_TMP/fullchain.pem" -noout -text 2>/dev/null | grep -q "DNS:${SNI}"; then
  rm -rf "$CERT_TMP"
  die "证书生成失败或缺少 SAN。原有证书未被改动。"
fi
mv "$CERT_TMP/fullchain.pem" "$CERT_DIR/fullchain.pem"
mv "$CERT_TMP/key.pem" "$CERT_DIR/key.pem"
rm -rf "$CERT_TMP"
chmod 600 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/fullchain.pem"

# 只把私钥交给 Xray 实际运行的那个用户，并且只交私钥本身。
#
# 早先这里是无条件 `chown -R nobody:nogroup`。nobody 是系统上共享的
# 通用低权限账号，把 TLS 私钥交给它，等于让任何以 nobody 身份运行的
# 进程都能读走私钥。这里改成先问 systemd 单元里到底配的是哪个用户。
XRAY_USER="$(systemctl show xray -p User --value 2>/dev/null || true)"
if [ -n "$XRAY_USER" ] && [ "$XRAY_USER" != "root" ] && id "$XRAY_USER" >/dev/null 2>&1; then
  chown "$XRAY_USER" "$CERT_DIR/key.pem"
  log "私钥属主交给 Xray 的运行用户 ${XRAY_USER}"
else
  log "Xray 以 root 运行，私钥保持 root 属主"
fi

# ---------------------------------------------------------------- 4. 配置

if [ -n "$PASSWORD" ]; then
  # 只接受字母数字和一小撮安全符号：密码会被写进 JSON 配置和分享链接，
  # 引号 / 反斜杠 / @ / # 之类会破坏其中之一。
  case "$PASSWORD" in
    *[!A-Za-z0-9._-]*) die "--password 只能包含字母、数字和 . _ - （避免破坏配置与分享链接）" ;;
  esac
  [ "${#PASSWORD}" -ge 8 ] || die "--password 至少 8 位"
  log "使用指定的节点密码"
else
  PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  [ -n "$PASSWORD" ] || die "生成密码失败"
  log "已随机生成节点密码"
fi

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
    "access": "none",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "hy2-xr",
      "listen": "::",
      "port": ${PORT},
      "protocol": "hysteria",
      "settings": {
        "version": 2,
        "users": [
          { "auth": "${PASSWORD}", "email": "personal" }
        ]
      },
      "streamSettings": {
        "method": "hysteria",
        "security": "tls",
        "tlsSettings": {
          "alpn": [ "h3" ],
          "certificates": [
            {
              "certificateFile": "${CERT_DIR}/fullchain.pem",
              "keyFile": "${CERT_DIR}/key.pem"
            }
          ]
        },
        "hysteriaSettings": {
          "version": 2,
          "udpIdleTimeout": 60
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
    { "tag": "direct", "protocol": "freedom",  "settings": {} },
    { "tag": "block",  "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "IPOnDemand",
    "rules": [
      {
        "type": "field",
        "inboundTag": [ "hy2-xr" ],
        "ip": [
          "10.0.0.0/8",
          "172.16.0.0/12",
          "192.168.0.0/16",
          "127.0.0.0/8",
          "169.254.0.0/16",
          "fc00::/7",
          "fe80::/10"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

log "校验配置"
if ! xray run -test -config "$CONFIG" >/tmp/xray-test.log 2>&1; then
  cat /tmp/xray-test.log >&2
  die "配置校验失败（详见上面的报错）。常见原因：Xray 版本过低，不支持 hysteria inbound。"
fi

# ---------------------------------------------------------------- 5. 防火墙

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "放行 UDP ${PORT}（ufw）"
  ufw allow 22/tcp        >/dev/null 2>&1 || true
  ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
else
  warn "未检测到启用的 ufw。请自行确认 VPS 面板的安全组已放行 UDP ${PORT}。"
fi

# ---------------------------------------------------------------- 6. 启动

log "启动 Xray"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2

if ! systemctl is-active --quiet xray; then
  journalctl -u xray -n 30 --no-pager >&2 || true
  die "Xray 启动失败（详见上面的日志）"
fi

# 服务活着 ≠ 端口在听。Xray 26.3.x 的 hysteria inbound 有已知问题
# （XTLS/Xray-core #5921、#5619）：实测出现过服务 active、配置也通过
# xray -test，但根本没有绑定 UDP 端口、日志里也不报错的情况。
# 所以这里必须真的去看一眼监听状态，否则脚本会假报成功。
log "验证 UDP ${PORT} 是否在监听"
command -v ss >/dev/null 2>&1 || apt-get install -y -qq iproute2 >/dev/null 2>&1 || true
LISTENING=0
for _ in 1 2 3 4 5; do
  if ss -ulnp 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
    LISTENING=1
    break
  fi
  sleep 1
done

if [ "$LISTENING" -ne 1 ]; then
  echo "--- ss -ulnp ---" >&2
  ss -ulnp >&2 || true
  echo "--- 最近日志 ---" >&2
  journalctl -u xray -n 30 --no-pager >&2 || true
  die "Xray 在运行，但没有监听 UDP ${PORT}。
这多半是 Xray 的 hysteria inbound 问题，不是你的配置写错了。
改用官方 Hysteria2 服务端：bash scripts/install-hy2-official.sh"
fi

log "确认监听中 ✓"

# ---------------------------------------------------------------- 7. 输出

SERVER_IP=""
for probe in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
  SERVER_IP="$(curl -fsS4 --max-time 8 "$probe" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$SERVER_IP" ] && break
done
[ -n "$SERVER_IP" ] || SERVER_IP="YOUR_SERVER_IP"

SHARE="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?insecure=1&sni=${SNI}#my-hy2"

cat <<EOF

================= 部署完成 =================

  服务器      ${SERVER_IP}
  端口        ${PORT}  (UDP)
  密码        ${PASSWORD}
  SNI         ${SNI}
  跳过证书验证 必须开启（本脚本用的是自签证书）

  分享链接（复制到客户端"从剪贴板导入"）：

${SHARE}

===========================================

后续常用命令：

  systemctl status xray          查看运行状态
  systemctl restart xray         重启
  journalctl -u xray -n 50       看最近日志
  tail -f /var/log/xray/error.log

排错见 docs/mobile-quickstart.md 第 6 节。

注意：上面的密码等同于你这台节点的钥匙，不要发到群里、Issue 或公开仓库。

EOF
