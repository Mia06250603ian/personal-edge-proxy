#!/usr/bin/env bash
#
# add-reality.sh — 给现有节点加一条 VLESS + REALITY + Vision 的 TCP 备用入口
#
#   已有：Client -> Hysteria2 (UDP 24443) -> VPS -> Direct     ← 不动它
#   新增：Client -> VLESS+REALITY (TCP 443) -> VPS -> Direct   ← 本脚本
#
# 为什么需要这个：
#
#   只有 HY2 时，入口只有 UDP 一条。运营商对 UDP 的处理是会变的——限速、
#   QoS、直接丢包都遇得到，而且往往只在某一个网络下发生（5G 不通、
#   Wi-Fi 正常）。这种时候服务器完全健康，你却进不去。
#
#   REALITY 走 TCP 443，是全互联网最不可能被整段封掉的端口。
#
# 关键前提（这也是本仓库反复强调的分界线）：
#
#   入口（怎么进 VPS）  ←  这个脚本只改这一层
#   出口（从哪里上网）  ←  完全不变，还是同一台机器同一个 IP
#
#   所以加这条入口对任何账号来说都是零变化：目标网站看到的出口 IP
#   一个字节都没变。也不需要动任何已经配好的 HY2 客户端。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash add-reality.sh
#   bash add-reality.sh --port 443 --sni www.microsoft.com
#
# 卸载（只卸 REALITY，不碰 HY2）：
#
#   bash add-reality.sh --uninstall
#
set -euo pipefail

PORT=443
SNI="www.microsoft.com"
CONFIG="/usr/local/etc/xray/config.json"
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
  log "停止并卸载 Xray（REALITY 入口）"
  systemctl disable --now xray >/dev/null 2>&1 || true
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge 2>/dev/null || true
  log "REALITY 入口已移除。HY2 未受影响："
  printf '  hysteria-server  %s\n' "$(systemctl is-active hysteria-server 2>/dev/null || echo '未安装')"
  log "防火墙规则未自动删除，如需清理：ufw delete allow ${PORT}/tcp"
  exit 0
fi

command -v apt-get >/dev/null 2>&1 || die "这个脚本只支持 Ubuntu / Debian（需要 apt-get）"

case "$PORT" in
  ''|*[!0-9]*) die "端口必须是数字：$PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口超出范围：$PORT"

# ---------------------------------------------------------------- 0. 先确认不会踩到现有服务
#
# 这个脚本的全部价值在于"给一个正在用的节点加保险"。如果它把那个节点
# 弄挂了，就完全本末倒置。所以动手之前先检查，宁可不装也不能踩。

log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates iproute2 >/dev/null

HY2_WAS_ACTIVE=0
if systemctl is-active --quiet hysteria-server 2>/dev/null; then
  HY2_WAS_ACTIVE=1
  log "检测到 HY2 正在运行，本脚本不会碰它"
fi

# TCP 端口被别的进程占着就停手。唯一可以接受的占用者是 Xray 自己
# （说明是重跑本脚本）。
OCCUPANT="$(ss -ltnp 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" | grep -oE 'users:\(\("[^"]+' | grep -oE '"[^"]+$' | tr -d '"' | head -1 || true)"
if [ -n "$OCCUPANT" ] && [ "$OCCUPANT" != "xray" ]; then
  die "TCP ${PORT} 已被 ${OCCUPANT} 占用。换个端口：bash $0 --port 8443"
fi

# ---------------------------------------------------------------- 1. Xray

if command -v xray >/dev/null 2>&1; then
  log "检测到已安装的 Xray：$(xray version 2>/dev/null | head -1)"
else
  log "安装 Xray（官方脚本）"
  bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi
command -v xray >/dev/null 2>&1 || die "Xray 安装失败，请检查上面的输出"

# ---------------------------------------------------------------- 2. 检查 SNI 目标合不合格
#
# REALITY 借用一个真实网站的 TLS 握手来伪装，所以那个网站必须支持
# TLS 1.3 + H2。不合格的目标会让握手在客户端侧莫名其妙地失败，
# 而且报错完全不会提示"是你的 target 选错了"。

log "检查 REALITY 目标：${SNI}"
TLS_PROBE="$(echo | timeout 10 openssl s_client -connect "${SNI}:443" -servername "$SNI" -tls1_3 -alpn h2 2>/dev/null || true)"
if printf '%s' "$TLS_PROBE" | grep -q "TLSv1.3"; then
  if printf '%s' "$TLS_PROBE" | grep -q "ALPN protocol: h2"; then
    log "目标合格（TLS 1.3 + H2）✓"
  else
    warn "${SNI} 支持 TLS 1.3 但没协商出 H2。多数情况仍可用，握手异常时优先换目标。"
  fi
else
  warn "无法确认 ${SNI} 支持 TLS 1.3。备选：www.apple.com / addons.mozilla.org / dl.google.com"
  warn "换目标重跑：bash $0 --sni www.apple.com"
fi

# ---------------------------------------------------------------- 3. 生成凭据

log "生成 UUID / REALITY 密钥对 / shortId"

UUID="$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
[ -n "$UUID" ] || die "生成 UUID 失败"

# `xray x25519` 的输出格式在版本间变过：
#   旧：Private key: xxx / Public key: yyy
#   新：PrivateKey: xxx  / Password: yyy      ← Password 就是客户端的 pbk
# 两种都认，免得换个 Xray 版本脚本就废。
KEYS="$(xray x25519 2>/dev/null || true)"
PRIVATE_KEY="$(printf '%s\n' "$KEYS" | grep -iE '^[[:space:]]*private[ _]?key' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')"
PUBLIC_KEY="$(printf '%s\n' "$KEYS"  | grep -iE '^[[:space:]]*(public[ _]?key|password)' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')"
[ -n "$PRIVATE_KEY" ] && [ -n "$PUBLIC_KEY" ] || {
  printf '%s\n' "$KEYS" >&2
  die "解析 xray x25519 输出失败（上面是原始输出，格式可能又变了）"
}

SHORT_ID="$(openssl rand -hex 8)"

# ---------------------------------------------------------------- 4. 写配置
#
# streamSettings 里那个字段的名字在 Xray 版本之间变过（network/tcp → method/raw）。
# 与其猜你装的是哪一版，不如两种都写一遍、拿 xray -test 去问它。

BACKUP=""
if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  warn "已备份原有 Xray 配置到 $BACKUP"
fi

mkdir -p "$(dirname "$CONFIG")" /var/log/xray

write_config() {
  # $1 = streamSettings 里的字段名, $2 = 它的值
  cat > "$CONFIG" <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "tag": "reality-vision",
      "listen": "::",
      "port": ${PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID}", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "$1": "$2",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${SNI}:443",
          "serverNames": [ "${SNI}" ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [ "${SHORT_ID}" ]
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
        "inboundTag": [ "reality-vision" ],
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
}

log "写入配置：$CONFIG"
STREAM_FIELD=""
for pair in "method raw" "network tcp"; do
  set -- $pair
  write_config "$1" "$2"
  if xray run -test -config "$CONFIG" >/tmp/xray-reality-test.log 2>&1; then
    STREAM_FIELD="$1"
    log "配置校验通过（streamSettings.$1 = $2）✓"
    break
  fi
done

if [ -z "$STREAM_FIELD" ]; then
  cat /tmp/xray-reality-test.log >&2
  [ -n "$BACKUP" ] && cp "$BACKUP" "$CONFIG"
  die "两种 schema 都没通过校验（上面是最后一次的报错）。多半是 Xray 版本太老，先升级再重跑。"
fi

# ---------------------------------------------------------------- 5. 防火墙

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "放行 TCP ${PORT}（ufw）"
  ufw allow 22/tcp        >/dev/null 2>&1 || true
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
else
  warn "未检测到启用的 ufw（Vultr 默认如此，端口本身是通的）。"
  warn "如果你在服务商面板上配了安全组，请确认已放行 TCP ${PORT}。"
fi

# ---------------------------------------------------------------- 6. 启动 + 验证监听
#
# 服务 active ≠ 端口在听。这是本仓库踩过最贵的一个坑（见 AGENTS.md §0.2），
# 所以这里必须真的去 ss 看一眼，不能只信 systemd。

log "启动 Xray"
systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2

rollback() {
  warn "REALITY 未能启动，正在回滚"
  systemctl disable --now xray >/dev/null 2>&1 || true
  if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    cp "$BACKUP" "$CONFIG"
    warn "已恢复原有 Xray 配置"
  else
    rm -f "$CONFIG"
  fi
}

if ! systemctl is-active --quiet xray; then
  journalctl -u xray -n 30 --no-pager >&2 || true
  rollback
  die "Xray 启动失败（详见上面的日志）。HY2 未受影响。"
fi

log "验证 TCP ${PORT} 是否在监听"
LISTENING=0
for _ in 1 2 3 4 5; do
  if ss -ltnp 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"; then
    LISTENING=1
    break
  fi
  sleep 1
done

if [ "$LISTENING" -ne 1 ]; then
  echo "--- ss -ltnp ---" >&2
  ss -ltnp >&2 || true
  journalctl -u xray -n 30 --no-pager >&2 || true
  rollback
  die "Xray 在运行，但没有监听 TCP ${PORT}。HY2 未受影响。"
fi
log "确认监听中 ✓"

# ---------------------------------------------------------------- 7. 确认 HY2 还活着
#
# 这条检查是这个脚本的底线：加保险的过程本身，绝不能把正在用的那条路弄断。

if [ "$HY2_WAS_ACTIVE" -eq 1 ]; then
  if systemctl is-active --quiet hysteria-server; then
    log "HY2 仍在正常运行 ✓"
  else
    warn "⚠️ HY2 在本次操作后变成了非运行状态，正在拉起"
    systemctl restart hysteria-server || true
    sleep 2
    systemctl is-active --quiet hysteria-server \
      && log "HY2 已恢复 ✓" \
      || warn "HY2 仍未运行，请检查：journalctl -u hysteria-server -n 50 --no-pager -o cat"
  fi
fi

# ---------------------------------------------------------------- 8. 输出

SERVER_IP=""
for probe in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
  SERVER_IP="$(curl -fsS4 --max-time 8 "$probe" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$SERVER_IP" ] && break
done
[ -n "$SERVER_IP" ] || SERVER_IP="YOUR_SERVER_IP"

HY2_PORT="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*:*\([0-9]\{1,5\}\).*/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)"
[ -n "$HY2_PORT" ] || HY2_PORT="24443"

SHARE="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#my-reality"

cat <<EOF

================= REALITY 备用入口部署完成 =================

  服务器      ${SERVER_IP}
  端口        ${PORT}  (TCP)  —— 已确认在监听
  UUID        ${UUID}
  Flow        xtls-rprx-vision
  SNI/target  ${SNI}
  公钥 (pbk)  ${PUBLIC_KEY}
  shortId     ${SHORT_ID}

  出口 IP 没有变化。目标网站看到的还是 ${SERVER_IP}。

  分享链接：

${SHARE}

============================================================

sing-box：把下面这段加进 outbounds 数组（和原来那个 hysteria2 并列），
然后在 route 里按需要选用。tag 用 "reality" 以免和 HY2 那个撞名：

{
  "type": "vless",
  "tag": "reality",
  "server": "${SERVER_IP}",
  "server_port": ${PORT},
  "uuid": "${UUID}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${SNI}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${PUBLIC_KEY}", "short_id": "${SHORT_ID}" }
  }
}

Clash / mihomo：加进 proxies 列表：

  - name: my-reality
    type: vless
    server: ${SERVER_IP}
    port: ${PORT}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${SNI}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}

------------------------------------------------------------

现在这台机器上有两条入口，出口是同一个：

  UDP ${HY2_PORT}   HY2       日常主用（更快）
  TCP ${PORT}   REALITY   UDP 抽风时的备用

后续常用命令：

  systemctl status xray --no-pager        查看运行状态
  journalctl -u xray -n 50 --no-pager     看最近日志
  ss -ltnp | grep ${PORT}                 确认端口在监听

注意：上面的 UUID / 私钥 / shortId 等同于这条入口的钥匙，
不要发到群里、Issue 或公开仓库。

EOF
