#!/usr/bin/env bash
#
# tune-hy2.sh — 修掉 HY2「老是断」的三个服务端成因
#
# 只动服务端，客户端一个字都不用改，现有配置不会失效。
#
# 修三件事：
#
#   1. maxIdleTimeout 30s → 60s
#      默认 30 秒收不到客户端的 UDP 包就把连接判死。手机切基站、锁屏、
#      电梯里信号抖一下，30 秒轻轻松松就过去了。这是「信号满格却断线」
#      最常见的解释。
#
#   2. ignoreClientBandwidth: true
#      客户端配置里那句 down: 150 Mbps 不是给自己看的——它会让服务端
#      切到 Brutal 拥塞控制，按 150 Mbps 硬发并且【故意无视丢包】。
#      手机实际只有 30 Mbps 时，多出来的全是丢包，表现就是卡死然后断，
#      而且这种持续高速 UDP 恰好是运营商 QoS 最爱盯的特征。
#      设成 true 之后服务端改用 BBR，按实际链路自适应。
#
#   3. net.core.rmem_max 208KB → 16MB
#      quic-go 想要约 7.5MB 的 UDP 接收缓冲区，Ubuntu 默认只给 208KB。
#      缓冲区一满内核就直接丢包——正是「下载跑一会儿就卡住然后断」。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash tune-hy2.sh
#   bash tune-hy2.sh --idle 90s        # 想更宽容一点
#   bash tune-hy2.sh --no-pmtud        # 路径 MTU 探测在某些移动网络上会黑洞
#
# 改完会自己连自己跑一次真实请求来验证；验证不过就自动回滚到改动前的配置。
#
set -euo pipefail

CONFIG="/etc/hysteria/config.yaml"
CERT_DIR="/etc/hysteria"
UNIT="hysteria-server.service"
SYSCTL_FILE="/etc/sysctl.d/99-hysteria-udp.conf"

IDLE="60s"
UDP_IDLE="90s"
NO_PMTUD=0

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --idle)     IDLE="${2:?--idle 需要一个时长，例如 90s}"; shift 2 ;;
    --no-pmtud) NO_PMTUD=1; shift ;;
    -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
    *)          die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
[ -f "$CONFIG" ] || die "找不到 $CONFIG。这个脚本是给已经装好的 HY2 用的；还没装请先跑 install-hy2-official.sh"

export SYSTEMD_PAGER=cat

# ---------------------------------------------------------------- 1. 读出现有配置
#
# 绝对不能丢掉的三样：密码、端口、obfs。任何一样对不上，所有客户端立刻失效。

PORT="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*:*\([0-9]\{1,5\}\).*/\1/p' "$CONFIG" | head -1)"
[ -n "$PORT" ] || die "读不出监听端口，请检查 $CONFIG"

PASSWORD="$(sed -n '/^auth:/,/^[^[:space:]]/s/^[[:space:]]*password:[[:space:]]*//p' "$CONFIG" | head -1 | tr -d '"'\''[:space:]')"
[ -n "$PASSWORD" ] || die "读不出节点密码，请检查 $CONFIG"

SNI="$(sed -n 's|^[[:space:]]*url:[[:space:]]*https://\([^/]*\)/.*|\1|p' "$CONFIG" | head -1)"
[ -n "$SNI" ] || SNI="www.bing.com"

OBFS_TYPE="$(sed -n '/^obfs:/,/^[^[:space:]#]/s/^[[:space:]]*type:[[:space:]]*//p' "$CONFIG" | head -1 | tr -d '"'\''[:space:]')"
OBFS_PASS="$(sed -n '/^obfs:/,/^[^[:space:]#]/s/^[[:space:]]*password:[[:space:]]*//p' "$CONFIG" | head -1 | tr -d '"'\''[:space:]')"

log "读到现有配置：端口 ${PORT}，SNI ${SNI}，密码已保留"
if [ -n "$OBFS_TYPE" ] && [ -n "$OBFS_PASS" ]; then
  log "检测到 obfs（${OBFS_TYPE}），会原样保留"
fi

CERT="$(sed -n '/^tls:/,/^[^[:space:]#]/s/^[[:space:]]*cert:[[:space:]]*//p' "$CONFIG" | head -1)"
KEY="$( sed -n '/^tls:/,/^[^[:space:]#]/s/^[[:space:]]*key:[[:space:]]*//p'  "$CONFIG" | head -1)"
[ -n "$CERT" ] || CERT="${CERT_DIR}/cert.pem"
[ -n "$KEY"  ] || KEY="${CERT_DIR}/key.pem"

# ---------------------------------------------------------------- 2. UDP 缓冲区

log "调大 UDP 接收缓冲区（quic-go 需要约 7.5MB，系统默认 208KB）"
OLD_RMEM="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
cat > "$SYSCTL_FILE" <<'EOF'
# quic-go（Hysteria2 的 QUIC 实现）需要大得多的 UDP 缓冲区。
# 缓冲区满了内核会直接丢弃新到的包，表现为高速传输时卡死并断线。
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true
NEW_RMEM="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
if [ "${NEW_RMEM:-0}" -ge 7500000 ] 2>/dev/null; then
  log "net.core.rmem_max: ${OLD_RMEM} → ${NEW_RMEM} ✓"
else
  warn "缓冲区没调上去（当前 ${NEW_RMEM}），继续，但这一项没生效"
fi

# ---------------------------------------------------------------- 3. 写配置

BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONFIG" "$BACKUP"
chmod 600 "$BACKUP"
log "已备份原配置到 $BACKUP"

PMTUD="false"
[ "$NO_PMTUD" -eq 1 ] && PMTUD="true"

OBFS_BLOCK=""
if [ -n "$OBFS_TYPE" ] && [ -n "$OBFS_PASS" ]; then
  OBFS_BLOCK="$(printf 'obfs:\n  type: %s\n  %s:\n    password: %s\n' "$OBFS_TYPE" "$OBFS_TYPE" "$OBFS_PASS")"
fi

log "写入调优后的配置"
{
cat <<EOF
listen: :${PORT}

tls:
  cert: ${CERT}
  key: ${KEY}

auth:
  type: password
  password: ${PASSWORD}

EOF

[ -n "$OBFS_BLOCK" ] && printf '%s\n\n' "$OBFS_BLOCK"

cat <<EOF
# ---- 稳定性调优（tune-hy2.sh 写入）----

# 默认 30s 太短：手机切基站/锁屏/信号抖动很容易超过它，连接就被判死。
quic:
  maxIdleTimeout: ${IDLE}
  disablePathMTUDiscovery: ${PMTUD}

# 不听客户端自报的带宽。客户端写 down: 150 Mbps 会让服务端启用 Brutal
# 拥塞控制，按该速率硬发且无视丢包；手机带宽达不到时就是持续丢包→断线。
# 设为 true 后服务端改用 BBR，按实际链路自适应。
ignoreClientBandwidth: true

# UDP 会话（游戏、DNS、QUIC）的空闲回收时间，默认 60s。
udpIdleTimeout: ${UDP_IDLE}

# 让主动探测这个端口的人看到的是 bing，而不是一个代理服务端
masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/
    rewriteHost: true

# 禁止经隧道访问 VPS 所在机房的私网 / 回环 / 链路本地地址。
# 规则按顺序匹配，最后必须有 direct(all) 兜底。
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
} > "$CONFIG"

chmod 600 "$CONFIG"
id hysteria >/dev/null 2>&1 && chown hysteria:hysteria "$CONFIG"

# ---------------------------------------------------------------- 4. 重启 + 回滚

rollback() {
  warn "正在回滚到改动前的配置"
  cp "$BACKUP" "$CONFIG"
  chmod 600 "$CONFIG"
  id hysteria >/dev/null 2>&1 && chown hysteria:hysteria "$CONFIG"
  systemctl restart "$UNIT" >/dev/null 2>&1 || true
  sleep 2
  if systemctl is-active --quiet "$UNIT"; then
    warn "已回滚，节点恢复到改动前的状态（本次调优未生效）"
  else
    warn "回滚后服务仍未启动：journalctl -u hysteria-server -n 50 --no-pager -o cat"
  fi
}

log "重启 hysteria-server"
systemctl restart "$UNIT"
sleep 3

if ! systemctl is-active --quiet "$UNIT"; then
  journalctl -u "$UNIT" -n 30 --no-pager -o cat >&2 || true
  rollback
  die "服务没能启动，已回滚"
fi

LISTENING=0
for _ in 1 2 3 4 5; do
  ss -ulnp 2>/dev/null | grep -q ":${PORT}[[:space:]]" && { LISTENING=1; break; }
  sleep 1
done
[ "$LISTENING" -eq 1 ] || { ss -ulnp >&2 || true; rollback; die "没有监听 UDP ${PORT}，已回滚"; }
log "确认监听中 ✓"

# ---------------------------------------------------------------- 5. 自己连自己验一次
#
# 端口在监听 ≠ 隧道能用（AGENTS.md §0.2）。用 hysteria 自带的客户端模式
# 走一次真实请求，通了才算改对。

log "自测：通过隧道请求一次出口 IP"
TMP="$(mktemp -d)"
chmod 700 "$TMP"
SELFTEST="$TMP/client.yaml"
cleanup() { [ -n "${TEST_PID:-}" ] && kill "$TEST_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

{
  printf 'server: 127.0.0.1:%s\nauth: %s\n' "$PORT" "$PASSWORD"
  [ -n "$OBFS_BLOCK" ] && printf '%s\n' "$OBFS_BLOCK"
  printf 'tls:\n  sni: %s\n  insecure: true\nsocks5:\n  listen: 127.0.0.1:10809\n' "$SNI"
} > "$SELFTEST"
chmod 600 "$SELFTEST"

hysteria client -c "$SELFTEST" >"$TMP/client.log" 2>&1 &
TEST_PID=$!
sleep 3
SELF_IP="$(curl -fsS --max-time 15 -x socks5h://127.0.0.1:10809 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true
TEST_PID=""

if [ -z "$SELF_IP" ]; then
  echo "--- 测试客户端日志 ---" >&2
  tail -20 "$TMP/client.log" >&2 2>/dev/null || true
  echo "--- 服务端日志 ---" >&2
  journalctl -u "$UNIT" -n 20 --no-pager -o cat >&2 2>/dev/null || true
  rollback
  die "自测没通过，已回滚。节点仍是改动前的状态。"
fi

log "自测通过 ✓ 出口 IP = ${SELF_IP}"

# ---------------------------------------------------------------- 6. 输出

cat <<EOF

================= 调优完成 =================

  已生效（客户端不用改任何东西）：

    maxIdleTimeout          30s → ${IDLE}
    ignoreClientBandwidth   false → true   （服务端改用 BBR）
    udpIdleTimeout          60s → ${UDP_IDLE}
    disablePathMTUDiscovery ${PMTUD}
    net.core.rmem_max       ${OLD_RMEM} → ${NEW_RMEM}

  密码、端口、obfs 全部保留，现有客户端继续可用。
  改动前的配置备份在：${BACKUP}

============================================

顺带把客户端也改一下（可选，但建议）：

  客户端里的 up / down（sing-box 是 up_mbps / down_mbps）现在已经被
  服务端忽略了。建议直接删掉这两行，或填成接近真实带宽的值，
  免得以后换服务端时又踩一次 Brutal 的坑。

观察几天，还断的话跑：

  bash scripts/diagnose-hy2.sh --hours 72

如果 diagnose 显示服务器全部正常、断线仍集中在 UDP 路径上，
那就是运营商在限制 UDP —— 切 TCP 备用入口（8443 / VLESS+TLS）。

EOF
