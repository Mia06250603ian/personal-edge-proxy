#!/usr/bin/env bash
#
# add-ws-tls.sh — 把已有的 VLESS 入口改成 VLESS + WebSocket + TLS（真证书）
#
#   改前：Client -> VLESS + TLS(自签)      TCP 8443 -> VPS   ← 裸 TCP，证书 CN=www.bing.com
#   改后：Client -> VLESS + WS + TLS(真证书) TCP 8443 -> VPS   ← 本脚本
#
#   HY2（hysteria-server / UDP）完全不碰。脚本只读 /etc/hysteria/config.yaml
#   取一个端口号用来打印，不写它、不重启它，最后还会确认它仍然活着。
#
# 为什么是 sing-box 而不是 xray：
#
#   见 AGENTS.md §0.1 和 §0.6。同一台机器上 xray 的 hysteria inbound
#   "服务 active 但端口不 bind"，REALITY 和 VLESS+TLS 两种 inbound 又
#   全部握手失败，且唯一的报错是 "handshake did not complete successfully"，
#   没有任何抓手。sing-box 的同一条入口一次就通，8443 上现在跑的就是它。
#
# 几条刻意保留、不要"顺手优化"掉的东西：
#
#   - 端口沿用现有配置里的值（默认 8443），**不迁 443**。
#   - UUID 从现有配置里读出来沿用，**不重新生成**。
#     （所以这个脚本不需要你把 UUID 贴进命令行，也就没有贴错的机会。）
#   - 协议还是 VLESS，**不换 REALITY**。
#   - 证书路径由 --cert / --key 指定，脚本不签发、不申请、不续期。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash add-ws-tls.sh --cert /etc/ssl/example.pem --key /etc/ssl/example.key
#   bash add-ws-tls.sh --cert ... --key ... --path /ws --dry-run
#
# 回滚：
#
#   脚本每次都会把原配置备份成 config.json.bak.<时间戳>，失败时自动回滚。
#   手工回滚：cp /etc/sing-box/config.json.bak.<时间戳> /etc/sing-box/config.json
#             && systemctl restart sing-box
#
set -euo pipefail

CONFIG="/etc/sing-box/config.json"
CERT=""
KEY=""
WS_PATH="/ws"
PORT=""
SNI=""
SOCKS_PORT=10810
DRY_RUN=0
FORCE=0

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --cert)    CERT="${2:?--cert 需要一个文件路径}";  shift 2 ;;
    --key)     KEY="${2:?--key 需要一个文件路径}";    shift 2 ;;
    --path)    WS_PATH="${2:?--path 需要一个路径}";   shift 2 ;;
    --port)    PORT="${2:?--port 需要一个端口号}";    shift 2 ;;
    --sni)     SNI="${2:?--sni 需要一个域名}";        shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --force)   FORCE=1;   shift ;;
    -h|--help) sed -n '2,45p' "$0"; exit 0 ;;
    *)         die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0 ..."
[ -n "$CERT" ] || die "必须指定 --cert（证书 PEM 的路径）"
[ -n "$KEY" ]  || die "必须指定 --key（私钥 PEM 的路径）"
command -v openssl >/dev/null 2>&1 || die "找不到 openssl"

case "$WS_PATH" in
  /*) : ;;
  *)  die "--path 必须以 / 开头，你给的是：$WS_PATH" ;;
esac

# ---------------------------------------------------------------- 1. 证书

# 手机 SSH 粘贴 PEM 是这一步唯一的风险来源（AGENTS.md §0.11：会静默增删空格）。
# base64 里多一个空格 openssl 就解不开，所以这里在改配置之前把三件事全部验掉：
# 能不能解析、有没有过期、私钥和证书是不是一对。
[ -f "$CERT" ] || die "证书文件不存在：$CERT"
[ -f "$KEY" ]  || die "私钥文件不存在：$KEY"

openssl x509 -in "$CERT" -noout >/dev/null 2>&1 \
  || die "证书解析失败：$CERT（粘贴时被改动过？重新写一次，确认 BEGIN/END 行完整、正文没有多余空格）"
openssl pkey -in "$KEY" -noout >/dev/null 2>&1 \
  || die "私钥解析失败：$KEY（同上）"

openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1 \
  || die "证书已过期：$(openssl x509 -in "$CERT" -noout -enddate)"

CERT_PUB="$(openssl x509 -in "$CERT" -noout -pubkey 2>/dev/null || true)"
KEY_PUB="$(openssl pkey -in "$KEY" -pubout 2>/dev/null || true)"
[ -n "$CERT_PUB" ] && [ "$CERT_PUB" = "$KEY_PUB" ] \
  || die "证书和私钥不是一对。两个文件都重新贴一次，别只贴其中一个。"

log "证书校验通过：$(openssl x509 -in "$CERT" -noout -subject) / $(openssl x509 -in "$CERT" -noout -enddate)"

# SNI 从证书里取，脚本不写死任何域名。
# 注意跳过通配符条目：Cloudflare 源证书的 SAN 通常是 *.example.com 和 example.com
# 两条，第一条拿去当 SNI 是错的。
if [ -z "$SNI" ]; then
  SNI="$(openssl x509 -in "$CERT" -noout -ext subjectAltName 2>/dev/null \
         | tr ',' '\n' | sed -n 's/.*DNS:\([^ ]*\).*/\1/p' | grep -v '^\*' | head -1 || true)"
fi
if [ -z "$SNI" ]; then
  SNI="$(openssl x509 -in "$CERT" -noout -subject 2>/dev/null \
         | sed -n 's/.*CN *= *\([^,/]*\).*/\1/p' | sed 's/[[:space:]]*$//' | head -1 || true)"
fi
case "$SNI" in
  ''|\**) die "没能从证书里取到一个可用的域名（只有通配符或空）。用 --sni 明确指定。" ;;
esac
log "SNI（取自证书）：$SNI"

# ---------------------------------------------------------------- 2. 现状

[ -f "$CONFIG" ] || die "找不到 $CONFIG。这个脚本是改已有的 VLESS 入口，不是从零部署；先跑 add-tcp-entry.sh。"

grep -q '"type": *"vless"' "$CONFIG" \
  || die "$CONFIG 里没有 vless 入口，不敢改。先看一眼：cat $CONFIG"

# 这份配置本来只有一条入口（add-tcp-entry.sh 生成的形状）。多于一条说明
# 现网已经不是那个形状了，整份重写会丢东西——停下来让人先看。
INBOUND_COUNT="$(grep -c '"listen_port"' "$CONFIG" || true)"
if [ "$INBOUND_COUNT" != "1" ] && [ "$FORCE" -ne 1 ]; then
  die "$CONFIG 里有 ${INBOUND_COUNT} 条入口，本脚本会整份重写，可能丢掉别的入口。
     先把配置贴出来看过，确认只有 VLESS 一条再加 --force。"
fi

UUID="$(sed -n 's/.*"uuid": *"\([^"]*\)".*/\1/p' "$CONFIG" | head -1 || true)"
[ -n "$UUID" ] || die "没能从 $CONFIG 里读出 UUID。不生成新的——UUID 换了两台客户端就全断。"
log "沿用现有 UUID：${UUID%%-*}-…（不完整打印）"

if [ -z "$PORT" ]; then
  PORT="$(sed -n 's/.*"listen_port": *\([0-9]\{1,5\}\).*/\1/p' "$CONFIG" | head -1 || true)"
fi
[ -n "$PORT" ] || die "没能读出监听端口，用 --port 指定"
case "$PORT" in ''|*[!0-9]*) die "端口必须是数字：$PORT" ;; esac
log "沿用现有端口：TCP ${PORT}"

# 8443 上如果坐着别的实现（xray），整份重写 sing-box 配置不会有任何效果，
# 而且会表现成"改了没反应"——这正是 AGENTS.md §0.1 那个最贵的失败形态。
OCCUPANT="$(ss -ltnp 2>/dev/null | grep -E "[:.]${PORT}[[:space:]]" \
            | grep -oE 'users:\(\("[^"]+' | grep -oE '"[^"]+$' | tr -d '"' | head -1 || true)"
if [ -n "$OCCUPANT" ] && [ "$OCCUPANT" != "sing-box" ]; then
  die "TCP ${PORT} 现在是 ${OCCUPANT} 在监听，不是 sing-box。
     改 $CONFIG 不会有任何效果。先确认这台机器上 VLESS 到底由谁提供。"
fi

command -v sing-box >/dev/null 2>&1 || die "找不到 sing-box"

HY2_WAS_ACTIVE=0
systemctl is-active --quiet hysteria-server 2>/dev/null && HY2_WAS_ACTIVE=1

if [ "$DRY_RUN" -eq 1 ]; then
  cat <<EOF

========== dry-run：下面这些会做，但现在什么都没改 ==========

  配置文件      $CONFIG（先备份成 .bak.<时间戳>）
  端口          TCP ${PORT}          ← 沿用现状，不迁 443
  协议          VLESS               ← 不变
  传输          WebSocket, path=${WS_PATH}   ← 新增（原来是裸 TCP）
  TLS 证书      ${CERT}
  TLS 私钥      ${KEY}
  SNI           ${SNI}
  UUID          沿用现有的，不重新生成
  重启          systemctl restart sing-box

  不碰：hysteria-server、/etc/hysteria/*、防火墙 443、UUID、协议类型

=============================================================

EOF
  exit 0
fi

# ---------------------------------------------------------------- 3. 权限

chmod 644 "$CERT"
chmod 600 "$KEY"

# 配置 0600 root 是对的（里面有 UUID），但服务如果不是以 root 跑，
# 就会在 systemd 报告启动成功之后才因为读不到文件而退出。
SB_USER="$(systemctl show sing-box -p User --value 2>/dev/null || true)"

# ---------------------------------------------------------------- 4. 写配置

BACKUP="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
cp "$CONFIG" "$BACKUP"
chmod 600 "$BACKUP"
log "已备份原配置到 $BACKUP"

# 私网 ACL 的写法在 sing-box 1.11 前后变过（outbound: block → action: reject）。
# 与其猜版本，不如两种都写一遍拿 sing-box check 去问它——add-tcp-entry.sh 同样的做法。
write_config() {
  local route_block outbounds
  if [ "$1" = "modern" ]; then
    route_block='"route": { "rules": [ { "ip_is_private": true, "action": "reject" } ], "final": "direct" }'
    outbounds='{ "type": "direct", "tag": "direct" }'
  else
    route_block='"route": { "rules": [ { "ip_is_private": true, "outbound": "block" } ], "final": "direct" }'
    outbounds='{ "type": "direct", "tag": "direct" }, { "type": "block", "tag": "block" }'
  fi

  cat > "$CONFIG" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
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
        "certificate_path": "${CERT}",
        "key_path": "${KEY}"
      },
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "outbounds": [ ${outbounds} ],
  ${route_block}
}
EOF
  chmod 600 "$CONFIG"
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
[ -n "$SHAPE" ] || { cat /tmp/sb-check.log >&2; cp "$BACKUP" "$CONFIG"; die "配置校验失败，已还原原配置"; }

# 重启之前把写进去的内容再确认一遍（AGENTS.md §0.11 第 3 条）
grep -q "\"path\": \"${WS_PATH}\"" "$CONFIG" || { cp "$BACKUP" "$CONFIG"; die "path 没写进去，已还原"; }
grep -q "\"certificate_path\": \"${CERT}\"" "$CONFIG" || { cp "$BACKUP" "$CONFIG"; die "证书路径没写进去，已还原"; }

if [ -n "$SB_USER" ] && [ "$SB_USER" != "root" ] && id "$SB_USER" >/dev/null 2>&1; then
  log "sing-box 以 ${SB_USER} 运行，移交配置和私钥属主"
  chown "$SB_USER" "$CONFIG" "$BACKUP" 2>/dev/null || true
  chown "$SB_USER" "$KEY" 2>/dev/null || true
fi

# ---------------------------------------------------------------- 5. 启动

rollback() {
  warn "正在回滚到 $BACKUP"
  cp "$BACKUP" "$CONFIG"
  systemctl restart sing-box >/dev/null 2>&1 || true
}

log "重启 sing-box"
systemctl restart sing-box
sleep 2

systemctl is-active --quiet sing-box || {
  journalctl -u sing-box -n 30 --no-pager -o cat >&2 || true
  rollback
  die "sing-box 启动失败（详见上面的日志）。HY2 未受影响。"
}

# ss 可能比进程 bind 快半秒，直接判会误报故障（NEXT-SESSION §0A.8e 踩过）。
LISTENING=0
for _ in 1 2 3 4 5; do
  ss -ltnp 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]" && { LISTENING=1; break; }
  sleep 1
done
[ "$LISTENING" -eq 1 ] || { ss -ltnp >&2; rollback; die "没有监听 TCP ${PORT}"; }
log "确认监听中 ✓"

# ---------------------------------------------------------------- 6. 自己连自己验一次
#
# 端口在监听 ≠ 这条入口能用。AGENTS.md §0.6 那条规则：任何加/改入口的脚本
# 都必须真的从这条入口过一次请求，过不去就回滚。

log "自测：通过这条入口请求一次出口 IP"

SELFTEST_DIR="$(mktemp -d)"
chmod 700 "$SELFTEST_DIR"
SELFTEST="$SELFTEST_DIR/client.json"
TEST_PID=""
cleanup_selftest() {
  [ -n "$TEST_PID" ] && kill "$TEST_PID" 2>/dev/null
  rm -rf "$SELFTEST_DIR"
}
trap cleanup_selftest EXIT

# insecure: true 是因为这里连的是 127.0.0.1，证书上的域名对不上回环地址，
# 与证书本身是不是可信无关。客户端那边是否需要跳过校验见脚本末尾的说明。
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
      "tls": { "enabled": true, "server_name": "${SNI}", "insecure": true },
      "transport": { "type": "ws", "path": "${WS_PATH}" }
    }
  ]
}
EOF

sing-box run -c "$SELFTEST" >"$SELFTEST_DIR/client.log" 2>&1 &
TEST_PID=$!
sleep 2
SELF_IP="$(curl -fsS --max-time 12 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/dev/null || true)"
kill "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true
TEST_PID=""

if [ -z "$SELF_IP" ]; then
  echo "--- 测试客户端日志 ---" >&2
  tail -20 "$SELFTEST_DIR/client.log" >&2 2>/dev/null || true
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

HY2_PORT="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*:*\([0-9]\{1,5\}\).*/\1/p' /etc/hysteria/config.yaml 2>/dev/null | head -1)"
[ -n "$HY2_PORT" ] || HY2_PORT="24443"

cat <<EOF

========== VLESS + WS + TLS 已生效（已自测通过）==========

  端口        ${PORT}  (TCP)     ← 没有改动
  协议        VLESS             ← 没有改动
  传输        WebSocket, path = ${WS_PATH}
  TLS 证书    ${CERT}
  SNI / 域名  ${SNI}
  UUID        沿用原来那个，没有换

  出口 IP 仍然是 ${SELF_IP}。
  HY2：UDP ${HY2_PORT}，本次未改动。

==========================================================

客户端两端必须同时改：服务端已经是 WS 了，还写着裸 TCP 的客户端会直接连不上。
配置见 docs/vless-ws-tls-cloudflare.md 的"客户端"一节。

回滚：
  cp ${BACKUP} ${CONFIG} && systemctl restart sing-box

EOF
