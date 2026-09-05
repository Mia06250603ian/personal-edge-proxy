#!/usr/bin/env bash
#
# test-reality.sh — 让服务器用它自己的 Xray 当客户端，连一次自己的 REALITY 入口
#
# 为什么需要这个：
#
#   REALITY 握手失败时，服务端日志永远只有一句
#
#     REALITY: processed invalid connection ... handshake did not complete successfully
#
#   它不会说是密钥不对、shortId 不对、serverName 不对，还是客户端版本太老。
#   于是排查很容易变成在手机客户端上盲改参数——而每改一次都要跨设备操作，
#   一轮好几分钟。
#
#   这个脚本把变量砍到只剩服务端：客户端参数直接从服务端配置里读出来，
#   Xray 版本和服务端完全一致，网络路径是本机回环。这样一来：
#
#     通  → 服务端配置是对的，问题在客户端（版本 / 字段 / 抄错）
#     不通 → 服务端配置本身有问题，而且这次能拿到客户端侧的报错
#
# 用法（在 VPS 上以 root 执行）：
#
#   bash test-reality.sh
#
# 只读 + 临时文件，不改动任何现有配置和服务。
#
set -euo pipefail

SERVER_CONFIG="/usr/local/etc/xray/config.json"
CLIENT_CONFIG="/tmp/reality-selftest.json"
CLIENT_LOG="/tmp/reality-selftest.log"
SOCKS_PORT=10808

log()  { printf '\033[32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash $0"
command -v xray >/dev/null 2>&1 || die "没找到 xray"
[ -f "$SERVER_CONFIG" ] || die "没找到服务端配置：$SERVER_CONFIG"

# ---------------------------------------------------------------- 1. 从服务端配置里读参数
#
# 手抄参数正是要排除的错误来源之一，所以一个字都不让人填。

jget() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" "$SERVER_CONFIG" | head -1; }

PORT="$(sed -n 's/.*"port": *\([0-9]\{1,5\}\).*/\1/p' "$SERVER_CONFIG" | head -1)"
UUID="$(jget id)"
SNI="$(sed -n 's/.*"serverNames": *\[ *"\([^"]*\)".*/\1/p' "$SERVER_CONFIG" | head -1)"
[ -n "$SNI" ] || SNI="$(grep -A2 '"serverNames"' "$SERVER_CONFIG" | grep -oE '"[a-z0-9.-]+\.[a-z]{2,}"' | head -1 | tr -d '"')"
SHORT_ID="$(sed -n 's/.*"shortIds": *\[ *"\([^"]*\)".*/\1/p' "$SERVER_CONFIG" | head -1)"
[ -n "$SHORT_ID" ] || SHORT_ID="$(grep -A2 '"shortIds"' "$SERVER_CONFIG" | grep -oE '"[0-9a-f]{2,16}"' | head -1 | tr -d '"')"
PRIVATE_KEY="$(jget privateKey)"
FLOW="$(jget flow)"

[ -n "$PORT" ] && [ -n "$UUID" ] && [ -n "$SNI" ] && [ -n "$PRIVATE_KEY" ] \
  || die "从 $SERVER_CONFIG 解析参数失败（port/id/serverNames/privateKey）"

PUBLIC_KEY="$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null \
  | grep -iE '^[[:space:]]*(public[ _]?key|password)' | head -1 | sed 's/.*:[[:space:]]*//' | tr -d '[:space:]')"
[ -n "$PUBLIC_KEY" ] || die "从私钥推导公钥失败"

log "从服务端配置读到的参数："
printf '    端口       %s\n' "$PORT"
printf '    UUID       %s\n' "$UUID"
printf '    serverName %s\n' "$SNI"
printf '    shortId    %s\n' "${SHORT_ID:-（空）}"
printf '    flow       %s\n' "${FLOW:-（无）}"
printf '    公钥       %s\n' "$PUBLIC_KEY"
echo

# ---------------------------------------------------------------- 2. 生成本地客户端配置

log "生成本地测试客户端"
cat > "$CLIENT_CONFIG" <<EOF
{
  "log": { "loglevel": "debug", "error": "${CLIENT_LOG}" },
  "inbounds": [
    {
      "tag": "socks-test",
      "listen": "127.0.0.1",
      "port": ${SOCKS_PORT},
      "protocol": "socks",
      "settings": { "udp": false }
    }
  ],
  "outbounds": [
    {
      "tag": "reality-test",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "127.0.0.1",
            "port": ${PORT},
            "users": [
              { "id": "${UUID}", "encryption": "none", "flow": "${FLOW}" }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "chrome",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF

# ---------------------------------------------------------------- 3. 跑起来测一次

: > "$CLIENT_LOG"
xray run -c "$CLIENT_CONFIG" >/dev/null 2>&1 &
CLIENT_PID=$!
cleanup() { kill "$CLIENT_PID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 2

kill -0 "$CLIENT_PID" 2>/dev/null || {
  xray run -test -c "$CLIENT_CONFIG" 2>&1 | tail -20 >&2
  die "本地测试客户端起不来（上面是配置校验输出）"
}

log "通过 REALITY 请求一次出口 IP……"
RESULT="$(curl -fsS --max-time 15 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/tmp/reality-curl.err || true)"

echo
echo "=========================================================="
if [ -n "$RESULT" ]; then
  echo "  结果：✅ 通了，出口 IP = ${RESULT}"
  echo
  echo "  → 服务端 REALITY 配置是对的。"
  echo "    手机上连不上就是客户端那边的问题：版本太老、字段抄错、"
  echo "    或者客户端不支持这套握手。对照上面的参数逐项核对。"
else
  echo "  结果：❌ 不通"
  echo
  echo "  → 服务端自己都连不上自己，问题在服务端配置。"
  echo
  echo "  curl 报错："
  sed 's/^/    /' /tmp/reality-curl.err 2>/dev/null | head -5
  echo
  echo "  客户端侧日志（这次能看到握手失败的具体原因）："
  grep -iE 'reality|tls|handshake|failed' "$CLIENT_LOG" 2>/dev/null | tail -10 | sed 's/^/    /'
  echo
  echo "  服务端侧日志："
  grep -i reality /var/log/xray/error.log 2>/dev/null | tail -3 | sed 's/^/    /'
fi
echo "=========================================================="
echo
echo "临时文件（排查完可以删）："
echo "  $CLIENT_CONFIG"
echo "  $CLIENT_LOG"
