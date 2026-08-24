# WARP 作为独立出口

这篇不是教你把整台 VPS 默认路由全部塞进 WARP。

本项目推荐的是：

```text
Linux 默认路由
    ↓
VPS 原生网络

只有 Xray 选中的流量
    ↓
127.0.0.1:40000
    ↓
warp-svc Local Proxy
    ↓
Cloudflare WARP
```

这样入口协议、SSH、系统更新、普通下载和 WARP 出口互不绑死。

---

## 1. 为什么这样用 WARP

部分 AI / SaaS 服务会结合：

- 服务可用地区；
- 数据中心 IP 信誉；
- 出口变化；
- 账号安全风控；

来决定访问体验。

WARP 的作用是给指定流量提供一个**独立 Cloudflare 出口**，而不是把它宣传成“住宅 IP”。

它的优点主要是：

1. 与 VPS 原生出口隔离；
2. 可以按域名选择；
3. 不需要修改系统默认路由；
4. 重连 / 故障恢复相对独立；
5. Xray 只需要把它当本地 SOCKS5 outbound 使用。

> WARP 不是住宅 IP，也不能保证某个目标服务一定接受它。请确认目标服务在你的所在地区可用，并遵守服务条款。

---

## 2. 当前生产结构

现机只读审计确认：

```text
Xray
  ↓ SOCKS5
127.0.0.1:40000
  ↓
warp-svc
  ↓ MASQUE
Cloudflare WARP
```

同时：

```text
ip route
```

仍然保持 VPS 原生默认网关，没有 WARP 接管全局路由。

这是本教程推荐的关键点。

---

## 3. 安装官方 Cloudflare WARP Linux Client

优先参考 Cloudflare 当前官方文档：

- Linux 安装：<https://developers.cloudflare.com/warp-client/get-started/linux/>
- WARP modes：<https://developers.cloudflare.com/warp-client/warp-modes/>

安装好 `cloudflare-warp` 后，应有：

```text
warp-svc
warp-cli
warp-diag
```

首次注册 / 连接的官方基础流程：

```bash
sudo warp-cli registration new
sudo warp-cli connect
```

Cloudflare 当前 Linux Client 默认支持 MASQUE，也可以查看：

```bash
warp-cli tunnel protocol --help
warp-cli mode --help
warp-cli settings
```

---

## 4. 切到 Local Proxy / WarpProxy 模式

生产机使用的是本地代理端口：

```text
127.0.0.1:40000
```

Cloudflare 当前文档把这种模式称为 **Local proxy**，`warp-cli settings` 中可看到类似：

```text
Mode: WarpProxy on port 40000
```

较新的 WARP Proxy mode 使用 MASQUE。

不同版本的 `warp-cli` 子命令曾发生过变化，因此先运行：

```bash
warp-cli mode --help
warp-cli proxy --help
```

当前生产环境对应的 CLI 形式为：

```bash
sudo warp-cli tunnel protocol set MASQUE
sudo warp-cli mode proxy
sudo warp-cli proxy port 40000
sudo warp-cli connect
```

如果你的版本不接受其中某条命令，以当前安装版本的 `--help` 和 Cloudflare 官方文档为准，不要盲目复制旧博客命令。

确认：

```bash
warp-cli settings
warp-cli status
ss -lntp | grep 40000
```

---

## 5. 验证 WARP Local Proxy

先不要接 Xray，直接验证本地代理：

```bash
curl --proxy socks5h://127.0.0.1:40000 \
  https://www.cloudflare.com/cdn-cgi/trace
```

检查返回中：

```text
warp=on
```

再查出口：

```bash
curl --proxy socks5h://127.0.0.1:40000 \
  https://api.ipify.org
```

注意：

```text
curl 直连出口
```

和：

```text
curl --proxy socks5h://127.0.0.1:40000
```

应该是两条独立路径。

---

## 6. 接入 Xray outbound

```json
{
  "tag": "warp-official",
  "protocol": "socks",
  "settings": {
    "servers": [
      {
        "address": "127.0.0.1",
        "port": 40000
      }
    ]
  }
}
```

然后只给指定规则使用它。

例如：

```json
{
  "type": "field",
  "domain": [
    "domain:openai.com",
    "domain:chatgpt.com",
    "domain:oaistatic.com",
    "domain:oaiusercontent.com",
    "domain:gemini.google.com",
    "domain:aistudio.google.com",
    "domain:generativelanguage.googleapis.com"
  ],
  "network": "tcp",
  "outboundTag": "warp-official"
}
```

域名列表不是永久完整清单。实际部署时按你使用的服务、日志和官方域名变化维护。

---

## 7. 为什么不建议 WARP 全局接管 VPS

如果把整台机器默认路由改到 WARP：

```text
SSH
系统更新
Xray 的上游 SOCKS5
普通下载
所有未知进程
```

都会一起改变路径。

结果是：

- 路由问题更难定位；
- 固定 SOCKS5 分支可能被再次套进 WARP；
- 原生 VPS 网络基线消失；
- WARP 故障会扩大成整机网络故障。

Local Proxy 模式把故障域缩小到：

```text
只有被 route 到 warp-official 的流量
```

更符合本项目“入口 / 出口分层”的设计。

---

## 8. WARP 假活 / 僵尸检测

生产环境遇到过一种情况：

```text
warp-svc 进程在
端口也在
但经本地 SOCKS5 已经无法正常请求外网
```

所以只检查：

```bash
systemctl is-active warp-svc
```

是不够的。

真正有价值的是**出口实测**：

```bash
curl --proxy socks5h://127.0.0.1:40000 \
  --silent --fail --max-time 8 \
  https://api4.ipify.org >/dev/null
```

一个简单 watchdog：

```bash
#!/usr/bin/env bash
set -u

TEST_URL="https://api4.ipify.org"
MAX_TIME=8

if ! curl --proxy socks5h://127.0.0.1:40000 \
  --silent --fail --max-time "$MAX_TIME" \
  "$TEST_URL" >/dev/null 2>&1; then

  logger -t warp-watchdog "WARP proxy check failed; reconnecting"

  warp-cli disconnect >/dev/null 2>&1 || true
  sleep 2
  warp-cli connect >/dev/null 2>&1 || true
  sleep 3

  if curl --proxy socks5h://127.0.0.1:40000 \
    --silent --fail --max-time "$MAX_TIME" \
    "$TEST_URL" >/dev/null 2>&1; then
    logger -t warp-watchdog "WARP recovered"
  else
    logger -t warp-watchdog "WARP recovery FAILED"
  fi
fi
```

保存为例如：

```text
/usr/local/sbin/warp-watchdog.sh
```

然后：

```bash
chmod 700 /usr/local/sbin/warp-watchdog.sh
```

生产机当前使用 cron 定期检查。新部署也可以改成 systemd timer，核心原则不变：

> **检查真实出口，而不是只检查 daemon 是否活着。**

---

## 9. 排错顺序

WARP 分支出问题时不要先改 Xray。

按顺序：

```text
1. warp-cli status
2. warp-cli settings
3. ss -lntp | grep 40000
4. curl 经 127.0.0.1:40000
5. 确认 warp=on
6. 再检查 Xray outbound
7. 最后检查 routing rule
```

这样能快速判断问题是在：

```text
Cloudflare WARP
还是 Xray
还是域名规则
```

---

## 10. 版本提醒

Cloudflare 的 Linux WARP Client 和 CLI 会变化。

尤其 Proxy mode 在近年有过实现和命令调整；较新的版本中 MASQUE 是 Proxy mode 的要求 / 默认方向。

因此公开教程不要把某一版 CLI 当成永远不变的 API：

```bash
warp-cli --help
warp-cli mode --help
warp-cli proxy --help
```

应当始终优先于旧博客截图。
