# personal-edge-proxy

> 一套我自己实际在用、并经过现机审计的个人代理架构：**Hysteria2 作为日常主入口；AI 流量优先使用独立 WARP 出口；如果需要更稳定的 Claude / Anthropic 出口，再单独接固定 SOCKS5。REALITY 和 Cloudflare Tunnel 主要用于入口冗余。**

[给 AI / Agent 的维护与部署说明 → `AGENTS.md`](./AGENTS.md)

> **只有手机、想尽快换掉不稳定的机场？**
> 直接看 [`docs/mobile-quickstart.md`](./docs/mobile-quickstart.md)：
> 全程手机操作，一条命令部署 HY2，含选购验 IP、平滑迁移和排错。
> 那份文档只做下面的 A 档，够用就停。

## 先说结论：我自己怎么选

如果只是想“能用”，一条 HY2 就够。

如果主要用途是 ChatGPT、Codex、Gemini、Claude 这类 AI 服务，我更推荐：

```text
Client
  ↓
Hysteria2
  ↓
VPS / Xray
  ├─ 普通流量 --------------------> VPS Direct
  ├─ OpenAI / ChatGPT / Codex ----> Cloudflare WARP
  ├─ Gemini / Google AI ----------> Cloudflare WARP
  └─ Claude / Anthropic ----------> 可选固定 SOCKS5
```

原因不是“某家一定会封号”或者“某家一定要求住宅 IP”，而是实际使用时一些 AI / SaaS 服务会受到**地区可用性、数据中心 IP 信誉、出口变化、风控挑战**等因素影响。把 AI 出口和廉价 VPS 的原生机房 IP 解耦，通常更容易维护，也更容易排错。

**这不是规避服务条款的保证方案，也不能保证任何账号不会触发风控。** 使用前仍应确认目标服务支持所在地区，并遵守对应服务条款。

---

## 推荐档位：A → E 怎么理解

这些档位不是强制逐级安装，而是帮助你判断“这一层到底解决什么问题”。

| 档位 | 结构 | 解决的问题 | 我的评价 |
|---|---|---|---|
| A | HY2 → VPS Direct | 最小可用 | 最简单，但 AI 直接看到 VPS 机房出口；如果 IP 段信誉一般，可能更容易遇到可用性/挑战问题 |
| B | A + REALITY 备用入口 | 降低入口单协议故障 | 出口仍是 VPS Direct，所以**出口侧问题与 A 基本相同**；它主要降低 UDP 不可用时的连接风险 |
| C | HY2 → VPS，指定 AI → WARP | 把 AI 与原生机房出口解耦 | 很实用；通常比 A/B 更适合 AI 场景，且 WARP 不需要接管整台 VPS |
| D | C + Claude / Anthropic → 固定 SOCKS5 | 给指定服务保持稳定最终出口 | **我最推荐的实用档**；OpenAI/Gemini 等走 WARP，Claude/Anthropic 需要时单独走固定出口 |
| E | D + REALITY / Cloudflare Tunnel 等备用入口 | 再增加入口冗余 | 锦上添花；网络环境复杂、经常换 Wi-Fi/校园网/公司网时再加 |

最重要的区分：

> **REALITY / Tunnel 解决“怎么进入 VPS”；WARP / SOCKS5 解决“VPS 从哪里出去”。**

不要因为加了 REALITY 就误以为 AI 看到的出口 IP 变干净了——如果最终还是 `VPS Direct`，出口身份并没有变化。

### 如果你懒：只部署 HY2 仍然完全可以

最小形态：

```text
Client
  ↓ Hysteria2
VPS
  ↓ Direct
Internet
```

如果 HY2 在你的网络里稳定，而且你不在意 AI 服务使用 VPS 原生出口，那么做到这里就可以停。

---

## 如果准备把部署交给 AI：先由人完成一次 SSH 引导

AI 可以继续完成服务器施工，但第一步最好由人把 SSH 公钥登录准备好。

推荐流程：

```text
人类第一次用 VPS 初始密码 / 厂商控制台登录
        ↓
本地生成 SSH 密钥对
        ↓
只把公钥放入服务器 authorized_keys
        ↓
人类确认密钥登录成功
        ↓
Claude Code / Codex / Agent 使用本机现成 ssh 继续操作
```

生成密钥：

```bash
ssh-keygen -t ed25519
```

默认：

```text
~/.ssh/id_ed25519       私钥，只留本机
~/.ssh/id_ed25519.pub   公钥，可以上传服务器
```

Linux / macOS：

```bash
ssh-copy-id root@YOUR_SERVER_IP
```

Windows PowerShell：

```powershell
Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub | ssh root@YOUR_SERVER_IP "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
```

最后先由人验证：

```bash
ssh root@YOUR_SERVER_IP
```

**不要把 SSH 私钥、VPS root 密码复制到聊天、Issue 或公开仓库。** 本地 Agent 如果能直接调用你已经可用的 `ssh` / SSH Agent / `~/.ssh/config`，就不需要知道私钥内容。

> 在密钥登录验证成功之前，不要关闭 SSH 密码登录，避免把自己锁在服务器外。

---

## 为什么 WARP 是推荐的 AI 出口层

推荐结构：

```text
Linux 默认路由 → VPS 原生网络

只有 Xray 选中的流量
        ↓
warp-official outbound
        ↓ SOCKS5
127.0.0.1:40000
        ↓
warp-svc / MASQUE
        ↓
Cloudflare WARP
```

这样做的价值：

1. AI 流量不必直接使用 VPS 原生机房出口；
2. WARP 故障不会把 SSH、系统更新、上游 SOCKS5 一起拖死；
3. 可以按域名精确分流；
4. 重连 WARP 不需要重做客户端节点；
5. Direct / WARP / Fixed SOCKS5 三条出口可以独立测试。

**WARP 不是住宅 IP，也不能保证某个服务一定接受它。** 它只是一个独立、方便维护的 Cloudflare 出口。

详见：[`docs/warp-outbound.md`](./docs/warp-outbound.md)

---

## 为什么 Claude / Anthropic 可以单独补固定出口

如果你希望 Claude / Anthropic 长期保持同一个最终出口：

```text
Claude / Anthropic
        ↓
   Xray routing
        ↓
   static-socks
        ↓
   固定公网出口
```

这样 HY2/REALITY 怎么切、VPS 是否迁移、WARP 是否重连，都可以与这条固定出口策略分开管理。

但要强调：

- Claude 并不是协议层面“必须住宅 IP”；
- 固定 SOCKS5 是可选策略；
- SOCKS5 本身不等于加密隧道；
- 如果 VPS/WARP 出口本身满足你的需求，就可以不加这一层。

详见：[`docs/static-socks.md`](./docs/static-socks.md)

---

## REALITY / Cloudflare Tunnel 放在哪一层

我把它们视为**入口冗余**：

```text
Client
  ├─ HY2 / UDP ---------------- 日常主用
  ├─ VLESS + REALITY / TCP ---- UDP 不友好时备用
  └─ VLESS + WS + CF Tunnel --- 可选应急入口
                ↓
              VPS
```

它们不会自动改善 VPS 的最终出口 IP。想改善出口，需要 WARP / Fixed SOCKS5 等 outbound 策略。

---

# 1. 我实际审过的环境

### 服务端

- Ubuntu 24.04 LTS
- Xray 26.3.27
- VLESS + REALITY + Vision：TCP 443
- Hysteria2：UDP 24443
- WARP：`warp-svc` Local Proxy / SOCKS5 `127.0.0.1:40000`
- 可选固定上游 SOCKS5

### Windows 客户端

- v2rayN 7.24.2
- HY2 激活时：sing-box 1.13.14
- REALITY 配置：Xray core
- TUN + Rule 模式

生产机经历过多轮实验，所以仓库 example 不是原样复制生产配置，而是：

```text
现网验证
  ↓
只读审计
  ↓
官方文档复核
  ↓
脱敏 + 清理历史残留
  ↓
公开 example
```

官方参考：

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

包含 HY2、REALITY、Direct、WARP、可选 Fixed SOCKS5 和示例 routing。

## v2rayN：Hysteria2

[`examples/v2rayn-hysteria2.example.md`](./examples/v2rayn-hysteria2.example.md)

来自当前 v2rayN 激活节点的实际 sing-box 运行时结构。

## v2rayN：REALITY + Vision

[`examples/v2rayn-reality-vision.example.md`](./examples/v2rayn-reality-vision.example.md)

根据 v2rayN 节点库、导入配置和当前 Xray 字段交叉核对整理。

---

# 3. VPS 条件

基础要求并不高：

```text
1 vCPU
1 GB RAM
Ubuntu 24.04 LTS / Debian 12+
公网 IPv4
TCP + UDP
```

真正重要的是线路、丢包、晚高峰、UDP 可用性和厂商是否允许个人代理/VPN用途。

购买前最好用测试 IP / Looking Glass，从自己的网络测试：

```powershell
ping TEST_IP -n 50
tracert -d TEST_IP
```

稳定的 200 Mbps 往往比晚高峰严重丢包的“共享 1 Gbps”更实用。

---

# 4. 端口布局

完整示例：

```text
TCP 22      SSH
TCP 443     REALITY
UDP 24443   HY2
```

只部署 HY2 时，不需要因为仓库里有 REALITY 示例就额外开放 TCP 443。

---

# 5. 客户端和服务端职责

客户端主要负责：

```text
中国大陆 / 私网 → DIRECT
需要代理的流量 → VPS
```

服务端高级 routing 再负责：

```text
普通流量 → VPS Direct
OpenAI/Gemini 等指定 AI → WARP
Claude/Anthropic → 可选 Fixed SOCKS5
```

这样每台客户端都不用保存 WARP 或上游 SOCKS5 凭据。

---

# 6. Fail Closed

对于刻意绑定固定出口的目标，我更喜欢：

```text
固定上游不可用
      ↓
请求失败
```

而不是自动回落到 VPS Direct。后者可能在用户没有察觉时改变最终出口。

---

# 7. 安全注意事项

公开仓库不要提交：

```text
真实 SSH 私钥 / root 密码
VLESS UUID
Reality Private Key
Reality shortId
HY2 Password
TLS Private Key
Cloudflare Token
上游 SOCKS5 凭据
订阅 URL
生产配置
```

仓库统一使用占位符：

```text
YOUR_SERVER_IP
YOUR_UUID
YOUR_REALITY_PRIVATE_KEY
YOUR_REALITY_PUBLIC_KEY
YOUR_SHORT_ID
YOUR_HY2_PASSWORD
YOUR_DOMAIN
YOUR_SERVER_NAME
YOUR_SOCKS_HOST
YOUR_SOCKS_USERNAME
YOUR_SOCKS_PASSWORD
```

---

# 8. 推荐部署顺序

如果主要目的是稳定使用 AI，我建议：

```text
1. 测 VPS 线路
2. 人类首次 SSH 登录，配置并验证 SSH 公钥
3. AI / Agent 接手后续 SSH 施工
4. 部署 HY2 并完成客户端验证
5. 配 WARP Local Proxy，把指定 AI 流量切到 WARP
6. 如果 Claude / Anthropic 需要稳定固定出口，再补 Fixed SOCKS5
7. 如果确实遇到 UDP 不稳定，再补 REALITY
8. 需要更多入口冗余时再考虑 Cloudflare Tunnel
```

这和“先装全家桶”不同：**优先把对日常体验最有价值的出口层做对，再按真实网络问题增加备用入口。**

---

# 9. 项目结构

```text
personal-edge-proxy/
├── README.md
├── AGENTS.md
├── LICENSE
├── .gitignore
├── scripts/
│   ├── install-hy2-official.sh     一条命令部署 Profile A（官方 HY2 → Direct）
│   ├── install-hy2.sh              同上的 Xray 版（见脚本内说明，不推荐）
│   ├── diagnose-hy2.sh             节点老是断时先跑这个（只读，不改任何东西）
│   ├── tune-hy2.sh                 修掉三个造成断线的服务端默认值（可回滚）
│   ├── add-tcp-entry.sh            加一条 TCP 备用入口（sing-box，已实机验证）
│   ├── add-reality.sh              同上的 REALITY 版（实机没跑通，见脚本头部）
│   ├── test-reality.sh             REALITY 握手失败时的服务端自测
│   └── harden-server.sh            服务器基础加固（fail2ban / 自动补丁 / BBR）
├── examples/
│   ├── xray-server.example.jsonc
│   ├── v2rayn-hysteria2.example.md
│   └── v2rayn-reality-vision.example.md
└── docs/
    ├── mobile-quickstart.md        手机版最短路径（新手从这里开始）
    ├── stability-and-security.md   断线成因分析 + 安全审查（老是断先看这份）
    ├── handover-template.md        交接手册模板（搭好之后填一份自己存）
    ├── warp-outbound.md
    └── static-socks.md
```

---

## Disclaimer

本项目用于个人远程访问、网络工程学习和开发测试。

请遵守所在地区法律法规、VPS 服务商的 Acceptable Use Policy，以及目标网站 / 服务的使用条款。不要把节点部署成无认证的公共代理。
