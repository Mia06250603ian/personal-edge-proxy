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

# ---------------------------------------------------------------- 2. 逐个组合去试
#
# 握手失败时服务端只说 "invalid connection"，不说是哪个参数不匹配。与其
# 一次改一个参数、每轮跨设备验证几分钟，不如在本机把可疑组合一次跑完。
#
# 试的两个维度：
#
#   uTLS 指纹  现代 Chrome 的 ClientHello 带了后量子密钥交换，某些
#              Xray 版本的 REALITY 对不上，换个老一点的指纹就通了
#   flow       Vision 流控本身也可能是失败点，所以带一次、不带一次

FINGERPRINTS="chrome firefox safari ios edge random"

write_client() {
  # $1 = fingerprint, $2 = flow（空字符串表示不带）
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
              { "id": "${UUID}", "encryption": "none", "flow": "$2" }
            ]
          }
        ]
      },
      "streamSettings": {
        "security": "reality",
        "realitySettings": {
          "serverName": "${SNI}",
          "fingerprint": "$1",
          "publicKey": "${PUBLIC_KEY}",
          "shortId": "${SHORT_ID}",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF
}

CLIENT_PID=""
cleanup() { [ -n "$CLIENT_PID" ] && kill "$CLIENT_PID" 2>/dev/null || true; }
trap cleanup EXIT

# 跑一次某个组合，通了返回 0 并把出口 IP 放进 RESULT
try_combo() {
  local fp="$1" flow="$2"
  write_client "$fp" "$flow"
  : > "$CLIENT_LOG"
  xray run -c "$CLIENT_CONFIG" >/dev/null 2>&1 &
  CLIENT_PID=$!
  sleep 1
  kill -0 "$CLIENT_PID" 2>/dev/null || { CLIENT_PID=""; return 1; }
  RESULT="$(curl -fsS --max-time 8 -x "socks5h://127.0.0.1:${SOCKS_PORT}" https://api.ipify.org 2>/tmp/reality-curl.err || true)"
  kill "$CLIENT_PID" 2>/dev/null || true
  wait "$CLIENT_PID" 2>/dev/null || true
  CLIENT_PID=""
  [ -n "$RESULT" ]
}

RESULT=""
GOOD_FP=""
GOOD_FLOW=""

for flow in "$FLOW" ""; do
  for fp in $FINGERPRINTS; do
    printf '    fingerprint=%-8s flow=%-18s ' "$fp" "${flow:-（不带）}"
    if try_combo "$fp" "$flow"; then
      echo "✅"
      GOOD_FP="$fp"; GOOD_FLOW="$flow"
      break 2
    fi
    echo "✗"
  done
done

# ---------------------------------------------------------------- 3. 结论

echo
echo "=========================================================="
if [ -n "$GOOD_FP" ]; then
  echo "  结果：✅ 通了，出口 IP = ${RESULT}"
  echo
  echo "  能用的组合："
  echo "    fingerprint  ${GOOD_FP}"
  echo "    flow         ${GOOD_FLOW:-（不带）}"
  echo
  echo "  → 服务端没问题。把客户端改成上面这个组合："
  echo "    sing-box  \"utls\": { \"enabled\": true, \"fingerprint\": \"${GOOD_FP}\" }"
  echo "    Clash     client-fingerprint: ${GOOD_FP}"
  if [ -z "$GOOD_FLOW" ]; then
    echo
    echo "    并且【删掉客户端的 flow 那一行】——带 Vision 流控时握手不过去。"
  fi
else
  echo "  结果：❌ 所有组合都不通"
  echo
  echo "  → 不是指纹也不是 flow 的问题，服务端 REALITY 参数本身有问题。"
  echo
  echo "  curl 报错："
  sed 's/^/    /' /tmp/reality-curl.err 2>/dev/null | head -3
  echo
  echo "  客户端侧日志："
  grep -iE 'reality|tls|handshake|failed' "$CLIENT_LOG" 2>/dev/null | tail -6 | sed 's/^/    /'
  echo
  echo "  服务端侧日志："
  grep -i reality /var/log/xray/error.log 2>/dev/null | tail -3 | sed 's/^/    /'
fi
echo "=========================================================="
