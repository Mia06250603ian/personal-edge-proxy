# personal-edge-proxy

> 一套我自己实际在用、并经过现机审计的个人多入口 / 多出口代理架构：**平时主要使用 Hysteria2，VLESS + REALITY + Vision 作为 TCP 备用入口；VPS 端再根据目标选择原生出口、Cloudflare WARP 或可选固定 SOCKS5。**

[给 AI / Agent 的维护说明 → `AGENTS.md`](./AGENTS.md)

## 先说结论：我自己平时怎么用

我一般直接用 **Hysteria2（HY2）**。

原因很简单：在我自己的网络环境里，HY2 的延迟、吞吐和弱网表现都比较好，所以它是日常主入口。

我同时保留一条 **VLESS + REALITY + XTLS Vision**：

- 它不是为了“取代 HY2”；
- 它是一个 TCP 备用入口；
- 当某个 Wi-Fi、校园网、公司网络或运营商对 UDP 不友好时，可以直接切过去；
- 两个入口最后都进入同一台 VPS，由服务端决定真正从哪里出网。

```text
Client
  |
  +-- Hysteria2 / UDP ---------------- 日常主用
  |
  +-- VLESS + REALITY + Vision / TCP -- 备用入口
  |
  `-- VLESS + WS + Cloudflare Tunnel -- 可选应急入口
                    |
                    v
                 Xray-core
                    |
          +---------+----------+----------------+
          |                    |                |
          v                    v                v
      VPS Direct          Cloudflare WARP   Fixed SOCKS5
      普通流量 / 大流量      指定 AI 站点       需要固定出口的服务
```

这套架构最重要的一句话是：

> **入口和出口是两回事。**
>
> - HY2 / REALITY 解决“我怎么稳定地进入 VPS”；
> - Direct / WARP / SOCKS5 解决“VPS 最后以什么出口访问目标服务”。

---

## 为什么我会给 AI 服务单独选出口

部分 AI 服务对 **服务可用地区、数据中心 IP 信誉、出口变化和账号安全风控**比较敏感。

所以我不喜欢把所有流量都简单粗暴地绑死在 VPS 自带公网 IP 上，也不喜欢让 WARP 接管整台 Linux 的默认路由。

我更倾向于：

```text
普通网站 / 下载 / 视频
        ↓
    VPS 原生出口

OpenAI / ChatGPT / Codex
Gemini / Google AI
        ↓
    Cloudflare WARP

Claude / Anthropic
        ↓
可选固定 SOCKS5 出口
```

这只是一个**路由策略示例**，不是说某个服务“必须”这样走。实际使用前请确认目标服务在你的所在地区可用，并遵守对应服务条款。

### 为什么选 WARP

WARP 在这里的价值不是“住宅 IP”，而是：

1. 给指定流量提供一条独立的 Cloudflare 出口；
2. 不需要修改 Linux 默认路由；
3. 可以由 Xray 按域名精确选择；
4. 出问题时容易单独排查、重连或替换；
5. VPS 的 SSH、系统更新、普通下载仍然保持原生线路。

推荐结构：

```text
Xray route
    ↓
warp-official outbound
    ↓ SOCKS5
127.0.0.1:40000
    ↓
warp-svc / MASQUE
    ↓
Cloudflare WARP
```

**WARP 不是住宅 IP，也不能保证某个 AI 服务一定接受这个出口。** 它只是一个非常方便、可隔离的独立网络出口。

详见：[`docs/warp-outbound.md`](./docs/warp-outbound.md)

### Claude / Anthropic 为什么可以单独走固定 SOCKS5

如果你希望某个服务长期保持同一个最终出口，可以再接一个可信的固定 SOCKS5：

```text
Claude / Anthropic
        ↓
   Xray routing
        ↓
   static-socks
        ↓
  固定公网出口
```

这样即使你：

- HY2 和 REALITY 之间切换；
- 更换 VPS；
- 重连 WARP；

目标服务看到的最终出口仍然可以保持不变。

但这也是**可选增强**。HY2、REALITY 本身完全不要求住宅 IP 或固定 SOCKS5。

详见：[`docs/static-socks.md`](./docs/static-socks.md)

---

# 1. 我实际审过的环境

这套文档不是纯理论拼装。当前生产环境经过只读审计，核心结构为：

### 服务端

- Ubuntu 24.04 LTS
- Xray 26.3.27
- VLESS + REALITY + Vision：TCP 443
- Hysteria2：UDP 24443
- WARP：`warp-svc` Local Proxy / SOCKS5 `127.0.0.1:40000`
- 可选上游 SOCKS5：用于固定出口

### Windows 客户端

- v2rayN 7.24.2
- 当前 HY2 激活时使用 sing-box 1.13.14
- REALITY 节点配置为 Xray core
- TUN + Rule 模式

需要特别说明：

> 生产机经历过多轮实验，里面存在一些旧字段、兼容别名和历史残留。本仓库的 example **不是把生产配置原样复制出来**，而是“现网验证 + 官方文档复核 + 脱敏 + 清理历史残留”后的干净版本。

截至 2026-08，Xray 官方已经原生支持 Hysteria2 inbound / outbound / transport；REALITY 当前推荐与 RAW、XHTTP 或 gRPC 搭配。新文档中 REALITY 服务端推荐使用 `target`，旧 `dest` 仍是兼容别名。

官方文档：

- Xray Hysteria inbound: <https://xtls.github.io/config/inbounds/hysteria.html>
- Xray Hysteria transport: <https://xtls.github.io/config/transports/hysteria.html>
- Xray REALITY: <https://xtls.github.io/config/transports/reality.html>
- Xray RAW: <https://xtls.github.io/config/transports/raw.html>
- Cloudflare WARP Linux: <https://developers.cloudflare.com/warp-client/get-started/linux/>
- Cloudflare WARP modes: <https://developers.cloudflare.com/warp-client/warp-modes/>

---

# 2. 仓库里的三个可复制示例

## 服务端

[`examples/xray-server.example.jsonc`](./examples/xray-server.example.jsonc)

包含：

- Hysteria2 inbound；
- VLESS + REALITY + Vision inbound；
- VPS direct；
- WARP Local Proxy outbound；
- 可选固定 SOCKS5 outbound；
- 示例域名分流；
- 私网地址拦截。

## v2rayN：Hysteria2

[`examples/v2rayn-hysteria2.example.md`](./examples/v2rayn-hysteria2.example.md)

这份来自当前 v2rayN 激活节点的实际 sing-box 运行时结构。

## v2rayN：REALITY + Vision

[`examples/v2rayn-reality-vision.example.md`](./examples/v2rayn-reality-vision.example.md)

这份根据 v2rayN 节点库、导入配置和当前 Xray 字段交叉核对整理。

---

# 3. 推荐 VPS 条件

基础代理本身对配置要求并不高：

```text
1 vCPU
1 GB RAM
Ubuntu 24.04 LTS / Debian 12+
1 个公网 IPv4
支持 TCP + UDP
```

真正重要的是线路，而不是纸面 CPU。

购买前最好有测试 IP / Looking Glass，并从你自己的网络实测：

```powershell
ping TEST_IP -n 50
tracert -d TEST_IP
```

重点看：

- 晚高峰丢包；
- 延迟抖动；
- 是否绕路；
- UDP 是否允许；
- 厂商是否允许个人代理 / VPN 用途。

一个稳定的 200 Mbps 节点，往往比一个晚高峰严重丢包的“共享 1 Gbps”更好用。

---

# 4. 推荐端口布局

示例默认：

```text
TCP 22      SSH
TCP 443     VLESS + REALITY + Vision
UDP 24443   Hysteria2
```

也可以让 HY2 使用 UDP 443、REALITY 使用 TCP 443，因为 TCP 和 UDP 可以复用同一个数字端口；本仓库为了方便排错，示例保留独立 UDP 端口。

---

# 5. 为什么 HY2 当主入口

我的实际习惯：

```text
HY2       = Primary
REALITY   = Backup
```

HY2 基于 QUIC / UDP，在合适线路上通常有很好的吞吐和弱网表现。

但它仍然依赖 UDP。因此保留 REALITY 的意义在于：

- 某些网络 UDP 质量很差；
- 某些热点 / 校园网 / 公司网络会限制 UDP；
- 单协议不应该成为唯一故障点。

所以这不是“哪个协议绝对更高级”的问题，而是**给入口做冗余**。

---

# 6. 客户端和服务端分别负责什么

我自己的 Windows 客户端使用 v2rayN TUN + Rule 模式。

客户端主要负责：

```text
中国大陆 / 私网 → DIRECT
需要代理的流量 → VPS
```

服务端再负责：

```text
普通流量 → VPS Direct
指定 AI → WARP
需要固定出口的服务 → SOCKS5
```

这样客户端不用知道 WARP 或固定 SOCKS5 的密码，也不用为每台设备复制复杂的多出口逻辑。

---

# 7. Fail Closed：固定出口挂了就失败，不要偷偷换 IP

对于“必须保持固定出口”的规则，我更喜欢 **Fail Closed**：

```text
Claude
  ↓
static-socks
  ↓
上游不可用
  ↓
请求失败
```

而不是：

```text
上游不可用
  ↓
偷偷回落 VPS Direct
```

后者会在你没有察觉的情况下改变最终出口。

---

# 8. 不要让 WARP 接管整台服务器

不推荐：

```text
Linux default route
       ↓
      WARP
       ↓
所有系统流量
```

推荐：

```text
Linux default route → VPS 原生网络

Xray 指定规则
       ↓
WARP Local Proxy
```

Cloudflare 当前 Local Proxy 模式支持 SOCKS5 / HTTPS proxy；较新的 Proxy mode 使用 MASQUE。生产环境使用本地 `127.0.0.1:40000` 作为 Xray 的独立 WARP outbound。

---

# 9. 安全注意事项

公开 GitHub 仓库里绝对不要放：

```text
真实服务器 IP（如果你不想公开）
VLESS UUID
Reality Private Key
Reality shortId
HY2 Password
TLS Private Key
Cloudflare Token
上游 SOCKS5 用户名 / 密码
订阅 URL
SSH Private Key
```

本仓库统一使用：

```text
YOUR_SERVER_IP
YOUR_UUID
YOUR_REALITY_PRIVATE_KEY
YOUR_REALITY_PUBLIC_KEY
YOUR_SHORT_ID
YOUR_HY2_PASSWORD
YOUR_DOMAIN
YOUR_SOCKS_HOST
YOUR_SOCKS_USERNAME
YOUR_SOCKS_PASSWORD
```

`.gitignore` 已经默认排除常见凭据、证书私钥、生产配置和日志。

---

# 10. 推荐部署顺序

不要第一天把所有功能一起装上去。

推荐：

```text
1. 测 VPS 线路
2. SSH / 防火墙 / 系统基线
3. 先部署 REALITY 或 HY2 其中一个
4. 客户端验证
5. 再加第二个入口
6. 再加 WARP
7. 再加固定 SOCKS5（如果需要）
8. 最后做复杂域名分流和保活
```

每次只增加一个变量，出问题才知道是哪一层。

---

# 11. 项目结构

```text
personal-edge-proxy/
├── README.md
├── AGENTS.md
├── LICENSE
├── .gitignore
│
├── examples/
│   ├── xray-server.example.jsonc
│   ├── v2rayn-hysteria2.example.md
│   └── v2rayn-reality-vision.example.md
│
└── docs/
    ├── warp-outbound.md
    └── static-socks.md
```

后续可以继续补：VPS 选型、ACME、Cloudflare Tunnel、systemd、日志轮转、故障排查和 Mihomo 客户端。

---

## Disclaimer

本项目用于个人远程访问、网络工程学习和开发测试。

请遵守所在地区法律法规、VPS 服务商的 Acceptable Use Policy，以及目标网站 / 服务的使用条款。不要把节点部署成无认证的公共代理。
