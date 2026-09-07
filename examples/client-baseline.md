# 客户端基线配置（两台设备用同一份）

这是和 `scripts/restore-baseline.sh` 配套的另一半。服务端还原之后，
**两台客户端都要整段替换成这里的配置**，否则两端对不上，节点直接不通。

> **整段替换，不要逐行改。** 现在手机和 iPad 上的配置是多轮手改的产物，
> 逐行改只会得到又一个"介于两者之间"的形态——那正是要消灭的东西。

> **两台用同一份，不要给单台设备开小灶。** 2026-09-07 那一轮里，手机被按
> Clash 改了很久，实际上跑的是 sing-box；iPad 和手机拿到的字段又不一样。
> 结果是任何一次现象都没法归因到某一端。**动手前先确认每台设备各跑什么客户端。**

---

## 基线长什么样

| 项 | 值 |
|---|---|
| HY2 | `UDP 24443`，**无混淆** |
| VLESS | `TCP 8443` |
| 端口跳跃 | **没有**（`ports` / `server_ports` / `hop-interval` 全部不写） |
| 证书 | 自签，CN = `www.bing.com`，客户端跳过校验 |
| 节点组 | 手动 `select`，HY2 在前 |

三个"曾经加过、现在一律不带"的字段：`obfs`、`ports` / `server_ports`、
`hop-interval` / `hop_interval`。服务端已经不认它们了。

---

## 一、mihomo / Clash（`ports` 与 `port` 互斥，这里只用 `port`）

```yaml
proxies:
  - name: my-hy2
    type: hysteria2
    server: PASTE_SERVER_IP
    port: 24443
    password: PASTE_HY2_PASSWORD
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
      - my-hy2
      - my-tcp
```

---

## 二、sing-box（iOS / iPad，只列 outbounds 的关键部分）

```json
{
  "type": "hysteria2",
  "tag": "proxy",
  "server": "PASTE_SERVER_IP",
  "server_port": 24443,
  "up_mbps": 10,
  "down_mbps": 50,
  "password": "PASTE_HY2_PASSWORD",
  "tls": {
    "enabled": true,
    "server_name": "www.bing.com",
    "insecure": true
  }
}
```

VLESS 那个 outbound 的 `server_port` 填 **8443**，`uuid` 和 TLS 部分照抄原样。

DNS 的 `detour` 要指 selector，不要直接指某一个 outbound——否则切到备用入口
之后 DNS 还在往原来那条死路上发。selector 里不要放 `DIRECT`：iOS 没有系统级
kill switch，一旦落到 DIRECT 就是明文出网。

---

## 三、几个只要写错就一定不通的点

| 点 | 说明 |
|---|---|
| `port` 和 `ports` 互斥 | mihomo 文档写明二选一。2026-09-07 两个都写了，节点直接无效，客户端**根本没往外拨**，日志里连 `client connected` 都不会有 |
| `server_port` 和 `server_ports` 互斥 | sing-box 同理，用了范围就不要再写单端口 |
| 密码后面要有空格 | 手机 SSH / 输入法会吞空格，`password:密码` 少一个空格类型就从映射变成字符串，**而且不报错** |
| `up` / `down` 别虚报 | 基线是 `ignoreClientBandwidth: true`（BBR），服务端**根本不看**这两个值；只有重新打开 Brutal 时它们才生效，那时虚报会把多出来的带宽全变成丢包 |
| 别加回 `obfs` | 服务端基线没开 Salamander，带混淆的节点连不上 |

---

## 四、怎么判断"通了"

**不要用"能刷开网页"判断。** Safari 可能吃缓存，也可能被分流规则判成直连走
国内出口，两种都会给出假的"通"。

只用这两个：

- 客户端里对节点**点测延迟**（出数字 = 握手成功，超时 = 没通）
- 或打开一个**必须翻墙、且没有国内 CDN** 的站

还有一条来自实测的判读纪律：**短于 5 分钟的重连是锁屏 / 切后台，不是故障。**
读断线记录时先问"设备当时醒着吗"，再谈故障。
