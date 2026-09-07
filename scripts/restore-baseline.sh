#!/usr/bin/env bash
#
# restore-baseline.sh — 把服务端拆回「最初搭好那天」的状态
#
# 为什么有这一份：
#
#   2026-09-06 到 09-07 之间，为了排查手机蜂窝上的断线，服务器上陆续加了
#   iptables NAT 重定向、端口跳跃段、Salamander 混淆、Brutal 拥塞控制、
#   VLESS 入口在 443/8443 之间来回搬，两台客户端各自被改成了不同的样子。
#   这些改动互相依赖、又都没有被完整验证，现在的实际状态既不是基线、
#   也不是任何一个假设的完整形态——排查时无法判断"这一条到底是谁造成的"。
#
#   这个脚本把服务端还原成 install-hy2-official.sh + add-tcp-entry.sh
#   本来会生成的那份配置：一个入口一个端口，没有任何转发层。
#   客户端那一半见 examples/client-baseline.md。
#
#   【例外：Salamander 混淆保留】——按用户决定。混淆改变的是流量看起来像
#   什么，和"端口 / 转发 / 拥塞控制"这几样不在同一个维度上，不是这次耦合
#   的来源；而且它已经在两台客户端上跑着。留着它就少一次两端同时改的机会
#   ——两端同时改正是最容易只改一边、然后把"连不上"误判成新故障的地方。
#   混淆密码同样从当前配置里原样沿用。要拆掉请显式加 --no-obfs。
#
# 它会做的（全部可回退，动手前先整机快照到 /root/pre-baseline-<时间戳>/）：
#
#   1. 删掉 nat 表 PREROUTING 里所有 REDIRECT 规则（443 → 24443、
#      20000:30000 → 24443），并清掉它们的持久化
#   2. 重写 /etc/hysteria/config.yaml 为基线：UDP 24443、
#      ignoreClientBandwidth: true（BBR）、maxIdleTimeout 60s，
#      混淆原样保留 —— 两个密码都从当前配置里沿用，不会重新生成
#   3. 把 sing-box 的 VLESS 入口固定回 TCP 8443
#   4. 收敛 sysctl：只留 99-hysteria-udp.conf 一份
#   5. 重启两个服务，等端口真的起来再报成功；起不来自动回滚
#   6. 打印还原后的客户端参数（含密码），照着改两台设备即可
#
# 它【不会】做的：不碰证书、不碰 UUID、不碰 SSH、不改密码、不装任何东西。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash restore-baseline.sh --dry-run    只打印会改什么，不动手
#   bash restore-baseline.sh              真的还原（保留混淆）
#   bash restore-baseline.sh --no-obfs    还原并【拆掉】混淆（两台客户端也要同时删）
#   bash restore-baseline.sh --snapshot   还原并验证通过后，刷新 /root/good 快照
#
set -euo pipefail

HY2_CONFIG="/etc/hysteria/config.yaml"
SB_CONFIG="/etc/sing-box/config.json"
CERT_DIR="/etc/hysteria"
HY2_PORT=24443
SB_PORT=8443
SNI="www.bing.com"

DRY_RUN=0
SNAPSHOT=0
KEEP_OBFS=1   # 默认保留混淆，见文件头的说明

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[36m── %s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1;   shift ;;
    --snapshot) SNAPSHOT=1;  shift ;;
    --no-obfs)  KEEP_OBFS=0; shift ;;
    -h|--help)  sed -n '2,46p' "$0"; exit 0 ;;
    *)          die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
[ -f "$HY2_CONFIG" ] || die "找不到 $HY2_CONFIG。这台机器上没装 Hysteria2？"

# ---------------------------------------------------------------- 0. 取密钥
#
# 密码必须从现有配置里原样读出来沿用。重新生成会让两台客户端同时失联，
# 而用户是纯手机运维，失联之后只能走 Vultr 网页控制台，代价极高。

yaml_value() {
  # yaml_value <文件> <顶层段> <字段>
  awk -v want_section="$2" -v want_key="$3:" '
    /^[^[:space:]#]/ { section = $1; sub(/:$/, "", section) }
    section == want_section && $1 == want_key {
      $1 = ""; sub(/^[[:space:]]+/, "", $0)
      gsub(/^["'\'']|["'\'']$/, "", $0)
      print; exit
    }
  ' "$1"
}

HY2_PASSWORD="$(yaml_value "$HY2_CONFIG" auth password || true)"
[ -n "$HY2_PASSWORD" ] || die "没能从 $HY2_CONFIG 读出 auth.password。请先手动确认配置没坏，不要让脚本猜。"

OBFS_PASSWORD="$(yaml_value "$HY2_CONFIG" obfs password || true)"

# 混淆的四种情况，先定死，后面所有分支都读这两个变量。
# WRITE_OBFS=1 表示新配置里要写 obfs 段（只有"本来就有 + 要保留"才成立，
# 脚本绝不会凭空给你开一个客户端不知道的混淆）。
if [ -n "$OBFS_PASSWORD" ] && [ "$KEEP_OBFS" -eq 1 ]; then
  WRITE_OBFS=1; OBFS_ACTION="保留 Salamander 混淆，密码原样沿用（客户端不用动这一项）"
elif [ -n "$OBFS_PASSWORD" ]; then
  WRITE_OBFS=0; OBFS_ACTION="【删除】Salamander 混淆 —— 两台客户端必须同时删掉 obfs 字段，否则连不上"
else
  WRITE_OBFS=0; OBFS_ACTION="本来就没有混淆，保持没有"
fi

# ---------------------------------------------------------------- 1. 现状盘点

step "1/6  盘点当前状态"

CUR_LISTEN="$(grep -E '^listen:' "$HY2_CONFIG" | head -n1 || echo '(读不到)')"
CUR_ICB="$(grep -E '^ignoreClientBandwidth:' "$HY2_CONFIG" | head -n1 || echo '(未设置，即默认 false = Brutal)')"
CUR_QUIC="$(grep -qE '^quic:' "$HY2_CONFIG" && echo '有 quic: 段' || echo '无 quic: 段（maxIdleTimeout 仍是默认 30s）')"
CUR_OBFS="$([ -n "$OBFS_PASSWORD" ] && echo '已开 Salamander 混淆' || echo '无混淆')"

printf '  HY2  %s\n' "$CUR_LISTEN"
printf '  HY2  %s\n' "$CUR_ICB"
printf '  HY2  %s\n' "$CUR_QUIC"
printf '  HY2  %s\n' "$CUR_OBFS"

NAT_RULES="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -- '-j REDIRECT' || true)"
if [ -n "$NAT_RULES" ]; then
  printf '  NAT  以下转发规则会被删除：\n'
  printf '%s\n' "$NAT_RULES" | sed 's/^/       /'
else
  printf '  NAT  PREROUTING 里没有 REDIRECT 规则 ✓\n'
fi

if [ -f "$SB_CONFIG" ]; then
  printf '  VLESS  %s\n' "$(grep -oE '"listen_port"[[:space:]]*:[[:space:]]*[0-9]+' "$SB_CONFIG" | head -n1 || echo '(读不到)')"
else
  warn "找不到 $SB_CONFIG，跳过 sing-box 部分"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  NAT_COUNT="$(printf '%s' "$NAT_RULES" | grep -c . || true)"
  cat <<EOF

═══════════ --dry-run：本次不做任何改动 ═══════════

会改的：

  HY2 监听端口        → UDP ${HY2_PORT}
  ignoreClientBandwidth → true（BBR。现在是 Brutal，改回来后速度会掉，
                          要重开走 docs/RESTORE-BASELINE.md 加装项二）
  quic.maxIdleTimeout → 60s（基线的一部分，不是对断线的修复）
  udpIdleTimeout      → 90s
  masquerade / acl    → 恢复成 install-hy2-official.sh 的原样
  iptables nat        → 删除 ${NAT_COUNT:-0} 条 REDIRECT 规则，并清掉持久化
  VLESS listen_port   → TCP ${SB_PORT}
  sysctl              → 只留 99-hysteria-udp.conf 一份

不会改的：

  混淆   ${OBFS_ACTION}
  密码   auth.password 原样沿用，不重新生成
  证书   不碰
  UUID   不碰
  SSH    不碰

改完之后你还要做的（服务端改完两端就对不上，节点会暂时不通，这是预期的）：

  两台设备都换成 examples/client-baseline.md 里的同一份配置，整段替换。
  端口回 ${HY2_PORT}，删掉 ports / server_ports / hop-interval 这些跳跃字段，
  obfs 保持现在的样子不用动，VLESS 端口 ${SB_PORT}。

出问题怎么退：动手前会整机快照到 /root/pre-baseline-<时间戳>/
（配置、iptables、两个密码都在里面）；HY2 起不来脚本会自己回滚。

═══════════════════════════════════════════════

确认没问题的话，去掉 --dry-run 再跑一次。
EOF
  exit 0
fi

# ---------------------------------------------------------------- 2. 整机快照

step "2/6  快照当前状态（出问题就从这里回滚）"

BACKUP_DIR="/root/pre-baseline-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp "$HY2_CONFIG" "$BACKUP_DIR/hysteria-config.yaml"
[ -f "$SB_CONFIG" ] && cp "$SB_CONFIG" "$BACKUP_DIR/sing-box-config.json"
iptables-save > "$BACKUP_DIR/iptables.rules" 2>/dev/null || true
ip6tables-save > "$BACKUP_DIR/ip6tables.rules" 2>/dev/null || true
cp /etc/sysctl.d/99-hy2.conf "$BACKUP_DIR/" 2>/dev/null || true
{
  echo "还原前的关键参数（万一要手工恢复）"
  echo "hy2_password  = ${HY2_PASSWORD}"
  echo "obfs_password = ${OBFS_PASSWORD:-（当时没开混淆）}"
} > "$BACKUP_DIR/NOTES.txt"
chmod 700 "$BACKUP_DIR"; chmod 600 "$BACKUP_DIR"/* 2>/dev/null || true
log "已快照到 $BACKUP_DIR"

# ---------------------------------------------------------------- 3. 拆掉转发层
#
# 这一层是"互相打架"的主要来源：客户端连的端口和服务端配置里写的端口不是
# 同一个，日志、ss、配置三者对不上，任何一次排查都要先在脑子里做一次翻译。

step "3/6  删除 iptables 转发层"

drop_redirects() {
  local bin="$1" n=0
  while :; do
    local rule
    rule="$("$bin" -t nat -S PREROUTING 2>/dev/null | grep -m1 -- '-j REDIRECT' || true)"
    [ -n "$rule" ] || break
    # -A PREROUTING ... -j REDIRECT ...  →  -D PREROUTING ... -j REDIRECT ...
    # 删失败必须立刻停：否则规则还在，下一轮循环又读到同一条，会死循环。
    # shellcheck disable=SC2086
    "$bin" -t nat ${rule/#-A/-D} || die "删除失败，停下来人工看：$bin -t nat -S PREROUTING"
    n=$((n + 1))
    [ "$n" -gt 50 ] && die "删了 50 条还没删完，停下来人工看：$bin -t nat -S PREROUTING"
  done
  [ "$n" -gt 0 ] && log "$bin：删除了 $n 条 REDIRECT 规则" || log "$bin：本来就没有 REDIRECT 规则 ✓"
}

drop_redirects iptables
command -v ip6tables >/dev/null 2>&1 && drop_redirects ip6tables

# 规则如果做过持久化，不清就会在下次重启时原样长回来——那正是"以为已经
# 还原了，结果重启后又变回去"的来源。
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 && log "已把清空后的规则写回持久化文件 ✓" || warn "netfilter-persistent save 失败，重启后规则可能长回来"
else
  log "没装 iptables-persistent，规则本来就不会持久化 ✓"
fi

# ---------------------------------------------------------------- 4. HY2 基线配置
#
# 整份重写而不是逐行 sed：现在这份配置经过多轮手改，逐行改只会得到
# 又一个"介于两者之间"的形态，而那正是要消灭的东西。

step "4/6  重写 Hysteria2 配置为基线"

cat > "$HY2_CONFIG" <<EOF
listen: :${HY2_PORT}

tls:
  cert: ${CERT_DIR}/cert.pem
  key: ${CERT_DIR}/key.pem

auth:
  type: password
  password: ${HY2_PASSWORD}
EOF

# 混淆是这份基线里唯一被刻意保留的非基线项（用户决定）。它是两端都要带的
# 字段：服务端有、客户端没有，或者反过来，结果都是"连不上"，而不是"变慢"。
# 所以这里只在本来就有的时候原样写回去，绝不凭空新开。
if [ "$WRITE_OBFS" -eq 1 ]; then
  cat >> "$HY2_CONFIG" <<EOF

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}
EOF
fi

cat >> "$HY2_CONFIG" <<EOF

# ---- 以下是 install-hy2-official.sh 的原始基线，逐条含义见该脚本 ----

# 默认 maxIdleTimeout 只有 30s，手机切基站 / 锁屏很容易超过它。
# 注意：RFC 9000 取两端最小值，只改服务端不会生效——它在这里是基线的一
# 部分，不是对断线问题的修复，别当成修复来验收。
quic:
  maxIdleTimeout: 60s

# true = 忽略客户端自报带宽，服务端用 BBR 自适应。
# false 会启用 Brutal（按客户端申报的速率硬推并无视丢包）。
# 基线是 true。要开 Brutal 请走 docs/RESTORE-BASELINE.md 的"加装项二"，
# 一次只加一项，加完记录实测结果。
ignoreClientBandwidth: true

udpIdleTimeout: 90s

masquerade:
  type: proxy
  proxy:
    url: https://${SNI}/
    rewriteHost: true

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

chmod 600 "$HY2_CONFIG"
if id hysteria >/dev/null 2>&1; then
  chown hysteria:hysteria "$HY2_CONFIG"
else
  warn "未找到 hysteria 用户，配置属主保持 root"
fi

# 重启前先看一眼写进去的东西，这是 docs/NEXT-SESSION.md §1.3 的硬约束。
grep -E '^(listen|ignoreClientBandwidth):' "$HY2_CONFIG" | sed 's/^/  /'
# -F：密码里的 . * [ 等字符不能当正则解释，否则这个校验形同虚设。
grep -qF "password: ${HY2_PASSWORD}" "$HY2_CONFIG" || die "密码没能正确写入，已停下。原文件在 $BACKUP_DIR"

# 混淆这一项两个方向都要验：该有的时候必须有（少了客户端全部失联），
# 该没有的时候必须没有（多了同样全部失联）。
if [ "$WRITE_OBFS" -eq 1 ]; then
  grep -q '^obfs:' "$HY2_CONFIG" || die "混淆段没写进去，已停下。原文件在 $BACKUP_DIR"
  grep -qF "password: ${OBFS_PASSWORD}" "$HY2_CONFIG" || die "混淆密码没写对，已停下。原文件在 $BACKUP_DIR"
  log "混淆保留，密码未变，端口回到 ${HY2_PORT} ✓"
else
  grep -q '^obfs:' "$HY2_CONFIG" && die "配置里还留着 obfs 段，不该发生，请人工检查"
  log "端口回到 ${HY2_PORT}，无混淆 ✓"
fi

# sysctl 收敛成一份。tune-hy2.sh 留下的 99-hy2.conf 与基线那份内容重叠，
# 两份并存时"当前生效值来自哪一份"要靠文件名排序去推，没必要。
if [ -f /etc/sysctl.d/99-hy2.conf ]; then
  rm -f /etc/sysctl.d/99-hy2.conf
  log "删除重复的 /etc/sysctl.d/99-hy2.conf（已备份）"
fi
cat > /etc/sysctl.d/99-hysteria-udp.conf <<'EOF'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true

# ---------------------------------------------------------------- 5. VLESS 回 8443
#
# 8443 而不是 443：本项目的证书是自签的、CN 为 www.bing.com。自签证书挂在
# 443 上是很明显的代理特征，而 443 是全互联网被扫得最狠的端口。
# 2026-09-07 迁到 443 当天日志里就出现了扫描器。拿到域名和真证书之前，
# TCP 入口留在 8443。

step "5/6  把 VLESS 入口固定回 TCP ${SB_PORT}"

if [ -f "$SB_CONFIG" ]; then
  PORT_COUNT="$(grep -cE '"listen_port"' "$SB_CONFIG" || true)"
  if grep -qE "\"listen_port\"[[:space:]]*:[[:space:]]*${SB_PORT}\b" "$SB_CONFIG"; then
    log "已经是 ${SB_PORT} ✓"
  elif [ "$PORT_COUNT" = "1" ]; then
    cp "$SB_CONFIG" "${SB_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i -E "s/(\"listen_port\"[[:space:]]*:[[:space:]]*)[0-9]+/\1${SB_PORT}/" "$SB_CONFIG"
    log "listen_port 已改为 ${SB_PORT}"
  else
    warn "配置里有 ${PORT_COUNT} 个 listen_port，脚本不猜哪个是 VLESS 的。"
    warn "请手工把 VLESS 那个改成 ${SB_PORT}，然后重跑本脚本。"
  fi

  if command -v sing-box >/dev/null 2>&1; then
    sing-box check -c "$SB_CONFIG" >/tmp/sb-check.log 2>&1 \
      && log "sing-box 配置校验通过 ✓" \
      || { cat /tmp/sb-check.log >&2; cp "$BACKUP_DIR/sing-box-config.json" "$SB_CONFIG"; die "sing-box 配置校验失败，已还原原文件"; }
  fi
fi

# ---------------------------------------------------------------- 6. 重启并验证
#
# 服务 active ≠ 端口在听（AGENTS.md §0.2），而重启后 ss 可能比进程绑定快
# 半秒（NEXT-SESSION §0A.8e），所以这里轮询而不是查一次就下结论。

step "6/6  重启并验证端口真的在监听"

rollback_hy2() {
  warn "回滚 Hysteria2 配置到 $BACKUP_DIR/hysteria-config.yaml"
  cp "$BACKUP_DIR/hysteria-config.yaml" "$HY2_CONFIG"
  chmod 600 "$HY2_CONFIG"
  id hysteria >/dev/null 2>&1 && chown hysteria:hysteria "$HY2_CONFIG"
  systemctl restart hysteria-server.service 2>/dev/null || true
}

wait_port() {
  # wait_port <u|t> <端口>
  local flag="$1" port="$2" i
  for i in 1 2 3 4 5 6; do
    ss -"${flag}"lnp 2>/dev/null | grep -q ":${port}[[:space:]]" && return 0
    sleep 1
  done
  return 1
}

systemctl restart hysteria-server.service
if ! wait_port u "$HY2_PORT"; then
  journalctl -u hysteria-server.service -n 30 --no-pager >&2 || true
  rollback_hy2
  die "hysteria-server 没有监听 UDP ${HY2_PORT}，已回滚。原文件在 $BACKUP_DIR"
fi
log "hysteria-server 监听 UDP ${HY2_PORT} ✓"

if [ -f "$SB_CONFIG" ]; then
  systemctl restart sing-box.service 2>/dev/null || true
  if wait_port t "$SB_PORT"; then
    log "sing-box 监听 TCP ${SB_PORT} ✓"
  else
    journalctl -u sing-box -n 20 --no-pager >&2 || true
    warn "sing-box 没有监听 TCP ${SB_PORT}。HY2 不受影响，但备用入口现在是坏的。"
  fi
fi

REMAIN="$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- '-j REDIRECT' || true)"
[ "${REMAIN:-0}" = "0" ] && log "NAT 转发层已清空 ✓" || warn "还剩 ${REMAIN} 条 REDIRECT 规则，请人工检查"

if [ "$SNAPSHOT" -eq 1 ]; then
  mkdir -p /root/good
  cp "$HY2_CONFIG" /root/good/hysteria.yaml
  [ -f "$SB_CONFIG" ] && cp "$SB_CONFIG" /root/good/singbox.json
  chmod 600 /root/good/* 2>/dev/null || true
  log "已把基线写进 /root/good 快照（sh /fix 今后恢复到的就是基线）"
fi

# ---------------------------------------------------------------- 输出

SERVER_IP=""
for probe in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
  SERVER_IP="$(curl -fsS4 --max-time 8 "$probe" 2>/dev/null | tr -d '[:space:]' || true)"
  [ -n "$SERVER_IP" ] && break
done
[ -n "$SERVER_IP" ] || SERVER_IP="YOUR_SERVER_IP"

if [ "$WRITE_OBFS" -eq 1 ]; then
  OBFS_SUMMARY="Salamander，密码 ${OBFS_PASSWORD}（未改动，客户端本来就带着）"
  OBFS_CLIENT_HINT="obfs 保持现状不用动"
else
  OBFS_SUMMARY="无"
  OBFS_CLIENT_HINT="obfs / obfs-password 也要删掉"
fi

cat <<EOF

================= 服务端已回到基线 =================

  HY2     ${SERVER_IP}  UDP ${HY2_PORT}   密码 ${HY2_PASSWORD}
          无端口跳跃、无 NAT 转发、BBR
  混淆    ${OBFS_SUMMARY}
  VLESS   ${SERVER_IP}  TCP ${SB_PORT}
  SNI     ${SNI}（自签证书，客户端必须跳过校验或做指纹固定）

  还原前的一切都在：${BACKUP_DIR}

===================================================

还没做完——客户端还是旧的，现在两端对不上：

  两台设备都要换成 examples/client-baseline.md 里的那份配置，
  【整段替换】，不要在旧配置上逐行改。两台用同一份，不要给单台设备开小灶。

  要点：端口 ${HY2_PORT}，删掉 ports / server_ports / hop-interval 这些
  跳跃字段，${OBFS_CLIENT_HINT}，up/down 按实测填（别虚报）。

换完之后再谈别的。基线没跑通之前加任何东西，都会回到现在这个"谁在起作用
说不清"的局面。加装项的顺序见 docs/RESTORE-BASELINE.md。

EOF
