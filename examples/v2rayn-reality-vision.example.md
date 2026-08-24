# v2rayN：VLESS + REALITY + Vision 客户端示例

这份配置根据当前 v2rayN 节点库、已有导入稿和 Xray 字段结构交叉整理。

审计环境：

- v2rayN 7.24.2
- Xray 26.6.1 已安装
- 当前日常激活的是 HY2，因此本次只读审计没有主动切换节点去重启 Xray
- REALITY 节点的 CoreType 指向 Xray

因此这份示例属于：**生产节点结构已存在 + 配置交叉核对完成，但本次审计没有为了验证而主动切换现网节点。**

## 1. Xray outbound 结构

脱敏后的结构：

```json
{
  "protocol": "vless",
  "settings": {
    "vnext": [
      {
        "address": "YOUR_SERVER_IP",
        "port": 443,
        "users": [
          {
            "id": "YOUR_UUID",
            "encryption": "none",
            "flow": "xtls-rprx-vision"
          }
        ]
      }
    ]
  },
  "streamSettings": {
    "network": "raw",
    "security": "reality",
    "realitySettings": {
      "show": false,
      "publicKey": "YOUR_REALITY_PUBLIC_KEY",
      "shortId": "YOUR_SHORT_ID",
      "serverName": "YOUR_SERVER_NAME",
      "fingerprint": "chrome",
      "spiderX": "/"
    }
  }
}
```

关键字段：

```text
flow        = xtls-rprx-vision
transport   = RAW / TCP
security    = REALITY
fingerprint = chrome
```

Xray 新版本把原来常写成 `tcp` 的 RAW transport 更明确地称为 `raw`。旧配置/GUI 里仍可能看到 `tcp`，不要因为字段名变化误以为是不同协议。

## 2. v2rayN 分享链接

```text
vless://YOUR_UUID@YOUR_SERVER_IP:443?type=raw&security=reality&fp=chrome&sni=YOUR_SERVER_NAME&pbk=YOUR_REALITY_PUBLIC_KEY&sid=YOUR_SHORT_ID&flow=xtls-rprx-vision#REALITY-Vision-Example
```

需要替换：

```text
YOUR_UUID
YOUR_SERVER_IP
YOUR_SERVER_NAME
YOUR_REALITY_PUBLIC_KEY
YOUR_SHORT_ID
```

注意：客户端拿的是 **Reality Public Key**，不是服务器的 Private Key。

## 3. 服务端和客户端分别保存什么

服务端：

```text
Reality Private Key
shortId
允许的 serverNames
```

客户端：

```text
Reality Public Key
shortId
serverName / SNI
UUID
```

绝对不要把 Reality Private Key 填进客户端分享链接或公开仓库。

## 4. 为什么我把它当备用入口

我的日常主入口仍然是 HY2。

REALITY + Vision 主要用于：

- 当前网络 UDP 不稳定；
- 某些网络限制 UDP；
- HY2 暂时不可用；
- 希望保留一条独立 TCP 接入路径。

所以推荐理解为：

```text
HY2       = Primary
REALITY   = Backup
```

而不是二选一。

## 5. serverName / target

当前服务端实际使用公共 TLS 站点作为 REALITY target，客户端的 `serverName` 与服务端允许值对应。

本仓库服务端 example 使用：

```text
www.microsoft.com:443
```

只是一个示例，不代表所有 VPS、所有地区都应该机械照抄。

Xray 官方建议先确认你的 VPS 到 target 的 TLS 行为正常，并提醒：未通过 REALITY 认证的流量可能被转发到 target，所以 target 的选择和 fallback 风险需要认真考虑。

官方文档：

<https://xtls.github.io/config/transports/reality.html>

## 6. 如果希望 REALITY 也由 sing-box 承载

v2rayN / sing-box 的等价思路大致是：

```json
{
  "type": "vless",
  "tag": "proxy",
  "server": "YOUR_SERVER_IP",
  "server_port": 443,
  "uuid": "YOUR_UUID",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "YOUR_SERVER_NAME",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "YOUR_REALITY_PUBLIC_KEY",
      "short_id": "YOUR_SHORT_ID"
    }
  }
}
```

这份只是帮助理解字段映射；本仓库当前 v2rayN 审计里，REALITY 节点指定的是 Xray core。

## 7. Mihomo 等价写法（可选）

```yaml
proxies:
  - name: REALITY-Vision-Example
    type: vless
    server: YOUR_SERVER_IP
    port: 443
    uuid: YOUR_UUID
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: YOUR_SERVER_NAME
    client-fingerprint: chrome
    reality-opts:
      public-key: YOUR_REALITY_PUBLIC_KEY
      short-id: YOUR_SHORT_ID
```

## 8. 最容易写错的地方

### 公私钥写反

```text
服务器：Private Key
客户端：Public Key
```

### 忘记 Vision flow

```text
xtls-rprx-vision
```

服务端和客户端需要对应。

### 把不同 core 的字段名混用

同一件事在不同 core 里可能叫：

```text
Xray       serverName / publicKey / shortId
sing-box   server_name / public_key / short_id
Mihomo     servername / reality-opts.public-key
```

不要跨格式复制字段名。
