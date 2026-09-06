#!/usr/bin/env bash
#
# install-hy2-official.sh — 用 Hysteria2 官方服务端部署 Profile A
#
#   Client -> Hysteria2 (官方实现) -> VPS -> Direct
#
# 与 install-hy2.sh 的区别：
#
#   install-hy2.sh           用 Xray 的 hysteria inbound
#   install-hy2-official.sh  用 hysteria.network 的官方服务端   ← 本脚本
#
# 为什么有这一份：Xray 26.3.x 的 hysteria inbound 存在已知问题
# （见 XTLS/Xray-core #5921、#5619），实测出现过服务已启动但根本
# 不监听 UDP 端口、或监听后不回包的情况。官方实现没有这些问题。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash install-hy2-official.sh
#   bash install-hy2-official.sh --port 24443
#   bash install-hy2-official.sh --password 'YourNodePassword'
#
# 卸载：
#
#   bash install-hy2-official.sh --uninstall
#
set -euo pipefail

PORT=24443
SNI="www.bing.com"
PASSWORD=""
CONFIG="/etc/hysteria/config.yaml"
CERT_DIR="/etc/hysteria"
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
  log "停止并卸载 Hysteria2"
  systemctl disable --now hysteria-server.service 2>/dev/null || true
  bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
  rm -f "$CERT_DIR/cert.pem" "$CERT_DIR/key.pem"
  log "已卸载。防火墙规则未自动删除，如需清理：ufw delete allow ${PORT}/udp"
  exit 0
fi

command -v apt-get >/dev/null 2>&1 || die "这个脚本只支持 Ubuntu / Debian（需要 apt-get）"

case "$PORT" in
  ''|*[!0-9]*) die "端口必须是数字：$PORT" ;;
esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "端口超出范围：$PORT"

if [ -n "$PASSWORD" ]; then
  case "$PASSWORD" in
    *[!A-Za-z0-9._-]*) die "--password 只能包含字母、数字和 . _ - （避免破坏配置与分享链接）" ;;
  esac
  [ "${#PASSWORD}" -ge 8 ] || die "--password 至少 8 位"
elif [ -f "$CONFIG" ] && grep -qE '^[[:space:]]*password:[[:space:]]*\S' "$CONFIG"; then
  # 重跑脚本（例如为了加固配置）时保留现有密码，否则每次重跑都会让
  # 已经配好的客户端全部失效。要换密码请显式传 --password。
  PASSWORD="$(sed -n 's/^[[:space:]]*password:[[:space:]]*//p' "$CONFIG" | head -1 | tr -d '"'\''[:space:]')"
  [ -n "$PASSWORD" ] || die "从现有配置中读取密码失败"
  REUSED_PASSWORD=1
else
  PASSWORD="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 24)"
  [ -n "$PASSWORD" ] || die "生成密码失败"
fi
REUSED_PASSWORD="${REUSED_PASSWORD:-0}"

# ---------------------------------------------------------------- 1. 依赖

log "安装依赖"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl openssl ca-certificates iproute2 >/dev/null

# ---------------------------------------------------------------- 2. 如果之前装过 Xray 版，先让路
#
# 只在 Xray 真的占着本脚本要用的 UDP 端口时才停它。早期版本是无条件
# 停 Xray，那会误伤 add-reality.sh 装的 REALITY 备用入口——它跑在
# TCP 443，跟 HY2 井水不犯河水，却会被这一步顺手关掉，而且要等到
# UDP 出问题、想切备用入口的那天才会发现。

if systemctl is-active --quiet xray 2>/dev/null; then
  if ss -ulnp 2>/dev/null | grep -E ":${PORT}[[:space:]]" | grep -q xray; then
    warn "Xray 正占用 UDP ${PORT}，先停掉以免冲突（配置保留，未卸载）"
    systemctl disable --now xray >/dev/null 2>&1 || true
  else
    log "检测到 Xray 在运行，但没占用 UDP ${PORT}（多半是 REALITY 备用入口），保持不动"
  fi
fi

# ---------------------------------------------------------------- 3. 安装 Hysteria2 官方服务端

log "安装 Hysteria2 官方服务端"
bash <(curl -fsSL https://get.hy2.sh/)

command -v hysteria >/dev/null 2>&1 || die "Hysteria 安装失败，请检查上面的输出"
log "已安装：$(hysteria version 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 4. 自签证书

# 说明：自签证书，所以客户端必须开启「跳过证书验证 / insecure」。
# HY2 的身份验证靠密码，自签不影响密码安全与流量加密；代价是客户端
# 无法验证服务端身份。有域名的话建议改用 ACME 签发的真实证书。

log "生成自签证书（SNI: ${SNI}）"
mkdir -p "$CERT_DIR"
# 先生成到临时目录，验证含 SAN 之后再原子替换。
# 直接写目标路径的话，生成失败会毁掉现在还能用的那张证书——
# 而这台机器上可能正跑着一条依赖它的入口。
CERT_TMP="$(mktemp -d)"
openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
  -keyout "$CERT_TMP/key.pem" -out "$CERT_TMP/cert.pem" \
  -subj "/CN=${SNI}" -addext "subjectAltName=DNS:${SNI}" \
  -days 3650 >/dev/null 2>&1
if ! openssl x509 -in "$CERT_TMP/cert.pem" -noout -text 2>/dev/null | grep -q "DNS:${SNI}"; then
  rm -rf "$CERT_TMP"
  die "证书生成失败或缺少 SAN。原有证书未被改动。"
fi
mv "$CERT_TMP/cert.pem" "$CERT_DIR/cert.pem"
mv "$CERT_TMP/key.pem" "$CERT_DIR/key.pem"
rm -rf "$CERT_TMP"

# 官方 systemd 单元以 hysteria 用户运行，证书要让它读得到
if id hysteria >/dev/null 2>&1; then
  chown hysteria:hysteria "$CERT_DIR/key.pem" "$CERT_DIR/cert.pem"
fi
chmod 600 "$CERT_DIR/key.pem"
chmod 644 "$CERT_DIR/cert.pem"

# ---------------------------------------------------------------- 5. 配置

BACKUP=""
if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  warn "已备份原有配置到 $BACKUP"
  [ "$REUSED_PASSWORD" -eq 1 ] && log "沿用现有密码（要换密码请加 --password）"
fi

log "写入配置：$CONFIG"
cat > "$CONFIG" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_DIR}/cert.pem
  key: ${CERT_DIR}/key.pem

auth:
  type: password
  password: ${PASSWORD}

# ---- 稳定性设置。默认值在移动网络上会导致频繁断线，详见 docs/stability-and-security.md ----

# 默认 maxIdleTimeout 只有 30s：手机切基站、锁屏、信号抖动很容易超过它，
# 连接就被判死，表现为"信号满格却断线"。放宽到 60s 能吃掉绝大多数瞬断。
quic:
  maxIdleTimeout: 60s

# 不听客户端自报的带宽。客户端配置里的 down: 150 Mbps 会让服务端启用
# Brutal 拥塞控制，按该速率硬发并【故意无视丢包】；手机实际带宽达不到时，
# 多出来的全是丢包，表现就是卡死然后断线，还特别容易被运营商 QoS 盯上。
# 设为 true 后服务端改用 BBR，按实际链路自适应。
ignoreClientBandwidth: true

# UDP 会话（游戏、DNS、QUIC）的空闲回收时间，默认 60s。
udpIdleTimeout: 90s

# 让主动探测这个端口的人看到的是 bing，而不是一个代理服务端
masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/
    rewriteHost: true

# 禁止经隧道访问 VPS 所在机房的私网 / 回环 / 链路本地地址。
# 单人自用时这主要是纵深防御：万一密码外泄，别人也不能拿你的节点
# 当跳板去探测机房内网。规则按顺序匹配，最后必须有 direct(all) 兜底，
# 否则匹配不到任何规则的流量会被丢弃。
acl:
  inline:
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(127.0.0.0/8)
    - reject(169.254.0.0/16)
    - reject(::1/128)
    - reject(fc00::/7)
    - reject(fe80::/10)
    - direct(all)
EOF

# 官方 systemd 单元以 hysteria 用户运行，配置文件必须让它读得到。
# 只 chmod 600 而不改属主的话，服务会以
#   FATAL failed to read server config ... permission denied
# 退出——而且是在 systemd 报告启动之后才失败。
chmod 600 "$CONFIG"
if id hysteria >/dev/null 2>&1; then
  chown hysteria:hysteria "$CONFIG"
else
  warn "未找到 hysteria 用户，配置属主保持 root"
fi

# ---------------------------------------------------------------- 5.5 UDP 缓冲区
#
# quic-go（Hysteria2 的 QUIC 实现）需要约 7.5MB 的 UDP 接收缓冲区，
# Ubuntu 默认只给 208KB。缓冲区一满内核就直接丢弃新到的包，表现为
# 高速传输时先卡住、然后整条连接断掉。这一步比任何客户端调参都管用。

log "调大 UDP 接收缓冲区"
cat > /etc/sysctl.d/99-hysteria-udp.conf <<'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true
RMEM="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
if [ "${RMEM:-0}" -ge 7500000 ] 2>/dev/null; then
  log "net.core.rmem_max = ${RMEM} ✓"
else
  warn "UDP 缓冲区没调上去（当前 ${RMEM}），高速传输时可能丢包"
fi

# ---------------------------------------------------------------- 6. 防火墙

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  log "放行 UDP ${PORT}（ufw）"
  ufw allow 22/tcp        >/dev/null 2>&1 || true
  ufw allow "${PORT}/udp" >/dev/null 2>&1 || true
else
  warn "未检测到启用的 ufw（Vultr 默认如此，端口本身是通的）。"
  warn "如果你在服务商面板上配了安全组，请确认已放行 UDP ${PORT}。"
fi

# ---------------------------------------------------------------- 7. 启动

# 如果这台机器上已经有一个能用的节点，任何一次改动都不该把它弄挂。
# 新配置起不来或不监听时，自动恢复到刚才备份的那份并重启，让用户
# 停在"和改动前一样能用"的状态，而不是一个坏掉的服务。
rollback() {
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || return 1
  warn "正在回滚到改动前的配置：$BACKUP"
  cp "$BACKUP" "$CONFIG"
  chmod 600 "$CONFIG"
  id hysteria >/dev/null 2>&1 && chown hysteria:hysteria "$CONFIG"
  systemctl restart hysteria-server.service 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet hysteria-server.service; then
    warn "已回滚，节点恢复到改动前的状态（本次加固未生效）"
  else
    warn "回滚后服务仍未启动，请手动检查：journalctl -u hysteria-server -n 50"
  fi
  return 0
}

log "启动 hysteria-server"
systemctl enable hysteria-server.service >/dev/null 2>&1 || true
systemctl restart hysteria-server.service
sleep 3

if ! systemctl is-active --quiet hysteria-server.service; then
  journalctl -u hysteria-server.service -n 30 --no-pager >&2 || true
  rollback || true
  die "hysteria-server 启动失败（详见上面的日志）"
fi

# ---------------------------------------------------------------- 8. 真正验证端口在监听
#
# 这一步是这份脚本存在的理由之一：上一版脚本只检查了 systemd 说服务
# "active" 就宣布成功，结果服务确实活着、却根本没绑定 UDP 端口，
# 排查时白白绕了一大圈。服务活着 ≠ 端口在听。

log "验证 UDP ${PORT} 是否在监听"
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
  journalctl -u hysteria-server.service -n 30 --no-pager >&2 || true
  rollback || true
  die "服务在运行，但没有监听 UDP ${PORT}。请把上面的输出发出来排查。"
fi

log "确认监听中 ✓"

# ---------------------------------------------------------------- 9. 输出

SERVER_IP=""
for probe in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
  SERVER_IP="$(curl -fsS4 --max-time 8 "$probe" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$SERVER_IP" ] && break
done
[ -n "$SERVER_IP" ] || SERVER_IP="YOUR_SERVER_IP"

SHARE="hysteria2://${PASSWORD}@${SERVER_IP}:${PORT}/?insecure=1&sni=${SNI}#my-hy2"

cat <<EOF

================= 部署完成（官方 Hysteria2）=================

  服务器      ${SERVER_IP}
  端口        ${PORT}  (UDP)  —— 已确认在监听
  密码        ${PASSWORD}
  SNI         ${SNI}
  跳过证书验证 必须开启（本脚本用的是自签证书）

  分享链接：

${SHARE}

============================================================

后续常用命令：

  systemctl status hysteria-server        查看运行状态
  systemctl restart hysteria-server       重启
  journalctl -u hysteria-server -n 50     看最近日志
  ss -ulnp | grep ${PORT}                 确认端口在监听

注意：上面的密码等同于你这台节点的钥匙，不要发到群里、Issue 或公开仓库。

EOF
