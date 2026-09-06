#!/usr/bin/env bash
#
# diagnose-hy2.sh — 查清 HY2「老是断」到底断在哪一层
#
# 这个脚本【只读】，不改任何配置、不重启任何服务。放心跑。
#
# 它回答一个问题：断线是服务器的锅，还是客户端到服务器这段 UDP 路的锅？
# 二者的处理方式完全相反，猜错就会在错误的一侧浪费几天。
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash diagnose-hy2.sh
#   bash diagnose-hy2.sh --hours 72     # 默认看最近 24 小时的日志
#   bash diagnose-hy2.sh --tz 8         # 日志是 UTC，默认按 +8 换算成本地时间
#
# 手机上跑：整个脚本不分页、不需要按键，输出可以直接截图或复制。
#
set -uo pipefail   # 刻意不加 -e：体检脚本要把所有项跑完，不能中途退出

export SYSTEMD_PAGER=cat
export SYSTEMD_COLORS=0

HOURS=24
TZ_OFFSET=8      # 日志是 UTC；这里换算成你的本地时间。中国是 +8

while [ $# -gt 0 ]; do
  case "$1" in
    --hours) HOURS="${2:?--hours 需要一个数字}"; shift 2 ;;
    --tz)    TZ_OFFSET="${2:?--tz 需要一个时区偏移，中国是 8}"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 1 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { printf '请用 root 执行：sudo bash %s\n' "$0" >&2; exit 1; }

CONFIG="/etc/hysteria/config.yaml"
UNIT="hysteria-server.service"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
hdr()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# 结论收集。分两档：能改的排前面，只能绕的排后面。
# 手机屏幕小，用户大概率只看前两条，所以顺序不能按扫描顺序来。
HIGH=()     # 服务端一条命令就能修的
REST=()     # 现象说明、只能绕的
add_high() { HIGH+=("$1"); }
add()      { REST+=("$1"); }

# ---------------------------------------------------------------- 1. 服务活着吗

hdr "1. 服务"

if systemctl is-active --quiet "$UNIT" 2>/dev/null; then
  SINCE="$(systemctl show "$UNIT" -p ActiveEnterTimestamp --value 2>/dev/null)"
  ok "hysteria-server 运行中（自 ${SINCE:-未知}）"
else
  bad "hysteria-server 没在运行"
  add_high "服务本身是停的。先 systemctl start hysteria-server，再看 journalctl -u hysteria-server -n 50 --no-pager -o cat"
fi

# NRestarts 是关键信号：如果服务在反复重启，客户端看到的就是「时好时坏」，
# 而每次重启都会把所有 QUIC 连接打断。
NRESTARTS="$(systemctl show "$UNIT" -p NRestarts --value 2>/dev/null || echo 0)"
if [ "${NRESTARTS:-0}" -gt 0 ] 2>/dev/null; then
  bad "服务已被 systemd 重启过 ${NRESTARTS} 次"
  add_high "服务反复重启 ${NRESTARTS} 次。这本身就是断线原因，先查它为什么退出：journalctl -u hysteria-server -p err -n 50 --no-pager -o cat"
else
  ok "没有被 systemd 重启过（进程一直没崩）"
fi

# ---------------------------------------------------------------- 2. 端口在听吗

hdr "2. 端口"

PORT="$(sed -n 's/^[[:space:]]*listen:[[:space:]]*:*\([0-9]\{1,5\}\).*/\1/p' "$CONFIG" 2>/dev/null | head -1)"
[ -n "$PORT" ] || PORT=24443

if ss -ulnp 2>/dev/null | grep -q ":${PORT}[[:space:]]"; then
  ok "UDP ${PORT} 在监听"
else
  bad "UDP ${PORT} 没有在监听"
  add_high "端口没绑上。服务活着≠端口在听（见 AGENTS.md §0.2）。重装：bash scripts/install-hy2-official.sh"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  if ufw status 2>/dev/null | grep -q "${PORT}/udp"; then
    ok "ufw 已放行 ${PORT}/udp"
  else
    bad "ufw 开着，但没放行 ${PORT}/udp"
    add_high "ufw 挡住了 UDP ${PORT}：ufw allow ${PORT}/udp"
  fi
else
  info "ufw 未启用（Vultr 默认如此，端口本身是通的）"
fi

# ---------------------------------------------------------------- 3. 出口通吗

hdr "3. 出口"

EGRESS="$(curl -fsS4 --max-time 10 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')"
if [ -n "$EGRESS" ]; then
  ok "服务器出口正常，IP = ${EGRESS}"
else
  bad "服务器自己都上不了网"
  add "VPS 出口不通，问题在机房/账单，不在代理配置。"
fi

# 拿 TCP 备用入口当对照组。
#
# 这是整个排查里最省事的一步：两条入口跑在同一台机器、同一个出口，
# 唯一的区别就是 UDP 和 TCP。所以「TCP 一直好、HY2 老断」这个事实本身
# 就排掉了一大半可能性——服务器死机、服务崩掉、流量跑超、磁盘满、
# 机房路由坏、密码错，这些都会让两条一起完蛋。只剩下 UDP 专属的原因。
if systemctl is-active --quiet sing-box 2>/dev/null; then
  ok "TCP 备用入口（sing-box）也在运行 —— 有对照组了"
  info ""
  info "  两条入口同机器、同出口，只差 UDP / TCP 这一点。"
  info "  如果 TCP 一直稳、只有 HY2 断，那么下面这些全部可以排除："
  info "    服务器宕机 / 服务崩溃 / 流量超额 / 磁盘满 / 机房路由 / 密码错"
  info "  剩下的只可能是 UDP 专属原因，也就是第 5、6 节那几项。"
else
  info "TCP 备用入口没在跑，这次没有对照组"
fi

# ---------------------------------------------------------------- 4. 断线日志分析（核心）

hdr "4. 最近 ${HOURS} 小时的断线记录"

LOG="$(mktemp)"; trap 'rm -f "$LOG" "$LOG.ev" "$LOG.rs" "$LOG.se"' EXIT
journalctl -u "$UNIT" --since "-${HOURS}h" --no-pager -o cat >"$LOG" 2>/dev/null

# 注意：grep -c 没匹配时会「打印 0 并且以 1 退出」。写成 `|| echo 0` 会得到
# 两行 "0"，后面的整数比较就会报错。grep -c 本来就一定会打印数字，
# 这里只需要吞掉退出码。
CONNECTED="$(grep -c 'client connected'    "$LOG" 2>/dev/null || true)"
DISCONN="$(  grep -c 'client disconnected' "$LOG" 2>/dev/null || true)"
IDLE="$(     grep -c 'no recent network activity' "$LOG" 2>/dev/null || true)"
CONNECTED="${CONNECTED:-0}"; DISCONN="${DISCONN:-0}"; IDLE="${IDLE:-0}"

info "握手成功 (client connected)     ${CONNECTED} 次"
info "断开     (client disconnected)  ${DISCONN} 次"
info "其中因 QUIC 空闲超时断开        ${IDLE} 次"

if [ "$CONNECTED" -eq 0 ]; then
  bad "这段时间里一次都没握手成功"
  add "包根本没到服务器，或密码不对。不是「断线」，是「连不上」：端口/协议被上游封了，先换端口测。"
elif [ "$IDLE" -gt 0 ] && [ "$IDLE" -ge $((DISCONN / 2)) ]; then
  bad "绝大多数断开都是 QUIC 空闲超时"
  add "主因确认：客户端的 UDP 包中途停止到达，服务端 ${IDLE} 次判定空闲超时。服务器是健康的，问题在 UDP 路径上（见下面第 5、6 节的三个可修项）。"
else
  ok "没有明显的空闲超时模式"
fi

# 断开原因逐条列出。上面只统计了空闲超时这一种，但服务端记下的原因不止一种，
# 而"到底以什么理由断的"才是排查里信息量最大的一项——它直接指向失败的那一层。
info ""
info "断开原因分布（服务端亲口记的）："
grep 'client disconnected' "$LOG" 2>/dev/null \
  | grep -oE '"error": *"[^"]*"' \
  | sed 's/"error": *"//; s/"$//' \
  | sort | uniq -c | sort -rn | head -6 >"$LOG.rs" 2>/dev/null

if [ -s "$LOG.rs" ]; then
  while read -r n reason; do info "  ${n} 次  ${reason}"; done <"$LOG.rs"
  info ""
  info "  timeout: no recent network activity  = 客户端的包不再到达（路径问题）"
  info "  connection refused / closed by peer  = 客户端主动断开（多半是你自己重开了）"
else
  info "  （日志里没有带原因的断开记录）"
fi

# ---- 真正的故障时刻 ----
#
# 这一段是整个脚本最重要的部分，因为服务端日志有个陷阱：
# 手机换个基站，旧连接同样会以 "no recent network activity" 消失，
# 跟真故障【写出来一模一样】，但用户根本感觉不到。
# 把两者混为一谈，就会把一次故障说成四次，把用户的"就死了一次"驳回去。
#
# 判据（拿真实日志校准过）：
#   1. 只看本来就用了 5 分钟以上的会话——短连接多半是手机后台挂起再重连，
#      用户在睡觉或没在用，谈不上"断了"。
#   2. 断开后 10 分钟内如果又建起一条活过 3 分钟的连接，说明客户端自己
#      接上了 → 换基站，无感。
#   3. 接不回来的，才是用户说的"死了"。
#
# 已知局限：分不清「真故障」和「手机深度睡眠之后不再重连」。实测 72 小时报出
# 7 次，其中 4 次落在 00:46 / 02:02 / 04:12 / 04:08，几乎肯定是手机睡了。
# 下结论时只认用户醒着那几个小时的，深夜时段单独看。
: > "$LOG.se"
PREV=""
while read -r ts kind; do
  E="$(date -u -d "$ts" +%s 2>/dev/null || echo 0)"
  [ "$E" = "0" ] && continue
  if [ "$kind" = "C" ]; then
    PREV="$E"
  elif [ -n "$PREV" ]; then
    printf '%s %s %s %s\n' "$PREV" "$E" "$((E - PREV))" "$kind" >>"$LOG.se"
    PREV=""
  fi
done < <(awk '/client connected/    { print $1, "C" }
              /client disconnected/ { print $1, (/no recent network activity/ ? "T" : "X") }' "$LOG" 2>/dev/null)

info ""
info "真正的故障时刻（已排除换基站造成的假断线）："
# 参照点必须是【真实当前时间】，不是最后一条日志的时间。
# 用后者的话，最近一次断线离日志末尾往往只有几十秒，会被下面
# "数据不够" 的保护条件挡掉——而那次恰恰是用户最关心的那一次。
NOW_TS="$(date -u +%s)"
OUTAGES=0
if [ -s "$LOG.se" ]; then
  while read -r st en dur kind; do
    [ "$kind" = "T" ]      || continue    # 客户端主动关闭的不算故障
    [ "$dur" -ge 300 ]     || continue    # 本来就没用起来的不算
    [ $((NOW_TS - en)) -ge 600 ] || continue   # 刚断不到 10 分钟，还看不出接不接得回来
    REC=0
    while read -r s2 _e2 d2 _k2; do
      [ "$s2" -ge "$en" ] && [ "$s2" -lt $((en + 600)) ] && [ "$d2" -ge 180 ] && REC=1
    done <"$LOG.se"
    if [ "$REC" -eq 0 ]; then
      OUTAGES=$((OUTAGES + 1))
      info "  ★ $(date -u -d "@$((en + TZ_OFFSET * 3600))" '+%m-%d %H:%M:%S')  之前正常用了 $((dur / 60)) 分钟，然后断了且接不回来"
    fi
  done <"$LOG.se"
fi
if [ "$OUTAGES" -eq 0 ]; then
  info "  这段时间里没有找到「用着用着断了还接不回来」的情况。"
else
  info ""
  info "  上面的时刻是按 UTC+${TZ_OFFSET} 换算的本地时间（服务器日志本身是 UTC）。"
  info "  不对的话加 --tz 你的时区，例如 --tz 9。"
  add "这段时间里出现了 ${OUTAGES} 次真正的断线（用着用着断掉且接不回来），时刻见上面第 4 节。其余的 disconnected 都是换基站，你不会有感觉。"
fi

# 客户端 IP 是否漂移：移动网络 NAT 映射一变，QUIC 连接必断。
# 这是「明明信号满格却断」的最常见解释。
grep 'client connected' "$LOG" 2>/dev/null \
  | grep -oE '"addr": *"[^"]+"' \
  | sed 's/.*"\([^"]*\)"$/\1/' \
  | sed 's/:[0-9]*$//' | sed 's/^\[//; s/\]$//' \
  | sort | uniq -c | sort -rn >"$LOG.ev" 2>/dev/null

NIP="$(wc -l <"$LOG.ev" 2>/dev/null | tr -d ' ')"
if [ "${NIP:-0}" -gt 1 ]; then
  bad "客户端来源 IP 有 ${NIP} 个（前 5 个）："
  head -5 "$LOG.ev" | while read -r n ip; do info "${n} 次  ${ip}"; done
  add "客户端公网 IP 变了 ${NIP} 次 = 运营商 NAT 映射漂移。每漂一次 QUIC 连接就断一次。加大 maxIdleTimeout 能缓解，根治要走 TCP 备用入口。"
elif [ "${NIP:-0}" -eq 1 ]; then
  ok "客户端来源 IP 稳定（$(awk '{print $2}' "$LOG.ev")）"
fi

# 会话时长：如果每次都在 30 秒左右断，那就是 maxIdleTimeout 默认值在起作用。
if [ "$CONNECTED" -gt 1 ]; then
  info ""
  info "最近几次会话的存活时长："
  grep -E 'client (connected|disconnected)' "$LOG" 2>/dev/null | tail -20 \
  | awk '{print $1, ($0 ~ /disconnected/ ? "D" : "C")}' \
  | while read -r ts kind; do
      epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
      [ "$epoch" = "0" ] && continue
      if [ "$kind" = "C" ]; then
        START="$epoch"
      elif [ -n "${START:-}" ]; then
        printf '      %4d 秒\n' "$((epoch - START))"
        START=""
      fi
    done
  info ""
  info "  普遍在 30 秒上下 → 空闲超时用的还是默认值，跑 tune-hy2.sh"
  info "  长短不一、几分钟到几十分钟 → 更像运营商 QoS 或 NAT 漂移"
fi

# ---------------------------------------------------------------- 5. 配置体检（可修项）

hdr "5. 配置里的可修项"

cfg_has() { grep -qE "^[[:space:]]*$1:" "$CONFIG" 2>/dev/null; }

if [ ! -f "$CONFIG" ]; then
  bad "找不到 $CONFIG"
else
  if cfg_has "ignoreClientBandwidth"; then
    ok "ignoreClientBandwidth 已设置（服务端用 BBR，不听客户端报的带宽）"
  else
    bad "ignoreClientBandwidth 没设置 —— 默认 false"
    add_high "【高优先级】客户端配置里写了 down: 150 Mbps 之类的值，服务端就会启用 Brutal 拥塞控制，按 150 Mbps 硬发、\
故意无视丢包。手机实际带宽远低于这个数时，结果就是持续丢包→卡死→断线，而且特别容易被运营商 QoS 盯上。\
修法：服务端设 ignoreClientBandwidth: true（跑 tune-hy2.sh）。"
  fi

  if grep -qE '^[[:space:]]*maxIdleTimeout:' "$CONFIG" 2>/dev/null; then
    ok "maxIdleTimeout 已显式设置（$(sed -n 's/^[[:space:]]*maxIdleTimeout:[[:space:]]*//p' "$CONFIG" | head -1)）"
  else
    bad "maxIdleTimeout 没设置 —— 默认只有 30 秒"
    add_high "【高优先级】默认 30 秒没收到客户端 UDP 包就判死连接。手机切基站、锁屏、信号抖一下就够 30 秒了。\
放宽到 60~90 秒能吃掉绝大多数瞬断（跑 tune-hy2.sh）。"
  fi

  if cfg_has "obfs"; then
    ok "已开启 obfs 混淆"
  else
    info "未开启 obfs 混淆（裸 QUIC 特征明显，运营商更容易 QoS）"
  fi

  if cfg_has "masquerade"; then ok "已配置 masquerade 伪装"; else info "未配置 masquerade"; fi
fi

# ---------------------------------------------------------------- 6. 系统层（最容易被忽略）

hdr "6. 系统层"

# 6a. UDP 接收缓冲区 —— quic-go 想要 ~7.5MB，Ubuntu 默认只给 208KB。
# 缓冲区满了内核就直接丢包，表现正是「跑着跑着就卡死/断了」。
RMEM="$(sysctl -n net.core.rmem_max 2>/dev/null || echo 0)"
if [ "${RMEM:-0}" -ge 7500000 ] 2>/dev/null; then
  ok "net.core.rmem_max = ${RMEM}（够 quic-go 用）"
else
  bad "net.core.rmem_max = ${RMEM} —— quic-go 需要约 7500000"
  add_high "【高优先级】UDP 接收缓冲区太小（${RMEM} 字节，需要 ~7.5MB）。缓冲区一满内核就丢包，\
高速下载时尤其明显：先卡住，然后整条连接断。一行 sysctl 就能修（跑 tune-hy2.sh）。"
fi

if grep -qi 'buffer size' "$LOG" 2>/dev/null; then
  bad "日志里出现了 quic-go 的缓冲区告警："
  grep -i 'buffer size' "$LOG" | tail -2 | while read -r l; do info "$l"; done
fi

# 6b. UDP 丢包计数
if command -v nstat >/dev/null 2>&1; then
  RCVERR="$(nstat -asz 2>/dev/null | awk '/UdpRcvbufErrors/{print $2}' | head -1)"
  [ -n "${RCVERR:-}" ] && [ "${RCVERR:-0}" -gt 0 ] 2>/dev/null && {
    bad "UdpRcvbufErrors = ${RCVERR}（内核因缓冲区满丢过 UDP 包）"
    add "内核已经实际丢了 ${RCVERR} 个 UDP 包，直接印证上面的缓冲区问题。"
  }
fi

# 6c. 磁盘 —— 日志写满磁盘会让服务写不进日志然后挂掉，是很常见的「莫名其妙就断了」
DISKPCT="$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "$DISKPCT" ] && [ "$DISKPCT" -ge 90 ] 2>/dev/null; then
  bad "根分区已用 ${DISKPCT}%"
  add "磁盘快满了（${DISKPCT}%）。写不进日志会导致服务异常退出。清理：journalctl --vacuum-time=3d"
else
  ok "磁盘可用（已用 ${DISKPCT:-?}%）"
fi

# 6d. OOM —— 小内存 VPS 上 hysteria 被 OOM killer 干掉，表现就是「突然全断然后自己好了」
if dmesg 2>/dev/null | grep -qi 'killed process.*hysteria'; then
  bad "内核 OOM killer 杀过 hysteria 进程"
  add "hysteria 被 OOM 杀掉过。内存不够，考虑加 swap 或调小 QUIC 接收窗口。"
elif journalctl -k --since "-${HOURS}h" --no-pager 2>/dev/null | grep -qi 'out of memory'; then
  bad "最近 ${HOURS} 小时内核报过 out of memory"
  add "系统发生过 OOM，可能误伤了代理进程。加 swap。"
else
  ok "没有 OOM 记录"
fi

info "内存：$(free -h 2>/dev/null | awk '/^Mem:/{print "总 "$2"  已用 "$3"  可用 "$7}')"

# 6e. 流量额度 —— 跑超月流量会被限速到几乎不可用，很像「线路不稳」
if command -v vnstat >/dev/null 2>&1; then
  info "本月流量：$(vnstat -m --oneline 2>/dev/null | cut -d';' -f11 || echo 未知)"
else
  info "未装 vnstat，无法核对月流量（apt install -y vnstat）。请去商家面板确认没跑超额度。"
fi

# ---------------------------------------------------------------- 7. 结论

hdr "结论"

if [ "${#HIGH[@]}" -eq 0 ] && [ "${#REST[@]}" -eq 0 ]; then
  printf '\n  没查出服务器侧的问题。\n\n'
  printf '  服务器是健康的，断线发生在客户端到服务器这段 UDP 路上。\n'
  printf '  按成本从低到高：换端口 → 开 obfs 混淆 → 端口跳跃 → 切 TCP 备用入口 8443。\n\n'
fi

i=1
if [ "${#HIGH[@]}" -gt 0 ]; then
  printf '\n  \033[1m能修的（%d 项）—— 每条都带了具体命令：\033[0m\n\n' "${#HIGH[@]}"
  for f in "${HIGH[@]}"; do
    printf '  %d) %s\n\n' "$i" "$f"
    i=$((i + 1))
  done
fi

if [ "${#REST[@]}" -gt 0 ]; then
  printf '  \033[1m现象说明（%d 项）—— 服务端改不了，只能绕：\033[0m\n\n' "${#REST[@]}"
  for f in "${REST[@]}"; do
    printf '  %d) %s\n\n' "$i" "$f"
    i=$((i + 1))
  done
fi

printf -- '--------------------------------------------------------\n下一步\n\n'
if [ "${#HIGH[@]}" -gt 0 ]; then
  cat <<'EOF'
  修掉上面「能修的」那几项（都是服务端一次性设置，
  客户端不用动，不会让现有配置失效）：

      bash scripts/tune-hy2.sh

  修完仍然断，说明是运营商在限制 UDP，走 TCP 备用入口：

      TCP 8443 / VLESS+TLS，已经装好了，客户端切过去即可
EOF
else
  cat <<'EOF'
  服务端这边已经没有可改的了。还断的话就是运营商在限制 UDP，
  按成本从低到高：

      换端口 → 开 obfs 混淆 → 端口跳跃 → 切 TCP 备用入口 8443

  细节见 docs/stability-and-security.md 成因 4。
EOF
fi
printf -- '--------------------------------------------------------\n'
