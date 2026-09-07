# 客户端基线配置（两台设备用同一份）

这是和 `scripts/restore-baseline.sh` 配套的另一半。服务端还原之后，
**两台客户端都要整段替换成这里的配置**，否则两端对不上，节点直接不通。

> **整段替换，不要逐行改。** 现在手机和 iPad 上的配置是多轮手改的产物，
> 逐行改只会得到又一个"介于两者之间"的形态——那正是要消灭的东西。

> **两台用同一份，不要给单台设备开小灶。** 2026-09-07 那一轮里，手机被按
> Clash 改了很久，实际上跑的是 sing-box；iPad 和手机拿到的字段又不一样。
> 结果是任何一次现象都没法归因到某一端。**动手前先确认每台设备各跑什么客户端。**

> ⚠️ **2026-09-07 追加：下面 VLESS（`my-tcp`）那一段已经不是现网形态了。**
> 服务端的 VLESS 入口已改成 **WebSocket + Cloudflare 源证书**（端口仍是 8443，
> 协议仍是 VLESS，UUID 没换）。**照抄下面的 `my-tcp` 会连不上**——服务端在等
> WS 握手，裸 TCP 客户端过不去。当前该写什么见
> `docs/vless-ws-tls-cloudflare.md` §3。
>
> 这一节**故意不改**：它是和 `scripts/restore-baseline.sh` 配套的**基线**，
> 那个脚本会把服务端打回裸 TCP + 自签证书。改了这里，基线的两半就对不上了。
> HY2 那一段不受影响，仍然是现网形态。

---

## 基线长什么样

| 项 | 值 |
|---|---|
| HY2 | `UDP 24443` |
| 混淆 | **Salamander 保留**，密码沿用现在这个，不用改 |
| `up` / `down` | `10` / `50 Mbps` —— **服务端 Brutal 开着，这两个值是生效的** |
| VLESS | `TCP 8443`（基线是裸 TCP；现网已改 WS，见上面的追加框） |
| 端口跳跃 | **没有**（`ports` / `server_ports` / `hop-interval` 全部不写） |
| 证书 | 自签，CN = `www.bing.com`，客户端跳过校验 |
| 节点组 | 手动 `select`，HY2 在前 |

要删掉的字段只有跳跃那一组：`ports` / `server_ports` / `hop-interval` /
`hop_interval`。**`obfs` 保持现状不要动**——服务端也保留着它，两边一致。

> **混淆是两端字段，只改一边就是"连不上"。** 所以这次不动它：少一次两端
> 同时改的机会，就少一次把"只改了一边"误判成新故障的机会。真要拆的话，
> 服务端跑 `restore-baseline.sh --no-obfs`，同时把下面两份配置里的
> `obfs` / `obfs-password` 一起删掉，**同一次做完**。

---

## 一、mihomo / Clash —— 完整配置（整份替换，不是片段）

`ports` 与 `port` 互斥，这里只用 `port`。

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
  - name: my-hy2-obfs
    type: hysteria2
    server: PASTE_SERVER_IP
    port: 24443
    password: PASTE_HY2_PASSWORD
    obfs: salamander
    obfs-password: PASTE_OBFS_PASSWORD
    sni: www.bing.com
    skip-cert-verify: true
    up: "10 Mbps"
    down: "50 Mbps"

  - name: my-tcp
    type: vless
    server: PASTE_SERVER_IP
    port: 8443
    uuid: PASTE_VLESS_UUID
    network: tcp
    udp: true
    tls: true
    servername: www.bing.com
    skip-cert-verify: true

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - my-hy2-obfs
      - my-tcp
      # 故意不列 DIRECT：iOS 没有系统级 kill switch，
      # 一旦落到 DIRECT 就是明文出网，而且不会有任何提示

rules:
  - MATCH,PROXY
```

**必须先全选清空再粘贴。** 贴到文件末尾会让 `proxies:` 出现两次，
YAML 不允许重复的顶层键，直接报错。

---

## 二、sing-box（iOS / iPad）—— 完整配置（整份替换）

```json
{
  "log": { "level": "info" },
  "dns": {
    "servers": [
      {
        "type": "https",
        "tag": "dns-proxy",
        "server": "1.1.1.1",
        "detour": "PROXY"
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
      "type": "selector",
      "tag": "PROXY",
      "outbounds": ["my-hy2-obfs", "my-tcp"],
      "default": "my-hy2-obfs"
    },
    {
      "type": "hysteria2",
      "tag": "my-hy2-obfs",
      "server": "PASTE_SERVER_IP",
      "server_port": 24443,
      "password": "PASTE_HY2_PASSWORD",
      "up_mbps": 10,
      "down_mbps": 50,
      "obfs": {
        "type": "salamander",
        "password": "PASTE_OBFS_PASSWORD"
      },
      "tls": {
        "enabled": true,
        "server_name": "www.bing.com",
        "insecure": true
      }
    },
    {
      "type": "vless",
      "tag": "my-tcp",
      "server": "PASTE_SERVER_IP",
      "server_port": 8443,
      "uuid": "PASTE_VLESS_UUID",
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
    "final": "PROXY"
  }
}
```

**DNS 的 `detour` 指的是 selector（`PROXY`），不是某一个具体 outbound。**
指到 `my-hy2-obfs` 的话，切到备用入口之后 DNS 还在往原来那条死路上发。

`route.final` 同理指 selector。selector 里不放 `direct`：iOS 没有系统级
kill switch，一旦落到直连就是明文出网，而且不会有任何提示。

服务端的 VLESS 用户只有 `uuid`，**没有配 flow**，所以这里也不要写 `flow`；
不写 transport 就是裸 TCP，与服务端一致。

> **DNS 格式在 sing-box 1.12 变过。** 上面是新写法。报
> `legacy DNS server formats are deprecated` 说明你贴的是旧写法
> （`"address": "https://1.1.1.1/dns-query"`）。

---

## 三、几个只要写错就一定不通的点

| 点 | 说明 |
|---|---|
| `port` 和 `ports` 互斥 | mihomo 文档写明二选一。2026-09-07 两个都写了，节点直接无效，客户端**根本没往外拨**，日志里连 `client connected` 都不会有 |
| `server_port` 和 `server_ports` 互斥 | sing-box 同理，用了范围就不要再写单端口 |
| 密码后面要有空格 | 手机 SSH / 输入法会吞空格，`password:密码` 少一个空格类型就从映射变成字符串，**而且不报错** |
| **`up` / `down` 别虚报** | 服务端保留着 Brutal（`ignoreClientBandwidth: false`），会**照着你申报的速率硬推并无视丢包**。这条路实测约 27 Mbps，写 `50/10`；写 `150/30` 多出来的部分会原样变成丢包——09-07 查到的 30% 丢包里，相当一部分可能就是这么来的 |
| `obfs` 两边必须一致 | 服务端保留着 Salamander。客户端漏了、或密码不一样，节点就是连不上——而且失败形式是"连不上"，很容易被当成新故障 |
| 混淆密码不写进仓库 | 上面是占位符。真密码在服务器 `/etc/hysteria/config.yaml` 里，`restore-baseline.sh` 跑完也会打印一次 |

---

## 四、怎么判断"通了"

**不要用"能刷开网页"判断。** Safari 可能吃缓存，也可能被分流规则判成直连走
国内出口，两种都会给出假的"通"。

只用这两个：

- 客户端里对节点**点测延迟**（出数字 = 握手成功，超时 = 没通）
- 或打开一个**必须翻墙、且没有国内 CDN** 的站

还有一条来自实测的判读纪律：**短于 5 分钟的重连是锁屏 / 切后台，不是故障。**
读断线记录时先问"设备当时醒着吗"，再谈故障。
