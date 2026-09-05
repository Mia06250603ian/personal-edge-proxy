# 手机版最短路径：只用手机搭一个独享 IP 的节点

这份文档面向的情况很具体：

- 你**没有电脑**，只有手机；
- 你现在用的是机场 / 商业 VPN，出现了**频繁人机验证**或**突然断线**；
- 你的主要用途是访问某个特定服务（比如 AI 服务），希望出口 IP **稳定且独享**。

如果你符合以上情况，这份文档就是为你写的。全程不需要电脑。

对应 README 里的 **Profile A**：

```text
手机
 ↓ Hysteria2
你自己的 VPS（独享 IP，长期不变）
 ↓ Direct
目标服务
```

**这份文档故意不装 WARP，也不装 REALITY、固定 SOCKS5。** 原因见第 7 节。

---

## 0. 先搞清楚：你到底在解决什么问题

很多人以为"IP 干净度"是唯一指标。实际上对**账号稳定性**来说，有两个不同的因素：

| 因素 | 含义 | 谁更重要 |
|---|---|---|
| **独享性** | 这个 IP 后面有多少人 | ⭐⭐⭐ 最重要 |
| **稳定性** | 这个 IP 会不会一直变 | ⭐⭐⭐ 最重要 |
| **纯净度评分** | 这个 IP 段历史上有多少滥用 | ⭐⭐ 次要 |
| **是否住宅 IP** | 机房 IP 还是家庭宽带 IP | ⭐ 大多数人用不上 |

**"频繁弹人机验证"几乎总是独享性问题**：同一个 IP 后面几十上百人同时在发请求，风控看到的是异常高的请求频率，于是对所有人弹验证码。你只是替别人挨的打。

自建 VPS 直接根治这一条——**整台机器只有你一个人在用**。

> 反过来说：如果你换到自建 VPS 之后**仍然**频繁弹验证，那问题就不在 IP 上了，
> 需要另外排查（账号本身、浏览器指纹、使用模式）。别继续在 IP 上砸钱。

---

## 1. 买 VPS：这一步决定成败

### 1.1 选地区

**规则只有一条：选你现在正在用的那个地区。**

如果你一直用新加坡，就继续买新加坡。如果一直用日本，就买日本。

原因见第 5 节——**跨国跳变是风控最敏感的信号之一**。换机房不敏感，换国家敏感。

延迟参考（从中国大陆）：

```text
香港 / 日本 / 韩国      30–80 ms    最快
新加坡                  60–120 ms   较快
美国西岸                150–250 ms  可接受
美国东岸 / 欧洲         250 ms+     偏慢
```

### 1.2 配置要求（很低）

```text
1 vCPU
512 MB – 1 GB RAM
10 GB 硬盘
公网 IPv4
必须支持 UDP        ← 重要，HY2 走 UDP
Ubuntu 22.04 / 24.04 或 Debian 12
```

预算 **$3–6 / 月**足够。别买高配，代理是 IO 密集不是 CPU 密集。

### 1.3 ⚠️ 买之前必须验 IP（最关键的一步）

**不要付完钱才去查 IP。** 正确顺序：

```text
1. 找商家客服，要一个"测试 IP"或"同段示例 IP"
   （正规商家都会给；不给的直接换一家）
        ↓
2. 手机浏览器打开 ippure.com，把这个 IP 粘进去查
        ↓
3. 看这几项 ↓
        ↓
4. 合格才付钱
```

**验收标准：**

| 指标 | 合格线 | 说明 |
|---|---|---|
| IPPure 系数 | **< 40%** | 不用追求 15%，那是住宅 IP 的水平，为它多花 3 倍钱不值 |
| IP 属性 | 机房 IP 可接受 | 但如果标着 **"广播 IP"** → ❌ 直接放弃 |
| 人机流量比 | bot **< 50%** | bot 占比高说明这个段在被大量程序化使用 |
| ASN | 见下面黑名单 | |

**ASN 黑名单（这些是批发 VPN 机房，再便宜也别碰）：**

```text
❌ AS60068   Datacamp Limited / cdn77.com
❌ AS9009    M247
❌ AS212238  Datacamp（另一个段）
❌ AS51396   Pfcloud
❌ 任何 whois 里写着 "VPN"、"Proxy" 的
```

**相对稳妥的选择：**

```text
✅ Vultr、DigitalOcean、Linode / Akamai
   —— 大厂，独享 IP，段的信誉一般但不烂，价格 $5–6
✅ 各地区本土中小机房（日本 IIJ / Sakura、韩国 KT 等）
   —— 往往更干净，但需要自己甄别商家
```

**关于"双 ISP 原生住宅 VPS"：** 这类确实更干净，但月费通常 ¥70–200+，且这个市场
超售、跑路、卖二手脏 IP 的不少。**建议先走普通 VPS，真的还有问题再考虑。**
如果要买，同样要求先给 IP 自己验，验完再付款。

### 1.4 买的时候还要确认

- [ ] 商家**允许**个人代理 / VPN 用途（看它的 AUP / TOS，有些明确禁止）
- [ ] **UDP 不被限制**（有些便宜商家封 UDP，HY2 会直接用不了）
- [ ] 能不能**换 IP**、换一次多少钱（万一拿到的 IP 不理想）
- [ ] 有没有**控制台 / VNC**（万一 SSH 锁死了能救回来）

---

## 2. 手机装 SSH 客户端

手机完全可以当终端用。

| 系统 | 推荐 App | 备注 |
|---|---|---|
| Android | **Termius** 或 **JuiceSSH** | 都有免费版，够用 |
| iOS | **Termius** | 免费版够用 |

**连接步骤（Termius 为例）：**

1. 打开 App → `Hosts` → 右下角 `+` → `New Host`
2. 填：
   - `Hostname` = 你的 VPS IP
   - `Username` = `root`
   - `Password` = 商家给你的初始 root 密码
3. 保存 → 点一下就连上了

连上后你会看到类似这样的一行，说明成功了：

```text
root@your-vps:~#
```

> **手机打字建议**：Termius 支持粘贴。本文所有命令都可以复制粘贴，不要手打，
> 手打极容易出错。

### 2.1 （可选但推荐）改用密钥登录

密码登录容易被暴力破解。Termius 可以直接生成密钥：

`Settings` → `Keychain` → `+` → 生成一个 Ed25519 密钥 → 在 Host 设置里绑定它。

绑定后，把公钥传到服务器（在已连上的 SSH 里执行，把 `你的公钥内容` 换成 Termius 里复制出来的公钥）：

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "你的公钥内容" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**先验证密钥能登录成功，再考虑关闭密码登录。** 顺序反了会把自己锁在外面。

---

## 3. 一条命令部署

在已经连上的 SSH 窗口里，粘贴这一行：

```bash
curl -fsSL https://raw.githubusercontent.com/mia06250603ian/personal-edge-proxy/main/scripts/install-hy2-official.sh -o hy2.sh && bash hy2.sh
```

> **为什么用 `install-hy2-official.sh` 而不是 `install-hy2.sh`？**
>
> 仓库里有两个脚本。`install-hy2.sh` 走 Xray 的 hysteria inbound，
> 实机验证下来**不可用**：`xray run -test` 通过、systemd 报告服务
> `active`、日志一个错都不报，但 `ss -ulnp` 显示**根本没有绑定 UDP 端口**
> （Xray 26.3.27 的已知问题，见 XTLS/Xray-core #5921、#5619）。
>
> `install-hy2-official.sh` 装的是 hysteria.network 的**官方服务端**，
> 没有这个问题。两个脚本产出的客户端链接格式完全一样。

> 养成习惯：**先下载再执行**，而不是 `curl ... | bash`。
> 这样你随时可以 `cat install-hy2.sh` 看它到底干了什么。

跑完大概 1–2 分钟，会输出：

```text
================= 部署完成 =================

  服务器      1.2.3.4
  端口        24443  (UDP)
  密码        xxxxxxxxxxxx
  SNI         www.bing.com
  跳过证书验证 必须开启

  分享链接（复制到客户端"从剪贴板导入"）：

hysteria2://xxxxxxxxxxxx@1.2.3.4:24443/?insecure=1&sni=www.bing.com#my-hy2

===========================================
```

**把那条 `hysteria2://` 链接复制下来**，下一步要用。

> ⚠️ 这条链接里包含密码，等同于你节点的钥匙。**不要发到群里、截图发朋友圈、
> 或贴进 Issue。**

### 3.1 关于自签证书

脚本用的是**自签证书**，所以客户端必须开"跳过证书验证 / 允许不安全"。

取舍说明：

- HY2 的身份认证靠**密码**，自签不影响密码安全，也不影响流量加密；
- 代价是客户端无法验证服务端身份，**理论上**存在中间人冒充服务端的风险；
- 对个人自用节点，这个风险通常可以接受。

**如果你有域名**（约 ¥50/年），可以换成真实证书，去掉 `insecure`。
做法见 README 的服务端示例 + 任意 ACME 工具（acme.sh / certbot）。这属于可选升级。

### 3.2 如果商家有"安全组 / 防火墙"面板

脚本会自动配置服务器内部的 ufw，但**很多商家在面板上还有一层防火墙**
（阿里云、腾讯云、AWS、Oracle 都有）。

务必去面板确认放行：

```text
TCP 22       SSH
UDP 24443    HY2      ← 最容易漏掉的就是这条
```

**漏了这条的表现就是：服务器显示运行正常，但客户端就是连不上。**

---

## 4. 手机客户端

### Android

| App | 价格 | 说明 |
|---|---|---|
| **Hiddify** 或 **NekoBox for Android** | 免费 | 推荐 |
| v2rayNG（较新版本支持 HY2） | 免费 | 也可以 |

### iOS

**iOS 上没有官方的 Clash 客户端。** App Store 里那些叫「Clash Plus」「Clash Mi」
之类的应用，多来自机场推广渠道，来源不明。

> ⚠️ **代理 App 能看到你的全部流量。** 不要安装来路不明的套壳应用——
> 那个风险比脏 IP 大得多。

可用的四个：

| App | 价格 | HY2 | 说明 |
|---|---|---|---|
| **Shadowrocket** | 约 $2.99 买断 | ✅ | 最老牌，中文教程最多，排错最容易 |
| **Stash** | 约 $4.99–5.99 买断 | ✅ | iOS 上最成熟的 mihomo（Clash.Meta）前端 |
| **Clash (by Hako)** | **免费** | ✅ | mihomo 内核的新客户端，见下方说明 |
| **sing-box (SFI)** | 免费 | ✅ 原生 | 官方出品，见下方注意事项 |

付费的两个都是一次性买断，非订阅，同一 Apple ID 全设备通用。

**怎么选：**

- 想稳、想少折腾、看重口碑积累 → **Shadowrocket**
- 想要 Clash 规则生态且愿意付费 → **Stash**
- 想零成本先验证节点通不通 → **Clash (by Hako)**

如果你只有一个节点，其实用不到 Clash 的复杂分流能力，Shadowrocket 就够。

**关于 Clash (by Hako)** — 与前面提到的可疑套壳应用不同，这个来源可查：
[App Store](https://apps.apple.com/us/app/clash-rule-based-proxy-utility/id6794257189) ·
[官网 clash.md](https://clash.md/) ·
[GitHub TokenPLS/Hako-Client](https://github.com/TokenPLS/Hako-Client)。
基于 mihomo 内核，原生 SwiftUI，明确支持 Hysteria2 / TUIC / VLESS 等，声明不收集数据。

但要知情：**它很新**——版本 1.0.x，仓库 commit 和 release 都极少，且
**苹果客户端源码尚未公开**（README 说明 Hako 内核已开源，客户端源码待 App Store
审核稳定后再发布）。这不代表有问题，但意味着目前缺少长期使用验证。

**sing-box 注意事项**：官方文档写明他们目前**无法在 App Store 更新**
（审核误判违规），TestFlight 名额仅限赞助者。App Store 上的版本可能偏旧。
上架名称近期有变动（`sing-box-vt` / `sing-box MT`），**认准开发者是 SagerNet**。

> 💡 **选客户端的本质是选择信任对象。**
> 代理客户端能看到你的全部明文流量。免费、新上架的应用不等于不可信，
> 但如果你的目标是长期稳定，多年口碑本身也是一种保障——
> 在客户端上省几十块，通常不是性价比高的地方。
>
> 折中做法：**先用免费客户端验证节点是否正常，确认可用后再决定是否换成付费老牌客户端。**

> 🚧 **iOS 的真正门槛**：以上应用**全部已从中国大陆区 App Store 下架**，
> 需要一个**非中国大陆的 Apple ID**（sing-box 官方也明确要求这一条）。
> 注册外区 Apple ID 免费，但要额外花约 20 分钟。

**导入步骤（各家大同小异）：**

1. 复制第 3 步那条 `hysteria2://` 链接
2. 打开客户端 → 找 `从剪贴板导入` / `Import from clipboard` / 右上角 `+` → `扫码或剪贴板`
3. 节点会自动出现在列表里
4. 点一下连接

**连上后第一件事：** 手机浏览器打开 `ippure.com`，确认 `My IP` 显示的是**你自己 VPS 的 IP**。

如果显示的还是运营商的 IP，说明没走代理，回第 6 节排错。

### 4.0.5 Clash / mihomo 系客户端：参考配置

这类客户端往往**只认订阅或 YAML 配置，不认单条 `hysteria2://` 分享链接**。
遇到「剪贴板里是一条节点分享链接，不是订阅」这种提示，就新建一个空白配置，
在「编辑源码」里贴下面这份（把密码换成你自己的）：

```yaml
mixed-port: 7890
mode: rule
log-level: info
ipv6: false

dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query

proxies:
  - name: my-hy2
    type: hysteria2
    server: YOUR_SERVER_IP
    port: 24443
    password: YOUR_HY2_PASSWORD
    sni: www.bing.com
    skip-cert-verify: true      # 对应链接里的 insecure=1，自签证书必需
    up: "30 Mbps"               # 填接近你真实带宽的值
    down: "150 Mbps"

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - my-hy2                  # 故意不列 DIRECT，见 §4.2

rules:
  - MATCH,PROXY
```

**三个容易翻车的点：**

- **必须先全选清空再粘贴。** 贴到文件末尾会让 `proxies:` 出现两次，
  YAML 不允许重复的顶层键，直接报错。
- **同一组列表的缩进必须一致。** `- https://1.1.1.1/...` 前面 3 个空格、
  下一行 4 个空格，就会报「不是有效的 YAML」。
- **粘贴，别手打。**

**Clash by Hako 的额外前提**：这个客户端启动时会强制检查 GeoIP 数据文件
（`geoip.metadb`），**缺了就拒绝启动，跟你用不用 GEOIP 规则无关**，报错是
`required GeoIP geodata is not pre-staged`。这个文件由 App 按自己的周期
自动下载，而 `NE downloads are disabled` 意味着 **VPN 开着的时候下不了**。
所以：先断开它，用别的网络联网，在「更多 → 客户端设置」确认两个「自动更新」
开关是开的，把 App 放前台等几分钟，再连。

### 4.0.6 sing-box：参考配置

sing-box **也不认 `hysteria2://` 分享链接**，它只吃 JSON 配置。新建一个「本地」
配置，把下面这份贴进去（只改密码）：

```json
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "dns-proxy",
        "server": "1.1.1.1",
        "detour": "proxy"
      }
    ],
    "strategy": "ipv4_only"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "address": ["172.19.0.1/30"],
      "auto_route": true,
      "strict_route": true,
      "stack": "gvisor"
    }
  ],
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "proxy",
      "server": "YOUR_SERVER_IP",
      "server_port": 24443,
      "password": "YOUR_HY2_PASSWORD",
      "up_mbps": 30,
      "down_mbps": 150,
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "insecure": true
      }
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
```

**和 Clash 那份是一一对应的：**

| Clash (YAML) | sing-box (JSON) |
|---|---|
| `skip-cert-verify: true` | `"insecure": true` |
| `sni: www.bing.com` | `"server_name": "www.bing.com"` |
| `up` / `down` | `"up_mbps"` / `"down_mbps"` |
| `ipv6: false` | `"strategy": "ipv4_only"` |
| `rules: - MATCH,PROXY` | `"route": { "final": "proxy" }` |

**⚠️ DNS 格式在 1.12 变过**。报这个错说明你用的是新版：

```text
decode config: dns.servers[0]: legacy DNS server formats are deprecated
in sing-box 1.12.0 and removed in sing-box 1.14.0
```

旧写法是 `"address": "https://1.1.1.1/dns-query"`，新写法拆成
`"type": "https"` + `"server": "1.1.1.1"`。上面这份用的是**新写法**。

> **保存键点了变灰是正常的**——蓝色表示有未保存的改动，灰色表示已保存。
> 不是失败。

### 4.1 分流建议

如果客户端支持规则模式（Hiddify / Shadowrocket 都支持），能用内置规则集就用，
不需要自己写：

```text
中国大陆网站 / 私网地址  →  直连
其他                     →  走节点
```

**先想清楚这个取舍：**

| | 速度 | 泄露风险 |
|---|---|---|
| `MATCH,PROXY` 全走代理 | 国内 App 慢（绕一圈） | 零 |
| 加国内直连规则 | 国内 App 恢复原速 | 重新引入「分流误判」 |

对国内 App 来说这个风险其实无所谓——**淘宝微信本来就知道你在哪**。真正要保护的
目标不在直连名单里，照样走节点。但**全走代理确实是最安全的**，先跑几天看哪些
App 慢得受不了，再按需要加规则，比一上来贴一大串精准。

**另外注意**：开着全局代理时，**银行、支付类 App 可能触发异地风控**，用之前
先断开比较稳妥。视频/音乐类可能因版权显示「地区不可用」。

**没有 GeoIP 数据也能做国内直连**——用域名后缀就行，不依赖任何数据文件：

```yaml
rules:
  - DOMAIN-SUFFIX,cn,DIRECT          # 一条顶几百条
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,tencent.com,DIRECT
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,tmall.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,alicdn.com,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,hdslb.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,126.net,DIRECT
  - DOMAIN-SUFFIX,douyin.com,DIRECT
  - DOMAIN-SUFFIX,bytedance.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,xiaohongshu.com,DIRECT
  - DOMAIN-SUFFIX,meituan.com,DIRECT
  - MATCH,PROXY                       # 兜底必须放最后
```

`DOMAIN-SUFFIX,cn,DIRECT` 覆盖所有 `.cn` 域名，性价比最高。

> `DIRECT` 作为**规则目标**始终可用，和 §4.2 里说的「把 `DIRECT` 从
> proxy-group 里删掉」不冲突——删的是**手动切换**这个后门，规则里的
> 定向直连是你明确指定的行为。

---

## 4.2 🔒 防止真实 IP 泄露（配好客户端就做这一次）

先澄清一个常见误解：

> **泄露发生在客户端，不在服务器。**
> 换成自建节点**不会**新增任何泄露途径——机场和自建面对的是同一批坑。

真正的泄露途径只有四条，逐条处理掉就行。

### 泄露途径一：IPv6 漏流 ⚠️ 最容易中

```text
你的 VPS   只有 IPv4
你的手机   运营商大概率分配了 IPv6
              ↓
      访问支持 IPv6 的网站
              ↓
   客户端没接管 IPv6 → 走手机直连
              ↓
       对方看到你的真实 IPv6 地址
```

IPv6 地址同样能定位到运营商和地区。**这是自建场景最需要注意的一条**，
因为便宜 VPS 常常只给 IPv4。

**处理**：客户端设置里关闭 IPv6，或开启「IPv6 走代理 / IPv6 走 TUN」。
Hiddify、NekoBox、Shadowrocket 都有这个开关。

### 泄露途径二：分流规则误判

这一条**自建确实比机场风险略高**——机场给你的规则是调好的，自建要你自己选。

```text
规则模式下
      ↓
某个域名被规则判成「国内 / 直连」
      ↓
这条流量绕过节点 → 真实 IP 暴露
```

**处理（二选一）：**

- **稳妥**：使用客户端内置的成熟规则集，不要自己手写规则；
- **最稳**：直接用**全局模式**。牺牲一点国内 App 体验，换零分流风险。
  如果你只在意一两个特定服务的稳定性，这个取舍很划算。

### 泄露途径三：断线漏流

```text
节点断开的瞬间
      ↓
系统自动回落到直连
      ↓
你还在刷页面，但已经在用真实 IP
```

**每一次「突然断」都是一个泄露窗口。** 这也是换掉不稳定机场的理由之一——
独享节点断得少，泄露窗口自然少。

**处理**：开启 Kill Switch —— 宁可断网，也不要静默回落到直连。

各客户端里它的名字不一样，很多商业「加速器」App 把它叫做 **「网络锁」**：

| 客户端 | 功能名称 | 位置 |
|---|---|---|
| **Android 系统级**（最可靠） | 「**始终开启 VPN**」+「**阻止没有 VPN 的连接**」 | 系统设置 → 网络 → VPN → 齿轮图标 |
| Hiddify / NekoBox (Android) | 依赖上面的系统级开关 | 同上 |
| Shadowrocket (iOS) | 「**按需连接 / On-Demand**」 | App 设置 |
| 各类商业加速器 | 「网络锁」/「Kill Switch」 | App 设置 |

**优先用 Android 的系统级开关**：它由操作系统强制执行，即使代理 App 崩溃退出，
系统也会继续拦截未走 VPN 的流量。App 自带的开关做不到这一点。

> ⚠️ **别把 Kill Switch 和 IP 信誉搞混。**
> 它防的是「泄露」，防不了「人机验证」——
> 后者是共享 IP 造成的，只能靠换成独享出口解决。
> 网络锁开着 ≠ 你的 IP 问题已经解决。

#### ⚠️ iOS 上多半找不到这个开关，别白翻

**先省掉你几十分钟：iOS 上没有真正的 Kill Switch。**

- 系统级的「始终开启 VPN / 阻止没有 VPN 的连接」是 **Android 独有**，
  iOS 的同类能力只对 MDM 托管设备开放，普通用户拿不到；
- Apple 开发者论坛里长期讨论过这个限制，商业 VPN 在 iOS 上标榜的
  「网络锁」，**多数只是启用了「按需连接」**，不是真的阻断流量；
- 「按需连接」这个开关，只对 IKEv2/IPsec 那类系统 VPN 配置显示。
  NetworkExtension 类客户端（Clash / sing-box / Hako 这些）的配置页里
  只会写「若要配置设置，请使用 XX 应用程序」，**没有这个开关**；
- 而客户端自己有没有实现，要看各家。实测 Clash by Hako 没有。

**所以 iOS 上能做的是另外两件事：**

**① 用配置本身当 Kill Switch**（能控制的部分）

把 `DIRECT` 从 proxy-group 里删掉，只留节点：

```yaml
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - my-hy2        # 不要再列 DIRECT
```

`DIRECT` 一旦在组里，就存在「切过去直连」的可能。删掉之后这个选项不存在，
规则里也只有 `MATCH,PROXY`，就没有任何一条路径能把流量送去直连。

**② 实测一次，别靠猜**（没法控制的部分）

文档、设置页、客服说什么都不算数，制造一次真实断线看结果最快。做法见下方
「断线实测」。

> 实测结论（Clash by Hako + Hysteria2 + iOS）：**节点停掉后网页直接打不开，
> 不会回落直连**。也就是说效果已经是对的，只是没有一个开关告诉你而已。
> 你自己的组合仍然要自己测一遍。

**③ 换个客户端，有的确实提供了这个能力**

上面说的「iOS 没有」指的是**系统级**和**多数客户端**。个别客户端在自己的
隧道实现里做了等效的东西，例如 sing-box 的 TUN 入站：

```json
"strict_route": true
```

严格路由会阻止流量绕过隧道，比「配置里没有 DIRECT」更靠前一层。
Clash by Hako 没有对应选项。**如果你很在意这一项，这是选 sing-box
而不是 Hako 的一个实际理由**（配置见 §4.0.6）。

换完仍然要重跑一次断线实测——**开关写在配置里不等于它生效了。**

### 泄露途径四：WebRTC / DNS

- **WebRTC**：主要影响浏览器，可能暴露本机地址。用 `browserleaks.com/webrtc`
  自查——它会直接给「No Leak」或者列出泄露的地址，比笼统的评分清楚得多。
- **DNS**：暴露的是你用的 DNS 服务器，**不直接暴露你的 IP**，危害低一级。
  用 `browserleaks.com/dns` 看检测到的 DNS 服务器**归属哪家**：
  全是你 VPS 服务商的 → 解析在服务端做的，没漏；
  出现你本地运营商的 → 漏了。

**配置里也别留国内 DNS。** 在 `fake-ip` + 全量代理的组合下它们几乎不会被用到，
但留着就是个隐患——万一某条路径绕过 fake-ip，查询就发给它们了：

```yaml
dns:
  enable: true
  ipv6: false
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://1.1.1.1/dns-query      # 加密 DNS，查询内容中间人也看不到
    - https://8.8.8.8/dns-query
```

### 泄露途径五：UDP 兜底回落

mihomo 系客户端有一个「UDP 兜底」设置，用来处理**出口扛不住 UDP** 时的流量。
它的默认档位可能是「带着你自己的地址经 DIRECT 出门」——**那就是直接泄露**。

选最严格的那一档（通常叫「拒绝全部落到兜底的 UDP」）。

> **用 Hysteria2 / TUIC 的话这一档不会被触发**——这些协议本身就承载 UDP，
> 流量正常命中规则，走不到兜底。所以它对你是零代价的保险：设上没有副作用，
> 万一以后换了不支持 UDP 的线路，自动不泄漏。

### 配好之后自查一遍

用 `browserleaks.com` 和 `ipleak.net` 交叉验证，逐项确认：

- [ ] IP = 你 VPS 的 IP（不是运营商的）
- [ ] WebRTC 明确显示 **No Leak**，Local IP 为空
- [ ] 页面上没有任何 IPv6 地址
- [ ] DNS 检测出的服务器**全部归属你的 VPS 服务商**
- [ ] 客户端「UDP 兜底」已设为最严格档
- [ ] proxy-group 里没有 `DIRECT`

### 🔬 断线实测（唯一能确定 Kill Switch 有没有效的办法）

设置页写什么、客服说什么都不算数。**制造一次真实断线，三分钟出答案。**

**① 在服务器上停掉节点**（SSH 是另一个服务，不受影响）：

```bash
systemctl stop hysteria-server
```

**② 立刻在手机 / 平板上打开任意网页**

**③ 看结果：**

| 现象 | 结论 |
|---|---|
| 打不开 / 一直转圈 | ✅ **不会泄露**。断了就断了，不会回落直连 |
| 正常打开，且显示你的真实 IP | 🔴 **会泄露**。需要换一个实现了按需连接的客户端 |

**④ 恢复：**

```bash
systemctl start hysteria-server
```

> 这个测试比任何设置项都可靠，**换客户端、换配置之后都值得重跑一遍**。

### 漏了一次会不会直接封号？

**通常不会。** 风控看到的是「这个账号偶尔从另一个网络访问」——
现实中用户换 Wi-Fi、开热点、出差，每天发生无数次。

真正麻烦的是**持续性泄露**：分流规则一直判错，导致流量长期一半代理一半直连，
两个地区反复交替出现。那才像异常。

所以目标不是「绝对不能漏一次」，而是**别让它变成常态**。

---

## 5. 🔑 从旧机场平滑迁移（这一步决定你会不会出事）

### 5.0 先回答一个顾虑：换 IP 本身不是更危险吗？

会有人担心「我现在好好的，一换反而出事」。两种风险的性质其实完全不同：

| | 换到自建 | 继续用机场 |
|---|---|---|
| 风险性质 | **一次性**事件 | **持续**累积 |
| 可控性 | 时间、地区、方式都你说了算 | 完全不可控 |
| 风险来源 | 你自己的操作 | 同 IP 上的陌生人 |

还有一条容易被忽略的事实：

> **机场随时可能更换你节点的出口 IP，而且不会通知你。**
> 节点扩容、机器迁移、IP 被封换新的——都会让出口悄悄变掉。
> 「我一直用同一个 IP」往往只是没查过。

所以自建的核心价值不是「IP 更干净」，而是**「IP 由你说了算」**：
换与不换、什么时候换，是你的决定，而不是被动接受。

如果你当前的 IP 已经在弹验证码，那它不是「熟悉的老 IP」，
而是一个**正在恶化且你无权干预**的 IP。

### 5.1 迁移操作

**核心原则：一次只改一个变量。**

风控在意的不是"你换了 IP"，而是"你同时换了 IP + 设备 + 登录状态"。
那三个一起变，长得像账号被盗。

按这个顺序做：

```text
第 1 天
  ├─ 新 VPS 装好，客户端连上
  ├─ 确认 ippure.com 显示的是新 IP、且评分合格
  └─ 用它刷普通网页 / 看视频，但【先不要碰你在意的那个账号】
       ↑ 目的：让这个 IP 先积累正常流量记录

第 2 天
  ├─ 切到新节点
  ├─ ✅ 同一个手机、同一个浏览器 / App
  ├─ ✅ 保持已登录状态，不要退出重登
  ├─ ✅ 不要清 cookie、不要用无痕模式
  ├─ ❌ 不要同一天改密码
  └─ ❌ 不要同一天换设备
       ↑ 这样风控看到的是"同一个会话换了个网络"，这在现实中太常见了

第 3–30 天
  └─ 旧机场先别退订，留着做备份
       万一新 IP 有问题，能立刻切回去
```

**为什么"保持登录态"这么关键？**

带着现有 cookie / token 换网络 = 「用户换了 Wi-Fi」，每天发生几亿次，完全正常。

新 IP + 重新登录 + 新设备 = 「有人在陌生地方用陌生设备登录」，这才触发警报。

**如果不幸真的被要求验证：** 正常完成验证即可，不要反复重试、不要疯狂切换节点。
越切换越可疑。

---

## 6. 排错

### 6.0 ⚠️ 手机上排错之前，先关掉分页器

**这一步不做，你会卡在一个跟故障毫无关系的界面里出不来。**

`systemctl status` 和 `journalctl` 默认把输出喂给 `less` 分页器。在手机上
这东西是纯粹的障碍：屏幕窄、没有 Esc 键、误触 `h` 会进入帮助页，看起来
像是服务器卡死了，其实只是个翻页程序。

**每次 SSH 连上先跑这一条：**

```bash
export SYSTEMD_PAGER=cat
```

本次会话内所有 systemd 命令都不再调 `less`。**已经卡进去了**：按 `q`
（可能要按两次），没反应就直接断开重连，一秒钟的事。

还有一个手机专属技巧——看日志时加 `-o cat`：

```bash
journalctl -u hysteria-server -n 30 --no-pager -o cat
```

默认格式每行前面有 `Sep 05 05:15:50 vultr hysteria[13275]:` 这么一大串，
手机屏幕一行放不下，**真正的报错全被挤到右边看不见**。`-o cat` 只留正文。

本文档后面的命令都按这个写法给。

### 6.1 先分清是哪一层坏了

在 SSH 里跑：

```bash
systemctl status hysteria-server --no-pager
```

- **显示 `active (running)`** → 服务端没问题，问题在网络或客户端，看 6.3
- **显示 `failed`** → 服务端问题，看 6.2

### 6.1.5 ⚠️ 服务 active 不等于端口在监听

这是最容易骗过人的一种故障，实机踩过：

```text
systemctl is-active xray   →  active     ✅ 看起来没问题
journalctl -u xray         →  无任何报错  ✅ 看起来没问题
ss -ulnp | grep 24443      →  空的        ❌ 根本没在监听
```

**服务进程活着，不代表它成功监听了端口。** 遇到"客户端连不上"时，
**第一件事永远是查监听**，而不是去调客户端：

```bash
ss -ulnp | grep 24443
```

- **有输出** → 服务端 OK，往客户端 / 网络方向查（6.3）
- **没输出** → 服务端问题，别再动客户端了

仓库的两个安装脚本现在都会在启动后主动轮询 `ss`，不监听就直接报错退出，
不会再假报成功。

### 6.1.6 Hysteria2 官方服务端起不来：permission denied

```text
FATAL failed to read server config
{"error": "open /etc/hysteria/config.yaml: permission denied"}
```

官方 systemd 单元以非特权的 `hysteria` 用户运行，配置和证书如果是
`root:root 600`，服务读不了自己的配置。**注意它是在 systemd 报告
"Started" 之后才失败的**，所以 `systemctl status` 一闪而过很容易看漏。

修复：

```bash
chown -R hysteria:hysteria /etc/hysteria
systemctl restart hysteria-server
ss -ulnp | grep 24443
```

### 6.2 服务端起不来

```bash
# 看最近 50 行日志，报错通常写得很直白
journalctl -u xray -n 50 --no-pager

# 单独校验配置文件语法
xray run -test -config /usr/local/etc/xray/config.json
```

常见原因：

| 报错关键词 | 原因 | 解决 |
|---|---|---|
| `unknown protocol: hysteria` | Xray 版本太老 | 重装最新版 Xray 后重跑脚本 |
| `address already in use` | 端口被占用 | 换端口：`bash install-hy2.sh --port 28443` |
| `failed to read certificate` | 证书路径 / 权限问题 | 重跑一次脚本 |

### 6.3 服务端正常但连不上（最常见）

**九成是 UDP 端口没放行。** 按这个顺序查：

```bash
# 1. 确认 Xray 真的在监听那个端口
ss -ulnp | grep 24443
#   有输出 = 在监听；没输出 = 服务端问题，回 6.2

# 2. 确认服务器内部防火墙
ufw status
#   应该能看到 24443/udp ALLOW
```

**3. 去商家面板检查安全组** —— 这一步没法在 SSH 里查，必须去网页面板。
**这是最常被漏掉的一步。**

**4. 排除运营商 QoS**：有些移动网络会限制 UDP。测试方法：切到另一个网络
（比如从 5G 切到 Wi-Fi，或反过来）再试。如果换网就好了，说明是运营商的问题——
这种情况才需要考虑加 REALITY（走 TCP 443），见 README。

### 6.3.5 日志里有 `client connected`，但客户端还是没网

这说明**握手成功、密码正确、包能到服务器**——问题不在配置。典型日志长这样：

```text
05:14:43  INFO  client connected     {"addr":"112.36.205.37:20181","id":"user"}
05:15:50  WARN  TCP error            {"error":"readfrom ...: timeout: no recent network activity"}
05:15:50  INFO  client disconnected  {"error":"accepting stream failed: timeout: no recent network activity"}
```

`no recent network activity` 是 **QUIC 的空闲超时**：服务器在等客户端的 UDP
包，等不到，就把这条连接判死了。连上之后一分钟内断，基本都是这个。

先确认服务器这边是好的（三条都应该正常）：

```bash
systemctl is-active hysteria-server                    # active
ss -ulnp | grep 24443                                  # 有输出
curl -4 -m 8 https://api.ipify.org; echo               # 打印出你的 VPS IP
```

> ⚠️ `curl` 成功时输出**不带换行**，紧接着就是下一个提示符，在手机上很像
> "什么都没打印"。所以命令后面一定要跟 `; echo`，否则会把成功误判成失败。

三条都正常 = **服务器健康，是客户端到服务器这段 UDP 路不通或不稳**。常见原因：

| 现象 | 原因 |
|---|---|
| 换个网络就好（5G ↔ Wi-Fi） | 运营商在限制 / QoS UDP |
| 日志里客户端 IP 中途变了 | 移动网络 NAT 映射漂移，QUIC 连接跟着断 |
| 一直连不上，日志里**没有**新的 `client connected` | 包根本没到，端口或协议被封 |

按成本从低到高处理：

1. **换个端口**（`--port 8443` 或 `--port 443`）。有些运营商是按端口段做 QoS 的。
2. **开 Salamander 混淆**。HY2 裸 QUIC 特征明显，混淆后看起来就是普通 UDP 流量。
   服务端 `/etc/hysteria/config.yaml` 加：
   ```yaml
   obfs:
     type: salamander
     password: 你生成的混淆密码
   ```
   **所有客户端都要同步加上同一个密码，否则全部连不上**（sing-box 是
   `"obfs": {"type":"salamander","password":"..."}`，mihomo 是 `obfs:` +
   `obfs-password:`）。改之前先 `cp /etc/hysteria/config.yaml{,.bak}`。
3. **加 TCP 备用入口**（`scripts/add-tcp-entry.sh`，见 §9）。前两条都是"绕"，
   运营商真要掐 UDP 就绕不过去；TCP 443 才是根治。

### 6.4 连上了但网速慢 / 频繁断

```bash
# 看服务器负载
uptime

# 看是不是流量跑超了（多数便宜 VPS 有月流量限额，超了会被限速到几乎不可用）
vnstat -m 2>/dev/null || echo "vnstat 未安装：apt install -y vnstat"
```

如果服务器负载正常、流量没超，那是**线路问题**，跟你的配置无关——
这是 VPS 商家的锅，考虑换商家或换地区。

### 6.4.5 iOS 上的几个坑（实机踩过）

**SSH 连不上，报 `unknown node or service`**

主机名里混进了多余字符。复制 IP 时很容易把行尾的空格或标点一起带进去
（实机遇到过 `"139.180.136.175 #"`）。看报错里引号中间的内容，
**手动重打一遍 IP**，确认前后没有空格。

**SSH 密码怎么输都是 `Authentication failed`**

iOS 键盘会偷偷改写你输入的密码：

| 功能 | 干了什么 |
|---|---|
| 自动大写 | 把首字母改成大写 |
| 智能标点 | 把 `'` `"` `-` 换成外观相似的弯引号 / 长破折号 |
| 自动更正 | 整段替换 |

**关掉它们**：`设置 → 通用 → 键盘` → 关闭「自动大写」「自动更正」「智能标点」。

密码框显示的是圆点，打错了看不见，所以更稳的做法是**先在备忘录里打出来
（可见）核对，再复制粘贴**。跨 App 粘贴时留意 iOS 顶部的
「"XX"想粘贴自"YY"」弹窗——点了「不允许」就会一直粘不进去。

**终端里删不掉打错的命令**

已经回车执行过的行是历史输出，删不掉也不需要删。只有当前输入行才能编辑。

### 6.4.6 Clash / mihomo 客户端的坑

**`The core refused this configuration: required GeoIP geodata is not pre-staged`**

配置里用了 `GEOIP,CN,DIRECT`，但客户端没有 GeoIP 数据库。
先在客户端里找地理数据下载入口；找不到就把这条规则删掉，只留
`- MATCH,PROXY`（相当于全局模式，代价是国内站点也绕一圈）。

**`这不是有效的 YAML`**

多半是把新配置**粘到了文件末尾**，导致 `proxies:` 出现两次。
YAML 不允许重复的顶层键。**同一个键全文件只能有一个**，
修改节点参数要在原来那块里改，不是另起一段。

**速度偏慢**

给 hysteria2 节点显式指定带宽，通常有明显提升：

```yaml
    up: "30 Mbps"
    down: "150 Mbps"
```

填**接近真实带宽**的值：填太高会丢包反而更慢，填太低会卡上限。
先测一次基准（`fast.com`），改完再测一次，**一次只改一处**才知道哪个有效。

### 6.5 换了新 VPS 还是频繁弹验证

**这说明问题不在 IP。** 别再换 IP 了，往这几个方向查：

- 账号本身是不是共享号 / 从他人处购买的
- 是不是在用第三方中转 / 镜像站（你的凭据在别人服务器上，别人的滥用算你头上）
- 浏览器是不是装了大量指纹类插件，或者用了指纹浏览器
- 同一浏览器是不是登了多个同类账号

这些因素**换多少个 IP 都解决不了**。

---

## 7. 为什么这份文档不装 WARP

README 的 Profile C/D 建议把 AI 流量丢给 WARP。那个建议在"想给多种 AI 服务
统一换出口"时是合理的，但**对"我要一个稳定不变的出口"这个目标是反效果的**：

```text
WARP 出口  =  Cloudflare 共享池
           →  IP 会变
           →  很多人共用
           →  正是你想逃离的那两个特征
```

**如果你的目标是"出口越稳越好"，VPS Direct 反而比 WARP 更合适**——
因为它就是一个永不变化的独享 IP。

什么时候才需要往上加东西：

| 症状 | 加什么 |
|---|---|
| UDP 被运营商限制，HY2 时好时坏 | REALITY（TCP 443 备用入口） |
| 某个服务明确不接受你的 VPS 段 | 针对那个服务加固定 SOCKS5（`docs/static-socks.md`） |
| 想给多个 AI 服务统一换出口 | WARP（`docs/warp-outbound.md`） |
| **没有以上症状** | **什么都别加** |

**先跑一个月 Profile A。** 遇到真实问题再对症加层，比一上来装全家桶好排错得多。

---

## 8. 长期运维：真正会坑到你的几件事

搭好只是开始。下面按「实际发生概率」排序，不是按技术难度。

### 🔴 8.1 余额耗尽 —— 最可能真实发生的一件事

```text
余额归零
  ↓
服务商暂停实例 → 一段时间后销毁
  ↓
你辛苦挑出来的那个 IP 被永久回收
  ↓
重新开机、重新验 IP、账号再承受一次 IP 变更
```

**这不是「可能」，是「不管它就一定会发生」。**

**现在就在手机上建一个每月重复的日历提醒：查余额。** 十秒钟的事，
挡掉的是整套推倒重来。有自动充值就更好。

### 🔴 8.2 单点：只有一条入口，一条出口

只部署 HY2 的话，**入口只有 UDP 一条**。任何一条断了就是全断：

| 情况 | 后果 |
|---|---|
| 运营商限速 / 封锁 UDP | 节点时好时坏，或直接不通 |
| 这个 IP 被封 | 完全连不上 |
| 实例故障 | 全断 |

**旧机场没退之前，它就是你的后备。退掉那天起，你就没有安全绳了。**

所以：**在退掉旧线路之前，给同一台服务器加一条 TCP 入口**
（VLESS + REALITY，走 443）。要点：

```text
入口（怎么进服务器）  →  多一条
出口（用什么身份上网）→  完全不变，同一个 IP
```

**加备用入口不会改变出口身份，对账号零影响**——这正是 README 反复强调的
「入口和出口是两回事」。成本也是零：同一台机器，不用加钱。

**一条命令就能加**，见 §9。

### 🟠 8.3 流量配额

便宜套餐通常含 1–2 TB/月（去实例页面确认你的额度）。超了会限速或产生额外费用。
大量看视频的话值得留意。

```bash
vnstat -m 2>/dev/null || apt install -y vnstat
```

### 🟠 8.4 密码轮换

节点密码等于钥匙。**只要它在任何地方出现过——截图、聊天、群里——就该换。**

```bash
# 随机生成并直接应用，不用自己想也不会填错
NEWPASS=$(openssl rand -hex 12) && bash hy2.sh --password "$NEWPASS"
```

换完把输出里的新密码更新到每一个客户端（Clash 的 `password:`、
sing-box 的 `"password"`）。

> 脚本不带 `--password` 重跑时会**沿用现有密码**，所以加固、改端口这类操作
> 不会误伤已配好的客户端。要换密码必须显式传 `--password`。

> ⚠️ 命令里的中文占位符**记得替换**。直接把 `--password '你的新密码'`
> 原样粘进去，脚本会拒绝（中文不在允许字符集里）——这是正常的保护。

### 🟡 8.5 例行检查

```bash
# 系统更新（装了 harden-server.sh 的话安全补丁已自动，这里是全量）
apt update && apt upgrade -y

# 服务状态
systemctl status hysteria-server
ss -ulnp | grep 24443          # 确认端口真的在监听

# 被封禁的爆破 IP
fail2ban-client status sshd
```

每隔一两个月复查一次 IP 信誉（`scamalytics.com/ip/你的IP`）。
**IP 信誉是动态的**，明显变差了就换个 IP，换的时候同样按第 5 节的流程走。

---

## 9. 加一条 TCP 备用入口

**什么时候需要**：你只有 HY2 一条 UDP 入口，而 UDP 是会出问题的——运营商
限速、QoS、某个网络下直接不通。那种时候服务器完全健康，你却进不去（§6.3.5）。

备用入口走 **TCP**，UDP 被限制时它还进得去。

### 先把边界说清楚

```text
入口（怎么进 VPS）    ←  这一步只改这里，从一条变两条
出口（从哪里上网）    ←  完全不变，同一台机器、同一个 IP
```

所以：

- **对任何账号都是零变化**，目标网站看到的出口 IP 一个字节没变；
- **不需要动任何已配好的 HY2 客户端**，HY2 照常工作；
- 不用加钱，不用第二台机器。

它**不会**让你的出口 IP 变干净——想改出口要用 WARP / 固定 SOCKS5，见 README。

### 部署

```bash
curl -fsSLO https://raw.githubusercontent.com/Mia06250603ian/personal-edge-proxy/main/scripts/add-tcp-entry.sh
bash add-tcp-entry.sh
```

装的是 **sing-box 的 VLESS + TLS 入口**，默认端口 8443。脚本会生成 UUID
和自签证书、验证端口在监听、**并且真的通过这条入口发一次请求**，成功了
才报完成。

**几个刻意的设计：**

- **成功的判据是"走通了一次请求"，不是"端口在监听"。** 这条是踩出来的：
  上一版脚本在端口起来之后就宣布部署完成，结果两个客户端配完都连不通，
  白折腾一轮。现在自测不过就自动回滚。
- **不碰 HY2**。装完还会回头确认 `hysteria-server` 仍在运行，掉了就拉起。
- **端口被别人占着就停手**，不硬抢（换端口：`--port 9443`）。
- **默认 8443 而不是 443**。自签证书挂在 443 上是很明显的代理特征，而 443
  是全互联网被扫得最狠的端口。等有了域名和真证书，再用 443 才有意义
  （`--domain example.com`）。

> **为什么不是 REALITY？** REALITY 隐蔽性更好，仓库里也有
> `scripts/add-reality.sh`，但它在实机上（Xray 26.3.27 / 26.7.28）握手一直
> 失败，能排除的都排除了还是不通，而 Xray 唯一的报错是一句不说原因的
> "handshake did not complete successfully"。同样的 VLESS+TLS 入口换成
> sing-box 一次就通。细节见那个脚本的头部注释和 `AGENTS.md` §0.6。

### 装完之后

两条入口并存，客户端里配成两个节点，哪条通用哪条：

```text
UDP 24443   HY2        日常主用，更快
TCP 8443    VLESS+TLS  UDP 抽风时切过去
```

sing-box 里可以加一个 `selector`，把两条都列进去，在 App 界面上点着切，
不用改配置：

```json
{
  "type": "selector",
  "tag": "select",
  "outbounds": ["proxy", "tcp"],
  "default": "proxy"
}
```

然后 `"route": { "final": "select" }`，DNS 的 `detour` 也指向 `select`。

**装完当天就在客户端里把备用入口也配好**，别等到用的时候再配——
真出问题的时候你多半连不上网，也就查不了文档。

### 卸载

```bash
bash add-tcp-entry.sh --uninstall
```

只卸备用入口，HY2 不受影响。

---

## 附：安全提醒

- 节点密码 = 你服务器的钥匙，**不要外传，不要让别人蹭**。
  多一个人用，你就多一份"共享 IP"的风险，等于白搭。
- 不要把节点做成无认证的公共代理。
- 遵守 VPS 商家的 AUP、所在地法律法规，以及目标服务的使用条款。
  目标服务是否在你所在地区提供服务，需要你自己确认。
